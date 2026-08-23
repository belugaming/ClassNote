#!/usr/bin/env python3
"""Local streaming ASR sidecar for ClassNote.

One process serves exactly one client. Started by LocalASRProcessManager.swift,
which waits for the ``READY port=N`` line on stdout before connecting.

WebSocket protocol
------------------
Client -> server:
  * binary frames -- raw Int16LE mono PCM at 16 kHz
  * text frames (JSON):
      {"type": "config", "language": "zh", "hotwords": "..."}
      {"type": "eof"}                       flush and finalize the live stream
      {"type": "file", "path": "/abs.wav"}  offline transcribe a whole file

Server -> client (JSON text frames), all carrying the same envelope so the
Swift decoder can treat them uniformly:
  {"type": "status",   "stage": "loading"|"ready"}
  {"type": "partial",  "segmentId", "startMs", "endMs", "text"}
  {"type": "final",    ...}     first-pass (streaming) text for a segment
  {"type": "revised",  ...}     second-pass (offline) correction of that segment
  {"type": "progress", "completed", "total"}
  {"type": "eof"}
  {"type": "error",    "message"}

Engine
------
Everything runs on MLX via `mlx-audio`; there is no PyTorch/FunASR dependency
and no language-dependent model set:

  VAD       silero (mlx_audio.realtime_vad) -- utterance boundaries
  pass 1    nemotron-3.5-asr-streaming-0.6b -- low-latency partials, 40 langs
  pass 2    Qwen3-ASR                       -- authoritative text, 52 langs,
                                               emits its own punctuation/casing

The invariant that makes this work: **pass 1 output is only ever a draft.** It is
emitted as `final` so the UI has something immediately, but pass 2 always runs on
the complete utterance buffer and supersedes it via `revised`. Dropped streaming
chunks, reset caches and missing words therefore cannot corrupt the transcript --
which is what went wrong in the previous FunASR/Nemotron split, where English had
no second pass and holed streaming text was committed as-is.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import json
import os
import sys
import time
import traceback
from collections import deque
from concurrent.futures import ThreadPoolExecutor

import numpy as np
import websockets

SAMPLE_RATE = 16000
BYTES_PER_MS = SAMPLE_RATE * 2 // 1000  # Int16 mono -> 32 bytes per ms

# Audio handed to the streaming encoder per call. 320ms is nemotron-3.5's native
# multilingual chunk geometry; other values re-derive the subsampling and are
# slower for no accuracy gain.
STREAM_STEP_MS = 320
STREAM_STEP_BYTES = STREAM_STEP_MS * BYTES_PER_MS

# Trained look-ahead pairs are [56,0] / [56,3] / [56,6] / [56,13]. Measured on an
# M-series machine over a 10.8s clip: [56,13] RTF 0.38, [56,3] RTF 0.91,
# [56,0] RTF 1.64. Smaller right context is *slower*, not faster -- the chunks get
# finer so the per-call overhead is paid more often -- and it is also less
# accurate. [56,13] is simply the best point on both axes, and is token-identical
# to the offline path.
DEFAULT_ATT_CONTEXT = [56, 13]

# If the streaming pass falls this far behind real time, start skipping chunks.
# Partials are disposable (pass 2 produces the authoritative text), so dropping
# them keeps latency bounded instead of accumulating a backlog that would
# eventually stall the socket entirely.
MAX_STREAM_BACKLOG_MS = 2400

# Force-cut an utterance VAD never closes, so a long monologue still produces
# finals instead of growing one unbounded buffer.
MAX_UTTERANCE_MS = 20_000

# Sentence-ending punctuation. VAD rarely reports an endpoint during continuous
# speech, so without this a speaker who does not pause produces one wall of text
# until the 20s force-cut. Cutting on punctuation instead keeps each committed
# line to roughly one spoken sentence, which is what makes it readable.
SENTENCE_END_CHARS = ".!?。！？…"
# Don't cut on a period that is probably an abbreviation or decimal ("Dr.",
# "3.5"), and don't emit a fragment so short it reads as noise.
MIN_SENTENCE_CHARS = 12
# Once a segment reaches this, cut at the next sentence end even mid-thought, so
# a run-on speaker still gets broken into readable lines.
SOFT_CUT_MS = 6_000
# When no speech is active, keep only a short pre-roll so pass 2 sees the onset
# of a word instead of starting mid-syllable.
PREROLL_MS = 300

STREAMING_REPO = "mlx-community/nemotron-3.5-asr-streaming-0.6b"
# Second-pass model, keyed by quality. "streaming" is the odd one out: it loads
# no second pass at all, leaving only the streaming model resident. That halves
# the footprint, which is what makes the engine usable on an 8 GB machine, at the
# cost of the corrections pass 2 provides ("Mitchandria" -> "mitochondria").
OFFLINE_REPOS = {
    "light": "mlx-community/Qwen3-ASR-0.6B-8bit",
    "standard": "mlx-community/Qwen3-ASR-1.7B-8bit",
}
QUALITY_CHOICES = ["streaming"] + sorted(OFFLINE_REPOS)
VAD_REPO = "mlx-community/silero-vad"

# Surfaced to the user when they import a file in single-pass mode.
L10N_FILE_NEEDS_SECOND_PASS = "单模型模式不支持文件导入，请在设置中关闭它。"


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def _is_cjk(ch: str) -> bool:
    o = ord(ch)
    return (
        0x3000 <= o <= 0x303F
        or 0x3400 <= o <= 0x4DBF
        or 0x4E00 <= o <= 0x9FFF
        or 0xF900 <= o <= 0xFAFF
        or 0xFF00 <= o <= 0xFFEF
    )


def pcm_to_float(pcm: bytes) -> np.ndarray:
    return np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0


# ---------------------------------------------------------------------------
# Streaming session
# ---------------------------------------------------------------------------


class PushStream:
    """Push-driven wrapper around nemotron-3.5's cache-aware streaming encoder.

    mlx-audio only exposes a pull-style ``stream_generate(whole_audio)`` generator,
    but audio here arrives frame by frame from a socket. This mirrors
    ``Model._decode_prompted_chunks`` with the RNNT decoder state hoisted onto the
    instance, so one chunk can be fed at a time.

    Both the mel front end and the encoder keep bounded, incremental state -- no
    part of the utterance is recomputed as it grows.
    """

    def __init__(self, model, language: str, att_context_size=None):
        from mlx_audio.stt.models.nemotron_asr.audio import StreamingLogMelSpectrogram
        from mlx_audio.stt.models.nemotron_asr.streaming import ConformerStreamingState

        self.m = model
        self.language = language
        self._mel = StreamingLogMelSpectrogram(model.preprocessor_config)
        self._state = ConformerStreamingState(
            model.encoder,
            att_context_size=att_context_size or DEFAULT_ATT_CONTEXT,
        )
        self._last_token = model.blank_id
        self._hidden = None
        self._hyp = []
        self._global_time = 0
        self._frame_sec = (
            model.encoder_config.subsampling_factor
            * model.preprocessor_config.hop_length
            / model.preprocessor_config.sample_rate
        )

    def push(self, samples: np.ndarray, final: bool = False) -> str:
        """Feed one chunk of float32 16 kHz audio; returns the cumulative text."""
        import mlx.core as mx

        mel = self._mel.push(mx.array(samples.astype(np.float32)), final=final)
        if mel is not None and mel.shape[1] > 0:
            for encoded in self._state.push(mel, final=final):
                self._decode(self.m.apply_prompt(encoded, self.language))
        return self.text

    def _decode(self, prompted):
        import mlx.core as mx
        from mlx_audio.stt.models.nemotron_asr import tokenizer as tok
        from mlx_audio.stt.models.nemotron_asr.nemotron_asr import AlignedToken

        chunk_len = prompted.shape[1]
        t = 0
        new_symbols = 0
        while t < chunk_len:
            feature = prompted[:, t : t + 1]
            cur = (
                mx.array([[self._last_token]], dtype=mx.int32)
                if self._last_token != self.m.blank_id
                else None
            )
            dec_out, (h, c) = self.m.decoder(cur, self._hidden)
            dec_out = dec_out.astype(feature.dtype)
            proposed = (h.astype(feature.dtype), c.astype(feature.dtype))
            pred = int(mx.argmax(self.m.joint(feature, dec_out)))
            if pred != self.m.blank_id:
                self._last_token = pred
                self._hidden = proposed
                if not tok.is_special_token(self._last_token, self.m.vocabulary):
                    self._hyp.append(
                        AlignedToken(
                            self._last_token,
                            start=(self._global_time + t) * self._frame_sec,
                            duration=self._frame_sec,
                            text=tok.decode([self._last_token], self.m.vocabulary),
                        )
                    )
                new_symbols += 1
                if self.m.max_symbols is not None and new_symbols >= self.m.max_symbols:
                    t += 1
                    new_symbols = 0
            else:
                t += 1
                new_symbols = 0
        self._global_time += chunk_len

    @property
    def text(self) -> str:
        if not self._hyp:
            return ""
        from mlx_audio.stt.models.nemotron_asr.nemotron_asr import (
            sentences_to_result,
            tokens_to_sentences,
        )

        return sentences_to_result(tokens_to_sentences(self._hyp)).text


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------


class Models:
    """Lazily constructed MLX models, shared by the streaming and file paths.

    Loading happens once at process start, before the READY line, because weights
    are fetched from Hugging Face on a first run and that takes tens of seconds.
    """

    def __init__(self, language: str = "zh", quality: str = "standard",
                 att_context_size=None, on_stage=None):
        # nemotron-3.5 and Qwen3-ASR are both multilingual, so unlike the previous
        # FunASR/paraformer setup there is no zh-vs-en model set to choose. The
        # language is only a decoding hint.
        self.language = (language or "zh").strip() or "zh"
        self.quality = quality if quality in QUALITY_CHOICES else "standard"
        self.att_context_size = att_context_size or DEFAULT_ATT_CONTEXT
        self.on_stage = on_stage
        self.streaming = None
        self.offline = None
        self._vad_model = None

    @property
    def single_pass(self) -> bool:
        """True when only the streaming model is loaded, so nothing revises."""
        return self.quality == "streaming"

    @property
    def stream_language(self) -> str:
        """nemotron prompts with a language id; map the app's code onto it."""
        lang = self.language.lower()
        if lang.startswith("zh"):
            return "zh"
        if lang == "auto":
            return "en"
        return lang.split("-")[0]

    def load(self):
        # mlx-audio and huggingface_hub print progress bars to stdout, which is the
        # channel Swift scans for READY. Redirect anything they print to stderr.
        with contextlib.redirect_stdout(sys.stderr):
            self._load()

    def _load(self):
        from mlx_audio.stt.utils import load as load_stt

        total = 2 if self.quality == "streaming" else 3
        step = 0

        def stage(key: str):
            """Report a loading step. Only the key crosses the boundary; the app
            localizes it, so the sidecar carries no UI strings."""
            nonlocal step
            step += 1
            log(f"[models] ({step}/{total}) {key}")
            if self.on_stage:
                self.on_stage(key, step, total)

        stage("streaming")
        self.streaming = load_stt(STREAMING_REPO)

        if self.quality == "streaming":
            log("[models] single-pass mode: no second pass will run")
            self.offline = None
        else:
            stage("offline")
            self.offline = load_stt(OFFLINE_REPOS[self.quality])

        # The VAD weights are fetched here so a first run pays the download cost
        # before READY, but the StreamingVad wrapper itself is built later, on the
        # thread that will drive it -- see Session._ensure_vad.
        stage("vad")
        self._vad_model = self._load_vad_model()

        # First inference pays for kernel compilation and lazy weight transfer.
        # Burn that on silence now, before the user's first words.
        if self.on_stage:
            self.on_stage("warmup", total, total)
        log("[models] warming up")
        silence = np.zeros(STREAM_STEP_MS * SAMPLE_RATE // 1000, dtype=np.float32)
        try:
            warm = PushStream(self.streaming, self.stream_language,
                              self.att_context_size)
            warm.push(silence, final=True)
        except Exception as exc:
            log(f"[models] streaming warmup failed (non-fatal): {exc}")
        if self.offline is not None:
            try:
                import mlx.core as mx

                self.offline.generate(mx.array(np.zeros(SAMPLE_RATE, dtype=np.float32)))
            except Exception as exc:
                log(f"[models] offline warmup failed (non-fatal): {exc}")
        log("[models] ready")

    def _load_vad_model(self):
        """Fetch the VAD weights. Returns None if unavailable, in which case the
        timed cuts alone drive segmentation -- degraded but still usable."""
        try:
            from mlx_audio.vad.utils import load as load_vad

            return load_vad(VAD_REPO)
        except Exception as exc:
            log(f"[models] VAD unavailable, relying on timed cuts only: {exc}")
            return None

    def make_vad(self):
        """Build a StreamingVad. MUST be called on the thread that will drive it.

        MLX state is thread-affine: an object built on one thread and evaluated on
        another dies with "There is no Stream(gpu, 0) in current thread". The
        weights are safe to share, but the wrapper carries a live per-call state
        array, so it has to be constructed where it is used.
        """
        if self._vad_model is None:
            return None
        try:
            from mlx_audio.realtime_vad import ServerVadConfig, StreamingVad

            return StreamingVad(
                self._vad_model,
                ServerVadConfig(
                    threshold=0.5,
                    prefix_padding_ms=PREROLL_MS,
                    silence_duration_ms=500,
                ),
            )
        except Exception as exc:
            log(f"[models] VAD construction failed, using timed cuts only: {exc}")
            return None

    def new_stream(self) -> PushStream:
        return PushStream(self.streaming, self.stream_language, self.att_context_size)


# ---------------------------------------------------------------------------
# Session
# ---------------------------------------------------------------------------


class Session:
    def __init__(self, ws, models: Models, default_language: str | None):
        self.ws = ws
        self.models = models
        self.language = default_language

        # MLX state is thread-affine (see Models.make_vad), so every stateful
        # object must live on exactly one thread. Two single-thread pools rather
        # than one shared pool:
        #   rt      VAD + streaming -- the real-time path, must never stall
        #   offline pass 2 -- seconds per utterance, would block partials if it
        #           shared the rt thread
        # A multi-worker pool would scatter consecutive calls across threads and
        # break non-deterministically.
        self._rt_pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="asr-rt")
        self._offline_pool = ThreadPoolExecutor(max_workers=1,
                                                thread_name_prefix="asr-offline")
        self._vad = None
        self._vad_ready = False

        self.asr_buf = bytearray()
        self.utt_buf = bytearray()
        self.preroll = bytearray()
        self.stream_ms = 0
        self.segment_start_ms = 0
        self.segment_id = 0
        self.partial_text = ""
        self.speech_active = False

        self._stream = None
        self._offline_lock = asyncio.Lock()
        self._revisions: set[asyncio.Task] = set()

        self._stream_calls = 0
        # A bounded window, so the reported figure doesn't go stale over a
        # multi-hour session and still reflects current speed.
        self._recent_times: deque[float] = deque(maxlen=100)
        self._skipped_ms = 0

        # Audio arrives faster than the streaming model can consume it when the
        # machine is loaded, so reading and processing are separate tasks joined
        # by this queue.
        self._inbox: asyncio.Queue = asyncio.Queue()
        self._worker: asyncio.Task | None = None
        self._queued_bytes = 0

    # ---- plumbing -------------------------------------------------------

    async def _run(self, fn, *a, **kw):
        """Real-time path: VAD and the streaming encoder."""
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(self._rt_pool, lambda: fn(*a, **kw))

    async def _run_offline(self, fn, *a, **kw):
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(self._offline_pool, lambda: fn(*a, **kw))

    async def _send(self, payload: dict):
        try:
            await self.ws.send(json.dumps(payload, ensure_ascii=False))
        except websockets.ConnectionClosed:
            pass

    async def _emit(self, kind: str, text: str, start_ms: int, end_ms: int,
                    segment_id: int | None = None):
        if not text:
            return
        await self._send({
            "type": kind,
            "segmentId": self.segment_id if segment_id is None else segment_id,
            "startMs": max(0, int(start_ms)),
            "endMs": max(0, int(end_ms)),
            "text": text,
        })

    # ---- model passes ---------------------------------------------------

    def _streaming_sync(self, pcm: bytes, is_final: bool) -> str:
        """Returns the cumulative text for the current segment."""
        if self._stream is None:
            self._stream = self.models.new_stream()
        samples = pcm_to_float(pcm) if pcm else np.zeros(0, dtype=np.float32)
        return self._stream.push(samples, final=is_final)

    def _vad_sync(self, pcm: bytes):
        """Runs on the rt thread, which is also where the VAD gets built."""
        if not self._vad_ready:
            self._vad_ready = True
            self._vad = self.models.make_vad()
        if self._vad is None:
            return []
        return self._vad.process(pcm_to_float(pcm))

    def _offline_sync(self, pcm: bytes) -> str:
        import mlx.core as mx

        with contextlib.redirect_stdout(sys.stderr):
            res = self.models.offline.generate(mx.array(pcm_to_float(pcm)))
        return (getattr(res, "text", "") or "").strip()

    # ---- streaming driver -----------------------------------------------

    async def start(self):
        """Start the processing task that consumes queued audio."""
        self._worker = asyncio.create_task(self._process_loop())

    def enqueue(self, pcm: bytes):
        """Called from the socket read loop. Never blocks on inference."""
        if pcm:
            self._queued_bytes += len(pcm)
            self._inbox.put_nowait(pcm)

    async def _process_loop(self):
        while True:
            pcm = await self._inbox.get()
            self._queued_bytes = max(0, self._queued_bytes - len(pcm))
            try:
                await self.feed(pcm)
            except Exception:
                log(f"[process] {traceback.format_exc()}")

    async def drain_inbox(self):
        """Wait until every queued frame has been processed."""
        while not self._inbox.empty():
            await asyncio.sleep(0.02)

    async def feed(self, pcm: bytes):
        """Consume one PCM frame from the client."""
        if not pcm:
            return
        if len(pcm) % 2:
            pcm = pcm[:-1]  # keep Int16 alignment across frame boundaries
            if not pcm:
                return

        self.stream_ms += len(pcm) // BYTES_PER_MS
        self.asr_buf.extend(pcm)

        if self.speech_active:
            self.utt_buf.extend(pcm)
        else:
            # Not in speech yet: hold a rolling pre-roll so that when VAD does
            # fire we can prepend the audio just before the detected onset.
            self.preroll.extend(pcm)
            keep = PREROLL_MS * BYTES_PER_MS
            if len(self.preroll) > keep:
                del self.preroll[: len(self.preroll) - keep]

        await self._drain_vad(pcm)
        await self._drain_streaming()

        # Safety valve: VAD occasionally never reports an endpoint on
        # continuous speech. Cut anyway so the user keeps getting finals.
        # Both of these fire while the speaker is still talking, so the turn stays
        # open and the next segment starts accumulating right away.
        if self.speech_active and self._should_cut_on_sentence():
            await self.close_segment(continuing=True)
            return

        if self.speech_active and len(self.utt_buf) >= MAX_UTTERANCE_MS * BYTES_PER_MS:
            log("[vad] max utterance length reached, forcing a cut")
            await self.close_segment(continuing=True)

    def _should_cut_on_sentence(self) -> bool:
        """Whether the partial text ends on a sentence the user can read as one line."""
        text = self.partial_text.rstrip()

        held_ms = len(self.utt_buf) // BYTES_PER_MS
        if held_ms >= SOFT_CUT_MS and text:
            # Prefer cutting where the speaker made a natural pause -- comma,
            # semicolon, or clause-ending mark. Failing that, just cut: a reader
            # handles an abrupt break better than a wall of text.
            if text[-1] in ",;，；:：":
                return True
            log(f"[sentence] soft cut after {held_ms}ms (no punctuation)")
            return True

        if len(text) < MIN_SENTENCE_CHARS or text[-1] not in SENTENCE_END_CHARS:
            return False
        if text[-1] == "." and len(text) >= 2:
            # "3.5" -- a period between digits is a decimal, not a sentence end.
            if text[-2].isdigit():
                return False
            # "Dr." / "Mr." / "U.S." -- a very short trailing word is far more
            # likely to be an abbreviation than a sentence. Capped at two letters
            # on purpose: three would also swallow genuine enders like "not."
            # or "can.", which are common in speech, and a missed cut here is
            # harmless anyway -- the 6s soft cut still breaks the line.
            token = text.rsplit(" ", 1)[-1]
            letters = [c for c in token if c.isalpha()]
            if letters and len(letters) <= 2:
                return False
        return True

    async def _drain_vad(self, pcm: bytes):
        """Feed the streaming VAD and act on turn events."""
        try:
            events = await self._run(self._vad_sync, pcm)
        except Exception as exc:
            log(f"[vad] {exc}")
            events = []

        if self._vad is None:
            # No usable VAD. Hold the segment permanently open so audio still
            # accumulates in utt_buf and the timed cuts drive segmentation.
            # Without this, speech_active never flips, utt_buf stays empty, and
            # pass 2 would "revise" a full sentence down to the 300ms pre-roll.
            if not self.speech_active:
                self.speech_active = True
                self.segment_start_ms = max(0, self.stream_ms - PREROLL_MS)
                self.utt_buf = bytearray(self.preroll)
                self.preroll.clear()
                self.utt_buf.extend(pcm)
            return

        from mlx_audio.realtime_vad import TurnEventKind

        for ev in events:
            if ev.kind == TurnEventKind.SPEECH_STARTED and not self.speech_active:
                self.speech_active = True
                self.segment_start_ms = max(0, self.stream_ms - PREROLL_MS)
                # Seed the utterance with the pre-roll so pass 2 hears the word
                # onset, not the middle of it.
                self.utt_buf = bytearray(self.preroll)
                self.preroll.clear()
            elif ev.kind == TurnEventKind.SPEECH_STOPPED and self.speech_active:
                await self.close_segment()

    async def _drain_streaming(self):
        """Run the streaming model on every complete stride available."""
        step = STREAM_STEP_BYTES
        step_ms = STREAM_STEP_MS
        while len(self.asr_buf) >= step:
            # Behind real time: drop this stride's partial instead of running the
            # model on it. Most of the lag sits in the inbox rather than in
            # asr_buf, so the backlog must be measured across both -- otherwise
            # this check reports nothing wrong while latency grows unbounded.
            #
            # The audio is already in utt_buf, so pass 2 still transcribes it in
            # full: only the intermediate partial is lost, never transcript text.
            backlog_ms = (len(self.asr_buf) + self._queued_bytes) // BYTES_PER_MS
            if backlog_ms > MAX_STREAM_BACKLOG_MS:
                del self.asr_buf[:step]
                self._skipped_ms += step_ms
                if self._skipped_ms % (step_ms * 5) == 0:
                    log(f"[streaming] behind by {backlog_ms}ms, "
                        f"{self._skipped_ms}ms of partials skipped so far")
                # Skipping leaves a hole in the encoder cache, so its next output
                # would splice across missing audio. Reset and restart the partial.
                self._stream = None
                continue

            chunk = bytes(self.asr_buf[:step])
            del self.asr_buf[:step]
            started = time.monotonic()
            try:
                text = await self._run(self._streaming_sync, chunk, False)
            except Exception as exc:
                log(f"[streaming] {exc}")
                continue
            elapsed = time.monotonic() - started
            self._stream_calls += 1
            # Report a moving average, not a cumulative one: over a long lecture a
            # lifetime mean stops responding to change, so a real slowdown would
            # stay hidden behind hours of healthy samples.
            self._recent_times.append(elapsed)
            if self._stream_calls % 25 == 0:
                mean = sum(self._recent_times) / len(self._recent_times)
                log(f"[streaming] {self._stream_calls} chunks, "
                    f"recent mean {mean * 1000:.0f}ms/{step_ms}ms audio "
                    f"(RTF {mean / (step_ms / 1000):.2f})")
            if text and text != self.partial_text:
                self.partial_text = text
                await self._emit("partial", self.partial_text,
                                 self.segment_start_ms, self.stream_ms)

    async def close_segment(self, end_ms: int | None = None,
                            continuing: bool = False):
        """Finish the current utterance: emit a streaming final, then a revision.

        ``continuing`` distinguishes the two reasons a segment ends. VAD reporting
        an endpoint means the speaker actually stopped, so the turn closes. A soft
        or max-length cut fires *mid-sentence* on a speaker who never pauses, and
        must open the next segment immediately -- otherwise ``speech_active`` stays
        False until VAD sees a fresh onset, ``utt_buf`` never refills, and pass 2
        revises a whole sentence down to the 300ms pre-roll.
        """
        if not self.utt_buf:
            self.speech_active = continuing
            return

        utterance = bytes(self.utt_buf)
        end = end_ms if end_ms is not None else self.stream_ms
        start = self.segment_start_ms

        # Flush whatever streaming audio is still buffered, with final=True so the
        # encoder releases its tail, then emit the first-pass result immediately.
        tail = bytes(self.asr_buf)
        self.asr_buf.clear()
        try:
            text = await self._run(self._streaming_sync, tail, True)
            if text:
                self.partial_text = text
        except Exception as exc:
            log(f"[streaming] final flush failed: {exc}")

        first_pass = self.partial_text
        segment_id = self.segment_id
        if first_pass:
            await self._emit("final", first_pass, start, end, segment_id=segment_id)

        # Reset streaming state and advance to the next segment immediately, so
        # audio arriving during pass 2 is handled without waiting.
        self._stream = None
        self.partial_text = ""
        self.utt_buf.clear()
        self.speech_active = continuing
        self.segment_id += 1
        self.segment_start_ms = end

        # Single-pass mode has nothing to revise with, so the streaming text is
        # already this segment's final answer.
        if self.models.single_pass:
            return

        # Pass 2 is slower than a single streaming stride. Run it in the
        # background so reading audio never blocks on it; the revision arrives out
        # of band and the client matches it by segmentId.
        task = asyncio.create_task(
            self._revise(utterance, first_pass, segment_id, start, end)
        )
        self._revisions.add(task)
        task.add_done_callback(self._revisions.discard)

    async def _revise(self, utterance: bytes, first_pass: str,
                      segment_id: int, start: int, end: int):
        async with self._offline_lock:
            try:
                revised = await self._run_offline(self._offline_sync, utterance)
            except Exception as exc:
                log(f"[offline] {exc}")
                return
        if not revised:
            return
        if first_pass:
            if revised != first_pass:
                await self._emit("revised", revised, start, end, segment_id=segment_id)
        else:
            # Streaming produced nothing (common for very short utterances); the
            # offline result becomes the segment's only final.
            await self._emit("final", revised, start, end, segment_id=segment_id)

    async def finish(self):
        """Client signalled end of audio: close any open utterance and drain."""
        # Frames may still be queued behind the streaming model; process them
        # before closing, or the tail of the recording would be dropped.
        await self.drain_inbox()

        if self.utt_buf or self.asr_buf:
            if not self.speech_active and not self.utt_buf:
                # Audio arrived but VAD never opened a segment; still transcribe it.
                self.utt_buf = bytearray(self.preroll)
                self.preroll.clear()
            await self.close_segment()

        # Revisions run in the background, so eof must wait for them. Sending it
        # early makes the client disconnect while the last segment's correction is
        # still being computed, and that text is then lost.
        while self._revisions:
            await asyncio.gather(*list(self._revisions), return_exceptions=True)

        await self._send({"type": "eof"})

    async def close(self):
        """Tear down background tasks so the process can exit cleanly."""
        if self._worker is not None:
            self._worker.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._worker
            self._worker = None
        for task in list(self._revisions):
            task.cancel()
        if self._revisions:
            await asyncio.gather(*list(self._revisions), return_exceptions=True)
        self._rt_pool.shutdown(wait=False)
        self._offline_pool.shutdown(wait=False)

    # ---- file import ----------------------------------------------------

    def _file_sync(self, path: str):
        # File import needs the offline model: there is no live audio to stream.
        if self.models.offline is None:
            raise RuntimeError(L10N_FILE_NEEDS_SECOND_PASS)

        """Transcribe a whole file, one entry per recognized sentence.

        Qwen3-ASR carries its own segmentation and timestamps, so unlike the old
        FunASR path this needs no separate VAD pass over the file.
        """
        with contextlib.redirect_stdout(sys.stderr):
            res = self.models.offline.generate(path)

        sentences = []
        for seg in getattr(res, "segments", None) or []:
            text = (getattr(seg, "text", "") or "").strip()
            if not text:
                continue
            sentences.append({
                "text": text,
                "start": int(getattr(seg, "start", 0.0) * 1000),
                "end": int(getattr(seg, "end", 0.0) * 1000),
            })
        if not sentences:
            text = (getattr(res, "text", "") or "").strip()
            if text:
                sentences.append({"text": text, "start": 0, "end": 0})
        return sentences

    async def transcribe_file(self, path: str):
        if not os.path.exists(path):
            await self._send({"type": "error", "message": f"文件不存在: {path}"})
            return
        await self._send({"type": "progress", "completed": 0, "total": 1})
        try:
            sentences = await self._run_offline(self._file_sync, path)
        except Exception as exc:
            log(f"[file] {traceback.format_exc()}")
            await self._send({"type": "error", "message": f"文件转写失败: {exc}"})
            return

        for sent in sentences:
            await self._emit("final", sent["text"], sent["start"], sent["end"])
            self.segment_id += 1
        await self._send({"type": "progress", "completed": 1, "total": 1})
        await self._send({"type": "eof"})


async def _exit_when_parent_gone(parent_pid: int, interval: float = 5.0):
    """Exit once the app that spawned us is gone.

    The sidecar is kept warm across recordings, so nothing else would reap it if
    the app crashed or was force-quit -- it would sit there holding several GB of
    models and its port. signal 0 only checks whether the pid is still alive.
    """
    while True:
        await asyncio.sleep(interval)
        try:
            os.kill(parent_pid, 0)
        except (ProcessLookupError, PermissionError):
            log(f"[parent] pid {parent_pid} is gone, exiting")
            os._exit(0)
        except Exception:
            return


async def handle_connection(ws, models: Models, default_language: str | None):
    session = Session(ws, models, default_language)
    await session._send({"type": "status", "stage": "ready"})
    await session.start()
    try:
        async for message in ws:
            if isinstance(message, (bytes, bytearray)):
                # Hand off without awaiting inference: the processing task runs
                # independently so the socket is always drained promptly. If we
                # awaited here, frames would pile up invisibly in the websocket
                # receive buffer and partials would fall minutes behind.
                session.enqueue(bytes(message))
                continue

            try:
                cmd = json.loads(message)
            except json.JSONDecodeError:
                log(f"[ws] ignoring non-JSON text frame: {message[:80]!r}")
                continue

            kind = cmd.get("type")
            if kind == "config":
                lang = cmd.get("language")
                # "auto" is the app's own sentinel. Both models are multilingual,
                # so unlike the old FunASR setup a language change here needs no
                # sidecar restart -- it only re-prompts the streaming decoder.
                session.language = lang if lang and lang != "auto" else None
                if lang and lang != "auto" and lang != models.language:
                    models.language = lang
                    log(f"[ws] language switched to {lang!r}")
            elif kind == "eof":
                await session.finish()
            elif kind == "file":
                await session.transcribe_file(cmd.get("path", ""))
            else:
                log(f"[ws] unknown command: {kind}")
    except websockets.ConnectionClosed:
        log("[ws] client disconnected")
    except Exception:
        log(f"[ws] {traceback.format_exc()}")
        await session._send({"type": "error", "message": "本地引擎内部错误"})
    finally:
        await session.close()


def _parse_att_context(value: str) -> list:
    try:
        left, right = (int(x) for x in value.split(","))
        return [left, right]
    except Exception:
        log(f"[args] bad --att-context {value!r}, using {DEFAULT_ATT_CONTEXT}")
        return list(DEFAULT_ATT_CONTEXT)


async def main():
    parser = argparse.ArgumentParser()
    # --engine and --device are accepted but ignored: both models are multilingual
    # and MLX has no device choice. They are kept so an older build of the app,
    # which still passes them, keeps working against this sidecar.
    parser.add_argument("--engine", default="mlx")
    parser.add_argument("--device", default="auto")
    parser.add_argument("--offline-device", default="auto")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--language", default="zh",
                        help="source language hint for the decoder")
    parser.add_argument("--quality", default="standard",
                        choices=QUALITY_CHOICES,
                        help="picks the second-pass model size")
    parser.add_argument("--att-context", default=None,
                        help="streaming look-ahead as 'left,right'; "
                             "see DEFAULT_ATT_CONTEXT for why 56,13 is the default")
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--exit-with-parent", type=int, default=0,
                        help="pid to watch; exit when it goes away")
    args = parser.parse_args()

    att = _parse_att_context(args.att_context) if args.att_context else None

    # Model loading happens before the WebSocket exists, so progress has to go out
    # on stdout -- the same channel Swift already reads for READY. Without this the
    # app looks frozen while weights load.
    def emit_stage(key: str, step: int, total: int):
        print(f"STAGE {step}/{total} {key}", flush=True)

    models = Models(language=args.language, quality=args.quality,
                    att_context_size=att, on_stage=emit_stage)
    try:
        await asyncio.get_running_loop().run_in_executor(None, models.load)
    except Exception:
        log(f"[fatal] model load failed: {traceback.format_exc()}")
        # Swift waits for READY on stdout; without this it would block for the
        # full timeout instead of surfacing the failure.
        print("FATAL model load failed", flush=True)
        sys.exit(1)

    async def handler(ws):
        await handle_connection(ws, models, args.language)

    if args.exit_with_parent:
        asyncio.create_task(_exit_when_parent_gone(args.exit_with_parent))

    server = await websockets.serve(
        handler, "127.0.0.1", args.port,
        max_size=None,        # audio frames are small, but never truncate one
        ping_interval=20,
        ping_timeout=60,      # model loading can stall the loop briefly
    )
    print(f"READY port={args.port}", flush=True)
    await server.wait_closed()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
