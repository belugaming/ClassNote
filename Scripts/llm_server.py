#!/usr/bin/env python3
"""Local MLX chat-completion sidecar for ClassNote.

Started by LocalMLXLLMProcess.swift, which waits for the ``READY`` line on stdout
before sending work. Structurally a sibling of translate_server.py: same
NDJSON-over-a-pipe protocol, same one-worker threading, same cancel handling.

It is a separate process rather than a second request kind on the translation
sidecar because that sidecar's single worker thread is its design -- MLX state
is thread-affine, so a second worker cannot share the first model -- and a
30-second notes generation would park every live subtitle translation behind it.

Client -> server (one JSON object per line):
    {"id": 1, "messages": [{"role": "system", "content": "..."},
                           {"role": "user", "content": "..."}],
     "temperature": 0.3, "max_tokens": 2048}
    {"id": 2, "cancel": true}

Server -> client:
    STAGE 1/1 llm                     (plain line, repeated every few seconds
                                       while the model loads)
    READY                             (plain line, model resident)
    FATAL <msg>                       (plain line, load failed)
    {"id": 1, "delta": "..."}         (zero or more)
    {"id": 1, "done": true}
    {"id": 1, "error": "..."}

The requested model name is not part of a request: this process loads exactly
one model, chosen by --model, and the app's model picker does not apply to it.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import traceback
from queue import Queue

# A 4B instruct model quantized to 4 bits: ~2.4 GB resident, which is what is
# left for notes and Q&A once nemotron and the translation model are loaded.
DEFAULT_MODEL = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
# Commit to download. Empty means "whatever main points at"; see the same
# constant in translate_server.py.
DEFAULT_REVISION = "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b"
# A superset of what mlx_lm.load() would fetch on its own; see the same constant
# in translate_server.py for why it must stay one.
MODEL_ALLOW_PATTERNS = ["*.json", "*.safetensors", "*.py", "*.jinja",
                        "tokenizer.model", "*.tiktoken", "tiktoken.model",
                        "*.txt", "*.jsonl"]

# Notes want a little variety in phrasing; an answer about the transcript does
# not want invention. 0.3 is the compromise the app sends, and it is only a
# default here.
DEFAULT_TEMPERATURE = 0.3
# A set of lecture notes runs to a few thousand tokens. The floor keeps a
# caller from truncating its own answer mid-sentence; the ceiling keeps a model
# that has started repeating itself from generating for an hour at ~30 tok/s.
DEFAULT_MAX_TOKENS = 2048
MIN_MAX_TOKENS = 256
MAX_MAX_TOKENS = 8192

ROLES = ("system", "user", "assistant")

# The only three lines Swift parses on stdout, held as the real stream so a
# library that rebinds sys.stdout (huggingface_hub does, mid-download) cannot
# take the handshake channel with it.
_HANDSHAKE = sys.stdout
STAGE_LINE = "STAGE 1/1 llm"
# The app extends its start-up deadline on every STAGE line; the first run
# downloads ~2.4 GB with nothing else to show for it.
HEARTBEAT_SECONDS = 5.0

_stdout_lock = threading.Lock()
_cancelled: set[int] = set()
_cancel_lock = threading.Lock()


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def handshake(line: str):
    """One handshake line (STAGE/READY/FATAL) on the real stdout."""
    with _stdout_lock:
        print(line, file=_HANDSHAKE, flush=True)


def emit(payload: dict):
    """One JSON object per line on stdout. Guarded by a lock because streaming
    deltas and a late error can race."""
    with _stdout_lock:
        sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
        sys.stdout.flush()


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


def normalize_messages(raw) -> list[dict]:
    """Keeps the well-formed turns of a request.

    A turn with a missing or non-string content makes apply_chat_template raise,
    which would cost the whole request; dropping it still leaves an answerable
    prompt. An unknown role becomes "user" for the same reason.
    """
    out: list[dict] = []
    for item in raw or []:
        if not isinstance(item, dict):
            continue
        content = item.get("content")
        if not isinstance(content, str) or not content.strip():
            continue
        role = item.get("role")
        out.append({"role": role if role in ROLES else "user", "content": content})
    return out


def clamp_max_tokens(value) -> int:
    try:
        n = int(value)
    except (TypeError, ValueError):
        n = DEFAULT_MAX_TOKENS
    return max(MIN_MAX_TOKENS, min(MAX_MAX_TOKENS, n))


def clamp_temperature(value) -> float:
    try:
        t = float(value)
    except (TypeError, ValueError):
        return DEFAULT_TEMPERATURE
    return max(0.0, min(2.0, t))


def plain_prompt(messages: list[dict]) -> str:
    """Fallback prompt for a tokenizer with no chat template. Labelled turns
    plus an empty assistant turn is what an instruct model was tuned on anyway,
    so the answer is usable even without the model's own control tokens."""
    return "\n\n".join([f"{m['role']}: {m['content']}" for m in messages]
                       + ["assistant:"])


def build_prompt(tokenizer, messages: list[dict]) -> str:
    try:
        return tokenizer.apply_chat_template(messages, add_generation_prompt=True,
                                             tokenize=False)
    except Exception:
        return plain_prompt(messages)


def handle(model, tokenizer, req: dict):
    from mlx_lm import stream_generate
    from mlx_lm.sample_utils import make_sampler

    req_id = req.get("id")
    messages = normalize_messages(req.get("messages"))
    if not messages:
        emit({"id": req_id, "done": True})
        return

    prompt = build_prompt(tokenizer, messages)
    sampler = make_sampler(temp=clamp_temperature(req.get("temperature",
                                                          DEFAULT_TEMPERATURE)))
    max_tokens = clamp_max_tokens(req.get("max_tokens", DEFAULT_MAX_TOKENS))

    try:
        for chunk in stream_generate(model, tokenizer, prompt,
                                     max_tokens=max_tokens, sampler=sampler):
            with _cancel_lock:
                if req_id in _cancelled:
                    _cancelled.discard(req_id)
                    log(f"[llm] request {req_id} cancelled")
                    emit({"id": req_id, "done": True})
                    return
            piece = getattr(chunk, "text", "") or ""
            if piece:
                emit({"id": req_id, "delta": piece})
        emit({"id": req_id, "done": True})
    except Exception as exc:
        log(f"[llm] {traceback.format_exc()}")
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
        # inside the handler that exception would escape before os._exit could
        # run, leaving the sidecar resident with the weights loaded.
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

    # Generation runs on its own thread so stdin stays readable while a request
    # is in flight. Doing both on one thread would make cancel useless: the loop
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
                log(f"[llm] {traceback.format_exc()}")
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
        handshake("FATAL llm model load failed")
        sys.exit(1)

    handshake("READY")
    log(f"[llm] ready with {args.model}")

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            log(f"[llm] ignoring non-JSON line: {line[:80]!r}")
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
