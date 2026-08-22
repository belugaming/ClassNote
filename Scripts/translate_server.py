#!/usr/bin/env python3
"""Local MLX translation sidecar for ClassNote.

Started by LocalMLXTranslatorProcess.swift, which waits for the ``READY`` line on
stdout before sending work.

Protocol -- newline-delimited JSON over stdin/stdout. Translation is
request/response rather than a continuous audio stream, so this needs none of the
WebSocket machinery asr_server.py has; a pipe is enough and avoids allocating a
port.

Client -> server (one JSON object per line):
    {"id": 1, "text": "...", "source": "en", "target": "zh"}
    {"id": 2, "cancel": true}

Server -> client:
    STAGE n/m key                     (plain line, load progress)
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
import sys
import threading
import traceback
from queue import Queue

DEFAULT_MODEL = "mlx-community/Hy-MT2-1.8B-4bit"

# Hy-MT2 is a dedicated translation model, not a general chat model: it is
# trained to answer this instruction shape with the translation and nothing else.
# Language names are spelled out because that is what the model card documents --
# codes like "zh-Hans" are not part of its training format.
LANGUAGE_NAMES = {
    "zh": "Chinese", "zh-hans": "Chinese", "zh-hant": "Traditional Chinese",
    "zh-cn": "Chinese", "zh-tw": "Traditional Chinese",
    "en": "English", "ja": "Japanese", "ko": "Korean", "fr": "French",
    "de": "German", "es": "Spanish", "pt": "Portuguese", "ru": "Russian",
    "it": "Italian", "ar": "Arabic", "hi": "Hindi", "th": "Thai",
    "vi": "Vietnamese", "id": "Indonesian", "tr": "Turkish", "pl": "Polish",
    "nl": "Dutch", "cs": "Czech", "uk": "Ukrainian", "he": "Hebrew",
}


def log(*a):
    print(*a, file=sys.stderr, flush=True)


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


def build_prompt(tokenizer, text: str, source: str, target: str) -> str:
    src = language_name(source, "English")
    tgt = language_name(target, "Chinese")
    instruction = (
        f"Translate the following segment into {tgt}, without additional "
        f"explanation.\n\n{text}"
    )
    if src:
        instruction = (
            f"Translate the following {src} segment into {tgt}, without "
            f"additional explanation.\n\n{text}"
        )
    messages = [{"role": "user", "content": instruction}]
    try:
        return tokenizer.apply_chat_template(messages, add_generation_prompt=True)
    except Exception:
        # No chat template: fall back to the raw instruction rather than failing.
        return instruction


def handle(model, tokenizer, req: dict):
    from mlx_lm import stream_generate
    from mlx_lm.sample_utils import make_sampler

    req_id = req.get("id")
    text = (req.get("text") or "").strip()
    if not text:
        emit({"id": req_id, "done": True})
        return

    prompt = build_prompt(tokenizer, text, req.get("source", ""), req.get("target", ""))
    # Greedy. Translation wants the most likely rendering, and sampling here
    # would make the same sentence translate differently on a retranslate.
    sampler = make_sampler(temp=0.0)
    # Generous relative to the input: CJK->Latin can expand, and a hard cap that
    # truncates mid-sentence is worse than spending a few extra tokens.
    max_tokens = max(64, min(1024, len(text) * 4))

    try:
        for chunk in stream_generate(model, tokenizer, prompt,
                                     max_tokens=max_tokens, sampler=sampler):
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
        except (ProcessLookupError, PermissionError):
            log(f"[parent] pid {parent_pid} is gone, exiting")
            os._exit(0)
        except Exception:
            return


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--exit-with-parent", type=int, default=0)
    args = parser.parse_args()

    if args.exit_with_parent:
        threading.Thread(target=watch_parent, args=(args.exit_with_parent,),
                         daemon=True).start()

    print("STAGE 1/1 translation", flush=True)

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

            model, tokenizer = load(args.model)
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
    ready.wait()
    if load_failed:
        # Swift waits for READY; without this it blocks for the full timeout
        # instead of surfacing the failure.
        print("FATAL translation model load failed", flush=True)
        sys.exit(1)

    print("READY", flush=True)
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
