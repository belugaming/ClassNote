#!/usr/bin/env python3
"""Local MLX translation sidecar for ClassNote.

Started by LocalMLXTranslatorProcess.swift, which waits for the ``READY`` line on
stdout before sending work.

Protocol -- newline-delimited JSON over stdin/stdout. Translation is
request/response rather than a continuous audio stream, so this needs none of the
WebSocket machinery asr_server.py has; a pipe is enough and avoids allocating a
port.

Client -> server (one JSON object per line):
    {"id": 1, "text": "...", "source": "en", "target": "zh",
     "context": ["previous sentence", ...],        (optional)
     "terms": [["eigenvalue", "特征值"], ...]}      (optional)
    {"id": 2, "cancel": true}

``context`` is the lecture just before this sentence and ``terms`` the course
glossary. Both go into the prompt through the templates Hy-MT2 was trained on
(background information and terminology intervention), which is what keeps a
pronoun or a course term consistent from one sentence to the next.

Server -> client:
    STAGE n/m key                     (plain line, load progress, repeated
                                       every few seconds while the model loads)
    READY                             (plain line, model resident)
    FATAL <msg>                       (plain line, load failed)
    {"id": 1, "delta": "线粒体"}       (zero or more)
    {"id": 1, "done": true}
    {"id": 1, "error": "..."}

The model stays resident between requests: Hy-MT2-1.8B takes seconds to load and
~1.2s to translate a sentence, so a per-request process would be dominated by
startup.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import threading
import traceback
from queue import Queue

DEFAULT_MODEL = "mlx-community/Hy-MT2-1.8B-4bit"
# Commit to download. Empty means "whatever main points at"; a sha is read off
# the CI job that prints model_info(...).sha for every repo the app uses, and
# pinning it stops a re-upload changing the model under a user who already has
# the old weights cached.
DEFAULT_REVISION = "e5c6fe56c7b3bc77fae5ae92db31f2178f1e6912"
# A superset of what mlx_lm.load() would fetch on its own (mlx_lm/utils.py
# _download, 0.31.3), but not of the whole repo: without it the snapshot also
# pulls original PyTorch weights and GGUF conversions. It has to stay a superset
# -- load() receives a local directory here and cannot fetch a file it misses --
# so re-check _download's defaults whenever mlx-lm is bumped.
MODEL_ALLOW_PATTERNS = ["*.json", "*.safetensors", "*.py", "*.jinja",
                        "tokenizer.model", "*.tiktoken", "tiktoken.model",
                        "*.txt", "*.jsonl"]

# The only three lines Swift parses on stdout, held as the real stream so a
# library that rebinds sys.stdout (huggingface_hub does, mid-download) cannot
# take the handshake channel with it.
_HANDSHAKE = sys.stdout
STAGE_LINE = "STAGE 1/1 translation"
# The app extends its start-up deadline on every STAGE line; the first run
# downloads ~1 GB with nothing else to show for it.
HEARTBEAT_SECONDS = 5.0

# Hy-MT2 is a dedicated translation model, not a general chat model: it is
# trained to answer the instruction shapes in its model card (github.com/
# Tencent-Hunyuan/Hy-MT2, README "Prompt Templates") with the translation and
# nothing else. Every template exists in a Chinese and an English wording, and
# the card asks for full language names in the prompt's own language -- codes
# like "zh-Hans" are not part of its training format.
LANGUAGE_NAMES = {
    "zh": "Chinese", "zh-hans": "Chinese", "zh-hant": "Traditional Chinese",
    "zh-cn": "Chinese", "zh-tw": "Traditional Chinese",
    "en": "English", "ja": "Japanese", "ko": "Korean", "fr": "French",
    "de": "German", "es": "Spanish", "pt": "Portuguese", "ru": "Russian",
    "it": "Italian", "ar": "Arabic", "hi": "Hindi", "th": "Thai",
    "vi": "Vietnamese", "id": "Indonesian", "tr": "Turkish", "pl": "Polish",
    "nl": "Dutch", "cs": "Czech", "uk": "Ukrainian", "he": "Hebrew",
}
# The card's Chinese names, used when the prompt is in Chinese.
LANGUAGE_NAMES_ZH = {
    "Chinese": "中文", "Traditional Chinese": "繁体中文", "English": "英语",
    "Japanese": "日语", "Korean": "韩语", "French": "法语", "German": "德语",
    "Spanish": "西班牙语", "Portuguese": "葡萄牙语", "Russian": "俄语",
    "Italian": "意大利语", "Arabic": "阿拉伯语", "Hindi": "印地语",
    "Thai": "泰语", "Vietnamese": "越南语", "Indonesian": "印尼语",
    "Turkish": "土耳其语", "Polish": "波兰语", "Dutch": "荷兰语",
    "Czech": "捷克语", "Ukrainian": "乌克兰语", "Hebrew": "希伯来语",
}

# How much of the preceding lecture goes in as background. Enough to resolve
# "it" and "this" across a sentence boundary; more only slows every sentence
# down and gives a 1.8B model more text it might translate by mistake.
MAX_CONTEXT_SENTENCES = 2
MAX_CONTEXT_CHARS = 400
# Glossary entries that actually occur in the sentence, capped: the whole
# course glossary on every line would cost latency for terms that are not there.
MAX_TERMS = 12
# Hy-MT2's recommended repetition penalty. Decoding stays greedy (see handle),
# and a small model decoding greedily is the one most prone to loops.
REPETITION_PENALTY = 1.05


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def handshake(line: str):
    """One handshake line (STAGE/READY/FATAL) on the real stdout."""
    with _stdout_lock:
        print(line, file=_HANDSHAKE, flush=True)


def resolve_model_path(model: str, revision: str) -> str:
    """Local directory for `model`, downloading it if needed.

    mlx_lm.load() does take a revision, but it resolves the snapshot with its own
    allow_patterns, which drag in every quantization sitting in the repo. Doing
    the download here narrows that set -- at the cost of having to keep
    MODEL_ALLOW_PATTERNS a superset of mlx_lm's own list, since load() gets a
    local directory and can no longer fetch anything it finds missing. A model
    that is already a directory (a developer testing a local conversion) is used
    as it is.
    """
    if os.path.isdir(model):
        return model
    from huggingface_hub import snapshot_download

    if revision:
        return snapshot_download(model, revision=revision,
                                 allow_patterns=MODEL_ALLOW_PATTERNS)
    return snapshot_download(model, allow_patterns=MODEL_ALLOW_PATTERNS)


def emit(payload: dict):
    """One JSON object per line on stdout. Guarded by a lock because streaming
    deltas and a late error can race."""
    with _stdout_lock:
        sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
        sys.stdout.flush()


_stdout_lock = threading.Lock()
_cancelled: set[int] = set()
_cancel_lock = threading.Lock()


def language_name(code: str, fallback: str) -> str:
    if not code:
        return fallback
    return LANGUAGE_NAMES.get(code.strip().lower(), code.strip())


def is_chinese(code: str) -> bool:
    return (code or "").strip().lower().split("-")[0] == "zh"


def term_occurs(term: str, text: str) -> bool:
    """Whether `term` is in `text` as a term, not inside another word: "RAM"
    must not match "program". Latin terms need word boundaries; CJK has no
    spaces, so there a substring is the best there is."""
    if re.search(r"[A-Za-z0-9]", term):
        pattern = r"(?<![A-Za-z0-9])" + re.escape(term) + r"(?![A-Za-z0-9])"
        return re.search(pattern, text, re.IGNORECASE) is not None
    return term in text


def relevant_terms(text: str, terms) -> list[tuple[str, str]]:
    """Glossary pairs whose source term occurs in `text`, oriented source ->
    target. A student may have written the glossary either way round
    ("特征值 = eigenvalue" for an English lecture), so a pair whose right-hand
    side is the one in the sentence is flipped rather than dropped."""
    out: list[tuple[str, str]] = []
    seen: set[str] = set()
    for pair in terms or []:
        if not isinstance(pair, (list, tuple)) or len(pair) != 2:
            continue
        a, b = (str(pair[0]).strip(), str(pair[1]).strip())
        if not a or not b:
            continue
        if term_occurs(a, text):
            src, tgt = a, b
        elif term_occurs(b, text):
            src, tgt = b, a
        else:
            continue
        if src.lower() in seen:
            continue
        seen.add(src.lower())
        out.append((src, tgt))
        if len(out) >= MAX_TERMS:
            break
    return out


def background_text(context) -> str:
    """The last few sentences before this one, trimmed from the front so the
    sentence nearest the one being translated always survives."""
    lines = [str(c).strip() for c in (context or []) if str(c).strip()]
    joined = " ".join(lines[-MAX_CONTEXT_SENTENCES:])
    if len(joined) > MAX_CONTEXT_CHARS:
        joined = joined[-MAX_CONTEXT_CHARS:]
    return joined


def build_instruction(text: str, source: str, target: str,
                      context=None, terms=None) -> str:
    """The user turn, in the model card's own wording.

    Chinese on either side of the pair takes the Chinese templates, which is
    how every example in the card for a pair with Chinese is written; any other
    pair takes the English ones.
    """
    tgt_en = language_name(target, "Chinese")
    chinese = is_chinese(source) or is_chinese(target)
    tgt = LANGUAGE_NAMES_ZH.get(tgt_en, tgt_en) if chinese else tgt_en
    pairs = relevant_terms(text, terms)
    background = background_text(context)

    if background:
        # "Structured Data 2" in the card: the background block is read, not
        # translated. It replaced Hy-MT1.5's contextual template.
        if chinese:
            prompt = (f"【背景信息】\n{background}\n\n"
                      f"请结合背景信息将以下文本翻译为{tgt}。\n\n"
                      f"【待翻译文本】\n{text}")
        else:
            prompt = (f"[Background Information]\n{background}\n\n"
                      f"Please translate the following text into {tgt}, taking the "
                      f"provided background information into consideration.\n\n"
                      f"[Source Text]\n{text}")
        if pairs:
            if chinese:
                glossary = "\n".join(f"{a} 翻译成 {b}" for a, b in pairs)
                prompt = f"参考下面的翻译：\n{glossary}\n{prompt}"
            else:
                glossary = "\n".join(f"{a} translates to {b}" for a, b in pairs)
                prompt = f"Reference the following translations:\n{glossary}\n\n{prompt}"
        return prompt

    if pairs:
        if chinese:
            glossary = "\n".join(f"{a} 翻译成 {b}" for a, b in pairs)
            return (f"参考下面的翻译：\n{glossary}\n"
                    f"将以下文本翻译为{tgt}，注意只需要输出翻译后的结果，不要额外解释：\n\n{text}")
        glossary = "\n".join(f"{a} translates to {b}" for a, b in pairs)
        return (f"Reference the following translations:\n{glossary}\n\n"
                f"Translate the following text into {tgt}. Note that you must ONLY output "
                f"the translated result without any additional explanation:\n\n{text}")

    if chinese:
        return f"将以下文本翻译为{tgt}，注意只需要输出翻译后的结果，不要额外解释：\n\n{text}"
    return (f"Translate the following text into {tgt}. Note that you should only output "
            f"the translated result without any additional explanation:\n\n{text}")


def build_prompt(tokenizer, text: str, source: str, target: str,
                 context=None, terms=None) -> str:
    instruction = build_instruction(text, source, target, context, terms)
    # The card: "our models do not have a default system_prompt".
    messages = [{"role": "user", "content": instruction}]
    try:
        return tokenizer.apply_chat_template(messages, add_generation_prompt=True)
    except Exception:
        # No chat template: fall back to the raw instruction rather than failing.
        return instruction


def handle(model, tokenizer, req: dict):
    from mlx_lm import stream_generate
    from mlx_lm.sample_utils import make_logits_processors, make_sampler

    req_id = req.get("id")
    text = (req.get("text") or "").strip()
    if not text:
        emit({"id": req_id, "done": True})
        return

    prompt = build_prompt(tokenizer, text, req.get("source", ""), req.get("target", ""),
                          context=req.get("context"), terms=req.get("terms"))
    # Greedy. Translation wants the most likely rendering, and sampling here
    # would make the same sentence translate differently on a retranslate.
    sampler = make_sampler(temp=0.0)
    logits_processors = make_logits_processors(repetition_penalty=REPETITION_PENALTY)
    # Generous relative to the input: CJK->Latin can expand, and a hard cap that
    # truncates mid-sentence is worse than spending a few extra tokens.
    max_tokens = max(64, min(1024, len(text) * 4))

    try:
        for chunk in stream_generate(model, tokenizer, prompt,
                                     max_tokens=max_tokens, sampler=sampler,
                                     logits_processors=logits_processors):
            with _cancel_lock:
                if req_id in _cancelled:
                    _cancelled.discard(req_id)
                    log(f"[translate] request {req_id} cancelled")
                    emit({"id": req_id, "done": True})
                    return
            piece = getattr(chunk, "text", "") or ""
            if piece:
                emit({"id": req_id, "delta": piece})
        emit({"id": req_id, "done": True})
    except Exception as exc:
        log(f"[translate] {traceback.format_exc()}")
        emit({"id": req_id, "error": str(exc)})


def watch_parent(parent_pid: int, interval: float = 5.0):
    """Exit once the app that spawned us is gone.

    The sidecar is kept warm, so nothing else would reap it if the app crashed or
    was force-quit -- it would sit there holding the weights. signal 0 only checks
    whether the pid is still alive.
    """
    import time

    while True:
        time.sleep(interval)
        try:
            os.kill(parent_pid, 0)
            continue
        except (ProcessLookupError, PermissionError):
            pass                       # gone -- fall through to the exit
        except Exception:
            return
        # Outside the handler on purpose. The parent is gone, so its end of the
        # stderr pipe is closed and this write raises BrokenPipeError; raised
        # inside the handler that exception escaped before os._exit could run,
        # and the sidecar stayed resident with the weights loaded.
        try:
            log(f"[parent] pid {parent_pid} is gone, exiting")
        except Exception:
            pass
        os._exit(0)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--revision", default=DEFAULT_REVISION,
                        help="model commit to download; empty means main")
    parser.add_argument("--exit-with-parent", type=int, default=0)
    args = parser.parse_args()

    if args.exit_with_parent:
        threading.Thread(target=watch_parent, args=(args.exit_with_parent,),
                         daemon=True).start()

    handshake(STAGE_LINE)

    # Generation runs on its own thread so stdin stays readable while a request is
    # in flight. Doing both on one thread would make cancel useless: the loop
    # would be blocked inside handle() and could not read the cancel line until
    # the work it was meant to abort had already finished.
    #
    # One worker, not a pool, and the model is loaded *inside* it: MLX state is
    # thread-affine, so weights loaded on the main thread and used here die with
    # "There is no Stream(gpu, N) in current thread".
    queue: "Queue[dict]" = Queue()
    ready = threading.Event()
    load_failed: list[str] = []

    def worker():
        try:
            from mlx_lm import load

            model, tokenizer = load(resolve_model_path(args.model, args.revision))
        except Exception:
            log(f"[fatal] model load failed: {traceback.format_exc()}")
            load_failed.append("load failed")
            ready.set()
            return
        ready.set()

        while True:
            req = queue.get()
            if req is None:
                return
            req_id = req.get("id")
            with _cancel_lock:
                # Cancelled while still queued -- never start it.
                if req_id in _cancelled:
                    _cancelled.discard(req_id)
                    emit({"id": req_id, "done": True})
                    continue
            try:
                handle(model, tokenizer, req)
            except Exception:
                log(f"[translate] {traceback.format_exc()}")
                emit({"id": req_id, "error": "internal error"})

    threading.Thread(target=worker, daemon=True).start()
    # Heartbeat while the worker downloads and loads: a repeated STAGE line
    # keeps the app's deadline alive and its progress text on screen, where
    # silence reads as a hang.
    while not ready.wait(HEARTBEAT_SECONDS):
        handshake(STAGE_LINE)
    if load_failed:
        # Swift waits for READY; without this it blocks for the full timeout
        # instead of surfacing the failure.
        handshake("FATAL translation model load failed")
        sys.exit(1)

    handshake("READY")
    log(f"[translate] ready with {args.model}")

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            log(f"[translate] ignoring non-JSON line: {line[:80]!r}")
            continue
        if req.get("cancel"):
            with _cancel_lock:
                _cancelled.add(req.get("id"))
            continue
        queue.put(req)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
