#!/usr/bin/env python3
"""Local simultaneous-translation sidecar (Confucius4-T3PO) for ClassNote.

T3PO (NetEase Youdao, Apache-2.0) is a 14B Qwen2.5 fine-tune for simultaneous
machine translation between Chinese and English. It is fed the transcript a
chunk at a time and decides after each chunk whether it has heard enough to
translate (WRITE) or should wait for more (READ). This file ports the
reference engine (github.com/netease-youdao/Confucius4-T3PO, inference/) onto
mlx-lm.

Started by SimulTranslatorProcess.swift, which waits for ``READY`` on stdout.

Protocol -- newline-delimited JSON over stdin/stdout:

Client -> server:
    {"id": 1, "op": "start", "session": "s1", "direction": "en2zh",
     "latency": "native", "terms": [["eigenvalue", "特征值"], ...]}
    {"id": 2, "op": "feed",  "session": "s1", "text": "next transcript line"}
    {"id": 3, "op": "flush", "session": "s1"}      translate whatever is held
    {"id": 4, "op": "end",   "session": "s1"}

Server -> client:
    STAGE n/m key            (plain line; download, convert, load)
    READY / FATAL <msg>      (plain lines)
    {"id": 2, "events": [{"type": "translation", "source": "...", "text": "..."}]}
    {"id": 2, "events": [{"type": "wait"}]}
    {"id": 2, "error": "..."}

Weights: there is no MLX build of T3PO, so the first run downloads the
original bf16 checkpoint (~28 GB), quantizes it to 4 bits with mlx-lm
(~8 GB, kept under --model-dir) and deletes the download again.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import re
import shutil
import sys
import threading
import traceback
from queue import Queue

SOURCE_REPO = "netease-youdao/Confucius4-T3PO"
# Commit to download; None means main. Pinned from the CI job that prints
# model_info(...).sha for every repo the app uses.
SOURCE_REVISION: str | None = "446e5dcca080740f2c2dc9d06a91ed66a9920410"
Q_BITS = 4
Q_GROUP_SIZE = 64
SOURCE_ALLOW_PATTERNS = ["*.json", "*.safetensors", "*.txt", "*.jinja",
                         "tokenizer*", "*.model", "*.tiktoken", "merges.txt", "vocab.json"]
# Download plus the converted copy, with a margin. Checked up front: running
# out of disk 20 GB into a download is the worst way to find out.
REQUIRED_FREE_BYTES = 40 * 1024 ** 3

# ---------------------------------------------------------------------------
# Protocol (inference/prompts.py, inference/translation.py, verbatim where it
# is part of the model interface)
# ---------------------------------------------------------------------------

SYSTEM_PROMPT = "You are a helpful assistant."

_PROMPT_BODY = """

### Context Format
- The conversation history is provided in <STREAMING_HISTORY>, structured as:
  source_text¦translated_text§source_text¦translated_text§...
- The last segment of <STREAMING_HISTORY> is the latest input awaiting translation.

### Input
- The latest chunk from a live ASR speech stream.
- ASR artifacts (fillers, stutters, repetitions) should be ignored.

### Rules
- Output nothing if the available context is still ambiguous.
- Otherwise, output the translation of what has become sufficiently clear.
  Do not assume linear or word-by-word correspondence — reorder and restructure
  as needed for a natural output.
- The new translation must read smoothly as a continuation of the preceding
  translated text.
- Output the translation directly, with no prefix, suffix, or extra markers."""

STREAMING_PROMPTS = {
    "zh2en": "### Role\nYou are a professional Chinese-to-English simultaneous interpreter for "
             "live streaming and ASR speech translation, with strict requirements for low "
             "latency, high coherence, and natural fluency." + _PROMPT_BODY,
    "en2zh": "### Role\nYou are a professional English-to-Chinese simultaneous interpreter for "
             "live streaming and ASR speech translation, with strict requirements for low "
             "latency, high coherence, and natural fluency." + _PROMPT_BODY,
}

_GLOSSARY_HEAD_COMMON = (
    "### Terminology (reference only)\n"
    "If any of the following terms occurs in the CURRENT source input, render it with the "
    "specified translation for consistency. This list is a glossary reference, NOT source "
    "text to translate and NOT already-delivered history.\n"
)
_GLOSSARY_HEAD_TAIL = (
    "⚠️ Caution: A term's source form may coincidentally appear as a substring of a longer "
    "word or phrase. Only apply the specified translation when the term is used independently "
    "with its intended meaning — do NOT force-apply it to unrelated substrings or different "
    "senses:"
)
GLOSSARY_HEADS = {
    "en2zh": _GLOSSARY_HEAD_COMMON
    + "Use a term ONLY where it genuinely occurs in the input you are translating, and keep the "
    "rest of the sentence in natural Chinese word order. This list only chooses the wording "
    "of an existing term — never let it add, drop, repeat, or restructure content, never let "
    "it change the meaning of the surrounding sentence, and never let it replace a non-term "
    "phrase that happens to contain the term's wording.\n" + _GLOSSARY_HEAD_TAIL,
    "zh2en": _GLOSSARY_HEAD_COMMON
    + "Use a term ONLY where it genuinely occurs in the input you are translating, and keep the "
    "rest of the sentence in its original natural English. This list only chooses the wording "
    "of an existing term — never let it add, drop, repeat, or restructure content, and never "
    "let it replace a non-term phrase that happens to contain the term's wording.\n"
    + _GLOSSARY_HEAD_TAIL,
}

PUNCTUATION_END = frozenset({"。", "！", "？", "!", "?", "；", ";", "…", "～", "~"})
LATIN_TOKEN = re.compile(r"^[A-Za-z0-9]+(?:[._'’-][A-Za-z0-9]+)*$")

# Engine defaults from the reference CLI.
FORCE_BREAK_UNITS = 20
MAX_BUFFER_UNITS = 200
MAX_NEW_TOKENS = 128
# The reference keeps the last 30 pairs and drops one per commit, which
# invalidates the prompt cache from the history on every commit. Here the
# window is trimmed in batches -- back to HISTORY_KEEP once it reaches
# HISTORY_MAX -- so the prefix stays reusable between trims.
HISTORY_MAX = 30
HISTORY_KEEP = 20

# Latency modes: WAIT if max(stop logits) - max(other logits) >= tau, done by
# biasing the two stop tokens (inference/latency.py).
STOP_TOKEN_IDS = (151643, 151645)          # <|endoftext|>, <|im_end|>
STOP_TOKEN_BIAS_SCALES = {151643: 1.0, 151645: 1.05}
LATENCY_TAU = {"low": 0.9375009536743164, "native": 0.0, "high": -0.39}
REPETITION_PENALTY = 1.05

_WAIT_ONLY = re.compile(r"^<?\s*WAIT\s*>?$", re.IGNORECASE)
_TRANS_ONLY = re.compile(r"^<?\s*TRANS\s*>?$", re.IGNORECASE)
_TRANS_PREFIX = re.compile(r"^(?:<\s*TRANS\s*>\s*|TRANS(?:\s*[:：]\s*|\s+))", re.IGNORECASE)


def sanitize(text) -> str:
    """Keeps generated text from corrupting the interleaved history markup."""
    return str(text or "").replace("¦", "｜").replace("§", "；").strip()


def parse_response(raw) -> tuple[str, str]:
    """("WAIT"|"TRANS", text). An empty completion is a WAIT."""
    text = str(raw or "").replace("<|im_end|>", "").strip()
    if not text or _WAIT_ONLY.fullmatch(text) or _TRANS_ONLY.fullmatch(text):
        return "WAIT", ""
    text = sanitize(_TRANS_PREFIX.sub("", text, count=1))
    return ("TRANS", text) if text else ("WAIT", "")


def split_source(text: str, direction: str) -> list[str]:
    """Source units: whitespace words for English; for Chinese one unit per
    character, with runs of ASCII letters/digits kept whole."""
    if direction == "en2zh":
        return str(text or "").strip().split()
    tokens: list[str] = []
    value = str(text or "")
    i = 0
    while i < len(value):
        ch = value[i]
        if ch.isspace():
            j = i + 1
            while j < len(value) and value[j].isspace():
                j += 1
            tokens.append(value[i:j])
            i = j
        elif ch.isascii() and (ch.isalnum() or ch in "_'’"):
            j = i + 1
            while j < len(value) and value[j].isascii() and (value[j].isalnum() or value[j] in "_'’.-"):
                j += 1
            tokens.append(value[i:j])
            i = j
        else:
            tokens.append(ch)
            i += 1
    return tokens


def join_source(tokens: list[str], direction: str) -> str:
    return " ".join(tokens) if direction == "en2zh" else "".join(tokens)


def source_units(tokens: list[str], direction: str) -> int:
    if direction == "en2zh":
        return len(tokens)
    return sum(not t.isspace() for t in tokens)


def terms_in(terms, segment: str) -> list[tuple[str, str]]:
    """Glossary entries that occur in `segment` (inference/glossary.py)."""
    seg = segment or ""
    seg_nospace = seg.replace(" ", "")
    hits = []
    for src, tgt in terms:
        src_nospace = src.replace(" ", "")
        found = (src_nospace in seg_nospace) if len(src_nospace) >= 3 else (src in seg)
        if found:
            hits.append((src, tgt))
    return hits


def glossary_block(terms, direction: str) -> str:
    if not terms:
        return ""
    lines = "\n".join(f"- {s} -> {t}" for s, t in terms)
    return f"{GLOSSARY_HEADS[direction]}\n{lines}"


def build_user_message(direction: str, history: str, current: str, glossary: str = "") -> str:
    block = f"\n{glossary}\n" if glossary else ""
    return (f"{STREAMING_PROMPTS[direction]}\n\n<STREAMING_HISTORY>\n{history}\n{block}\n"
            f"<CURRENT_INPUT>\n{current}")


def chat_prompt(user_message: str) -> str:
    """ChatML, as Qwen2.5's template renders [system, user] with a generation
    prompt. Built by hand so the prompt does not depend on a template file."""
    return (f"<|im_start|>system\n{SYSTEM_PROMPT}<|im_end|>\n"
            f"<|im_start|>user\n{user_message}<|im_end|>\n"
            "<|im_start|>assistant\n")


def normalize_terms(raw) -> list[tuple[str, str]]:
    out, seen = [], set()
    for item in raw or []:
        if not isinstance(item, (list, tuple)) or len(item) != 2:
            continue
        src, tgt = str(item[0] or "").strip(), str(item[1] or "").strip()
        if src and tgt and (src, tgt) not in seen:
            seen.add((src, tgt))
            out.append((src, tgt))
    return out[:200]


class SimulSession:
    """One lecture's translation state: committed (source, target) pairs and
    the source text heard since the last commit.

    `model.complete(prompt, force, latency) -> str` is the only model call; a
    forced call may not return empty (the engine must commit something).
    """

    def __init__(self, model, direction: str, latency: str = "native", terms=None):
        if direction not in STREAMING_PROMPTS:
            raise ValueError(f"unsupported direction {direction!r}")
        self.model = model
        self.direction = direction
        self.latency = latency if latency in LATENCY_TAU else "native"
        self.terms = normalize_terms(terms)
        self.history: list[tuple[str, str]] = []
        self.buffer: list[str] = []

    def history_text(self) -> str:
        return "".join(f"{s}¦{t}§" for s, t in self.history)

    def feed(self, text: str) -> list[dict]:
        incoming = [t for t in split_source(text, self.direction) if t]
        if not incoming:
            return []
        if (self.direction == "zh2en" and self.buffer and incoming
                and LATIN_TOKEN.match(self.buffer[-1] or "") and LATIN_TOKEN.match(incoming[0] or "")):
            self.buffer[-1] += incoming.pop(0)
        self.buffer.extend(incoming)
        units = source_units(self.buffer, self.direction)
        if not units:
            return []
        force = units >= MAX_BUFFER_UNITS or units >= FORCE_BREAK_UNITS
        if not force and self.direction == "zh2en" and LATIN_TOKEN.match(self.buffer[-1] or ""):
            # A trailing English word inside Chinese is often still being said.
            return []
        return [self._translate(force=force) or {"type": "wait"}]

    def flush(self) -> list[dict]:
        if not self.buffer or not source_units(self.buffer, self.direction):
            self.buffer.clear()
            return []
        return [self._translate(force=True) or {"type": "wait"}]

    def _translate(self, force: bool) -> dict | None:
        source = join_source(self.buffer, self.direction)
        glossary = glossary_block(terms_in(self.terms, source), self.direction)
        prompt = chat_prompt(build_user_message(self.direction, self.history_text(),
                                                source, glossary))
        raw = self.model.complete(prompt, force=force, latency=self.latency)
        action, target = parse_response(raw)
        if action == "WAIT":
            return None
        clean_source = sanitize(source)
        self.history.append((clean_source, target))
        if len(self.history) >= HISTORY_MAX:
            self.history = self.history[-HISTORY_KEEP:]
        self.buffer.clear()
        return {"type": "translation", "source": clean_source, "text": target}


# ---------------------------------------------------------------------------
# MLX model
# ---------------------------------------------------------------------------


class MLXSimulModel:
    """T3PO on mlx-lm, with the KV cache of the previous call reused up to the
    longest common prefix: between commits only the current input grows, so
    most calls prefill a few tokens instead of the whole history."""

    def __init__(self, path: str):
        from mlx_lm import load
        from mlx_lm.models.cache import make_prompt_cache

        self.model, self.tokenizer = load(path)
        self.cache = make_prompt_cache(self.model)
        self.cached: list[int] = []

    def complete(self, prompt: str, force: bool, latency: str) -> str:
        import mlx.core as mx
        from mlx_lm.generate import generate_step
        from mlx_lm.models.cache import trim_prompt_cache
        from mlx_lm.sample_utils import make_logits_processors

        ids = self.tokenizer.encode(prompt, add_special_tokens=False)
        common = 0
        for a, b in zip(self.cached, ids):
            if a != b:
                break
            common += 1
        common = min(common, len(ids) - 1)   # at least one token to feed
        if len(self.cached) > common:
            trim_prompt_cache(self.cache, len(self.cached) - common)
        suffix = ids[common:]

        processors = []
        tau = LATENCY_TAU.get(latency, 0.0)
        if not force and tau:
            bias = {tok: -tau * STOP_TOKEN_BIAS_SCALES[tok] for tok in STOP_TOKEN_IDS}

            def latency_bias(tokens, logits):
                for tok, value in bias.items():
                    logits[..., tok] = logits[..., tok] + value
                return logits
            processors.append(latency_bias)
            processors += make_logits_processors(repetition_penalty=REPETITION_PENALTY)
        if force:
            first = len(suffix)

            def no_wait_on_first_token(tokens, logits):
                # A forced call must commit: EOS is banned as the first token.
                if tokens.shape[-1] <= first:
                    for tok in STOP_TOKEN_IDS:
                        logits[..., tok] = -mx.inf
                return logits
            processors.append(no_wait_on_first_token)

        out: list[int] = []
        for token, _ in generate_step(mx.array(suffix), self.model, max_tokens=MAX_NEW_TOKENS,
                                      sampler=lambda x: mx.argmax(x, axis=-1),
                                      logits_processors=processors or None,
                                      prompt_cache=self.cache):
            token = int(token)
            if token in STOP_TOKEN_IDS:
                break
            out.append(token)
        offset = self.cache[0].offset
        self.cached = (ids + out)[:offset]
        return self.tokenizer.decode(out)


def convert_model(model_dir: str, stage) -> str:
    """The quantized model directory, building it on first use."""
    if os.path.exists(os.path.join(model_dir, "config.json")):
        return model_dir
    from huggingface_hub import snapshot_download, try_to_load_from_cache

    parent = os.path.dirname(os.path.abspath(model_dir))
    os.makedirs(parent, exist_ok=True)
    cached_before = isinstance(try_to_load_from_cache(SOURCE_REPO, "config.json",
                                                      revision=SOURCE_REVISION), str)
    free = shutil.disk_usage(parent).free
    if not cached_before and free < REQUIRED_FREE_BYTES:
        raise RuntimeError(f"disk: {free // 1024 ** 3} GB free, "
                           f"{REQUIRED_FREE_BYTES // 1024 ** 3} GB needed")

    stage("download")
    kwargs = {"allow_patterns": SOURCE_ALLOW_PATTERNS}
    if SOURCE_REVISION:
        kwargs["revision"] = SOURCE_REVISION
    source = snapshot_download(SOURCE_REPO, **kwargs)

    stage("convert")
    from mlx_lm import convert

    # Into a scratch directory first: an interrupted conversion must not
    # leave a directory that looks finished.
    scratch = model_dir + ".partial"
    shutil.rmtree(scratch, ignore_errors=True)
    convert(source, mlx_path=scratch, quantize=True, q_bits=Q_BITS, q_group_size=Q_GROUP_SIZE)
    os.replace(scratch, model_dir)

    if not cached_before:
        # The bf16 original is ~28 GB and only served as input to the
        # conversion. Remove the whole repo from the hub cache.
        repo_dir = os.path.dirname(os.path.dirname(source))
        if os.path.basename(repo_dir).startswith("models--"):
            shutil.rmtree(repo_dir, ignore_errors=True)
    return model_dir


# ---------------------------------------------------------------------------
# Process plumbing (as translate_server.py)
# ---------------------------------------------------------------------------

_HANDSHAKE = sys.stdout
_stdout_lock = threading.Lock()
HEARTBEAT_SECONDS = 5.0


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def handshake(line: str):
    with _stdout_lock:
        print(line, file=_HANDSHAKE, flush=True)


def emit(payload: dict):
    with _stdout_lock:
        _HANDSHAKE.write(json.dumps(payload, ensure_ascii=False) + "\n")
        _HANDSHAKE.flush()


def watch_parent(parent_pid: int, interval: float = 5.0):
    import time

    while True:
        time.sleep(interval)
        try:
            os.kill(parent_pid, 0)
            continue
        except (ProcessLookupError, PermissionError):
            pass
        except Exception:
            return
        try:
            log(f"[parent] pid {parent_pid} is gone, exiting")
        except Exception:
            pass
        os._exit(0)


class Server:
    """Owns the model and the sessions; runs every request on one thread,
    because MLX state is thread-affine and requests must stay in order."""

    def __init__(self, model):
        self.model = model
        self.sessions: dict[str, SimulSession] = {}

    def handle(self, req: dict) -> dict:
        req_id = req.get("id")
        op = req.get("op")
        sid = str(req.get("session") or "")
        try:
            if op == "start":
                self.sessions[sid] = SimulSession(self.model, str(req.get("direction") or ""),
                                                  str(req.get("latency") or "native"),
                                                  req.get("terms"))
                return {"id": req_id, "events": []}
            if op == "end":
                self.sessions.pop(sid, None)
                return {"id": req_id, "events": []}
            session = self.sessions.get(sid)
            if session is None:
                return {"id": req_id, "error": f"unknown session {sid!r}"}
            if op == "feed":
                return {"id": req_id, "events": session.feed(str(req.get("text") or ""))}
            if op == "flush":
                return {"id": req_id, "events": session.flush()}
            return {"id": req_id, "error": f"unknown op {op!r}"}
        except Exception as exc:
            log(f"[simt] {traceback.format_exc()}")
            return {"id": req_id, "error": str(exc)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", required=True,
                        help="where the quantized model lives (built on first run)")
    parser.add_argument("--exit-with-parent", type=int, default=0)
    args = parser.parse_args()

    if args.exit_with_parent:
        threading.Thread(target=watch_parent, args=(args.exit_with_parent,), daemon=True).start()

    stages = ["download", "convert", "load"]
    current = {"key": "load"}

    def stage(key: str):
        current["key"] = key
        handshake(f"STAGE {stages.index(key) + 1}/{len(stages)} {key}")

    queue: "Queue[dict | None]" = Queue()
    ready = threading.Event()
    failure: list[str] = []
    holder: dict = {}

    def worker():
        try:
            with contextlib.redirect_stdout(sys.stderr):
                path = convert_model(args.model_dir, stage)
                stage("load")
                holder["server"] = Server(MLXSimulModel(path))
        except Exception as exc:
            log(f"[fatal] {traceback.format_exc()}")
            failure.append(str(exc).splitlines()[0] if str(exc) else "load failed")
            ready.set()
            return
        ready.set()
        server = holder["server"]
        while True:
            req = queue.get()
            if req is None:
                return
            emit(server.handle(req))

    threading.Thread(target=worker, daemon=True).start()
    while not ready.wait(HEARTBEAT_SECONDS):
        stage(current["key"])
    if failure:
        handshake(f"FATAL {failure[0]}")
        sys.exit(1)
    handshake("READY")
    log("[simt] ready")

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            log(f"[simt] ignoring non-JSON line: {line[:80]!r}")
            continue
        queue.put(req)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
