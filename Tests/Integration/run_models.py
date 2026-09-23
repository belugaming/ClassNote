#!/usr/bin/env python3
"""Runs the local sidecars' model code against the real weights.

Not part of the unit suite: it downloads several GB and needs MLX (the CPU
build works on Linux, which is what the model-integration workflow uses). It
checks what the unit tests cannot -- that the prompts and decode steps written
against mlx-audio / mlx-lm produce sensible output from the actual models.

    python Tests/Integration/run_models.py r2t2 speech.wav "reference text"
    python Tests/Integration/run_models.py hymt
"""
import os
import sys
import time
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "Scripts"))


def words(text):
    return [w.strip(".,!?;:").lower() for w in text.split() if w.strip(".,!?;:")]


def word_overlap(hyp, ref):
    h, r = words(hyp), words(ref)
    hits = sum(1 for w in r if w in h)
    return hits / max(1, len(r))


def run_r2t2(wav_path, reference):
    import asr_server
    import r2t2_engine

    with wave.open(wav_path, "rb") as w:
        assert (w.getframerate(), w.getnchannels(), w.getsampwidth()) == (16000, 1, 2)
        pcm = w.readframes(w.getnframes())
    seconds = len(pcm) / 32000
    print(f"[r2t2] audio {seconds:.1f}s, reference: {reference!r}")

    t0 = time.time()
    path = r2t2_engine.resolve_model_path()
    model = r2t2_engine.R2T2Model(path)
    print(f"[r2t2] loaded {path} in {time.time() - t0:.1f}s")

    # Offline-style: one decode over the whole clip.
    audio = np.frombuffer(pcm, np.int16).astype(np.float32) / 32768.0
    t0 = time.time()
    offline = model.generate(audio, "", "English", "", 128)
    print(f"[r2t2] one-shot decode ({time.time() - t0:.1f}s): {offline!r}")

    # Streaming through the app's own line segmentation. CPU is slow, so the
    # step is larger than the app's 160 ms; the algorithm is the same.
    step_ms = int(os.environ.get("R2T2_STEP_MS", "640"))
    t = asr_server.R2T2Transcriber(model, "en", context="", step_ms=step_ms)
    frame = 3200  # 100 ms
    events = []
    t0 = time.time()
    for i in range(0, len(pcm), frame):
        new = t.feed(pcm[i:i + frame])
        for e in new:
            print(f"[r2t2]   {time.time() - t0:6.1f}s {e['type']}: {e['text']}")
        events += new
    events += t.finish()
    spent = time.time() - t0
    finals = [e for e in events if e["type"] == "final"]
    partials = [e["text"] for e in events if e["type"] == "partial"]
    streamed = " ".join(e["text"] for e in finals)
    print(f"[r2t2] streaming at {step_ms} ms steps took {spent:.1f}s (RTF {spent / seconds:.2f})")
    for e in finals:
        print(f"[r2t2]   final {e['startMs']:>6}-{e['endMs']:>6} end={e['sentenceEnd']}: {e['text']}")

    # Append-only: within a line, each partial extends the previous one.
    rewrites = 0
    for a, b in zip(partials, partials[1:]):
        if not b.startswith(a) and b and a and not a.startswith(b) and len(b) >= len(a):
            rewrites += 1
    overlap_offline = word_overlap(offline, reference)
    overlap_stream = word_overlap(streamed, reference)
    print(f"[r2t2] word overlap with reference: offline {overlap_offline:.0%}, "
          f"streaming {overlap_stream:.0%}, partial rewrites {rewrites}")
    assert overlap_offline >= 0.7, "one-shot decode does not match the reference"
    assert overlap_stream >= 0.6, "streaming decode does not match the reference"
    assert finals, "no final lines"


def run_hymt():
    from mlx_lm import load
    import translate_server

    path = translate_server.resolve_model_path(translate_server.DEFAULT_MODEL,
                                               translate_server.DEFAULT_REVISION)
    model, tokenizer = load(path)
    print("[hymt] chat template:", repr(getattr(tokenizer, "chat_template", ""))[:300])

    cases = [
        dict(text="It breaks glucose down into two molecules of pyruvate.",
             source="en", target="zh",
             context=["Glycolysis happens in the cytoplasm of every cell."],
             terms=[["pyruvate", "丙酮酸"]]),
        dict(text="and then it releases energy", source="en", target="zh"),
        dict(text="这个矩阵的特征值是二。", source="zh", target="en",
             terms=[["特征值", "eigenvalue"]]),
    ]
    from mlx_lm import generate
    from mlx_lm.sample_utils import make_logits_processors, make_sampler
    for case in cases:
        prompt = translate_server.build_prompt(tokenizer, case["text"], case["source"], case["target"],
                                               context=case.get("context"), terms=case.get("terms"))
        out = generate(model, tokenizer, prompt, max_tokens=128,
                       sampler=make_sampler(temp=0.0),
                       logits_processors=make_logits_processors(repetition_penalty=1.05))
        print(f"[hymt] {case['text']!r} -> {out!r}")
        assert out.strip(), "empty translation"
        if case.get("context"):
            # The background must be read, not translated along with the line.
            assert "细胞质" not in out, "the context sentence was translated too"
        for src, tgt in case.get("terms", []):
            if src in case["text"]:
                assert tgt.lower() in out.lower(), f"glossary term {tgt!r} not used"


def run_simt_plumbing():
    """MLXSimulModel's prompt cache, logits processors and forced commit,
    exercised with a small model of T3PO's architecture (Qwen2.5). T3PO itself
    is 28 GB before conversion, too big for a CI runner; this checks the code
    around it, not translation quality."""
    from huggingface_hub import snapshot_download
    import simt_server

    path = snapshot_download("mlx-community/Qwen2.5-0.5B-Instruct-4bit")
    model = simt_server.MLXSimulModel(path)
    session = simt_server.SimulSession(model, "en2zh", terms=[["cell", "细胞"]])
    lines = ["The cell membrane", "is selectively permeable.", "It controls what enters",
             "and what leaves the cell."]
    t0 = time.time()
    for line in lines:
        events = session.feed(line)
        print(f"[simt] feed {line!r} -> {events} (cached {len(model.cached)} tokens)")
    events = session.flush()
    print(f"[simt] flush -> {events}; {time.time() - t0:.1f}s")
    # The cache must track the prompt: a follow-up call reuses most of it.
    before = len(model.cached)
    prompt = simt_server.chat_prompt(simt_server.build_user_message(
        "en2zh", session.history_text(), "next"))
    out = model.complete(prompt, force=True, latency="low")
    print(f"[simt] forced completion {out!r}, cache {before} -> {len(model.cached)}")
    assert out.strip(), "a forced call must not come back empty"
    assert len(model.cached) > 0


if __name__ == "__main__":
    what = sys.argv[1]
    if what == "r2t2":
        run_r2t2(sys.argv[2], sys.argv[3])
    elif what == "hymt":
        run_hymt()
    elif what == "simt":
        run_simt_plumbing()
    else:
        raise SystemExit(f"unknown target {what}")
