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

Two-pass design mirrors runtime/python/websocket/funasr_wss_server.py from the
FunASR repo: FSMN-VAD finds utterance boundaries, paraformer-zh-streaming emits
low-latency partials, and paraformer-zh + ct-punc re-transcribes each finished
utterance for an accurate, punctuated replacement.
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
from concurrent.futures import ThreadPoolExecutor

import websockets

SAMPLE_RATE = 16000
BYTES_PER_MS = SAMPLE_RATE * 2 // 1000  # Int16 mono -> 32 bytes per ms

# [0, 10, 5] => 600ms lookahead chunks, the config FunASR documents for
# paraformer-zh-streaming. chunk_size[1] * 960 samples is the required stride.
ASR_CHUNK_SIZE = [0, 10, 5]
ENCODER_LOOK_BACK = 4
DECODER_LOOK_BACK = 1

ASR_STEP_MS = ASR_CHUNK_SIZE[1] * 60          # 600 ms
ASR_STEP_BYTES = ASR_CHUNK_SIZE[1] * 960 * 2  # 19200 bytes
VAD_STEP_MS = 200
VAD_STEP_BYTES = VAD_STEP_MS * BYTES_PER_MS

# If the streaming pass falls this far behind real time, start skipping chunks.
# Partials are disposable (the offline pass produces the authoritative text), so
# dropping them keeps latency bounded instead of accumulating a backlog that
# would eventually stall the socket entirely.
MAX_STREAM_BACKLOG_MS = 2400

# Force-cut an utterance VAD never closes, so a long monologue still produces
# finals instead of growing one unbounded buffer.
MAX_UTTERANCE_MS = 20_000
# When no speech is active, keep only a short pre-roll so the offline pass sees
# the onset of a word instead of starting mid-syllable.
PREROLL_MS = 300


# Trailing silence that ends an utterance for engines without their own VAD.
SILENCE_CUT_MS = 700


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def _is_silent(pcm: bytes, threshold: float = 0.008) -> bool:
    """RMS silence check on Int16LE mono PCM, matching VADGate.rms in the app."""
    if len(pcm) < 2:
        return True
    import numpy as np

    samples = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
    if samples.size == 0:
        return True
    return float(np.sqrt(np.mean(samples * samples))) < threshold


class Models:
    """Lazily constructed FunASR models, shared by the streaming and file paths.

    Loading takes tens of seconds on first run (weights are fetched from
    ModelScope), so this happens once at process start, before the READY line.
    """

    def __init__(self, device: str, offline_device: str | None = None):
        # Measured on an M-series CPU vs MPS (600ms streaming chunks, 10s
        # offline utterance):
        #   streaming  cpu RTF 1.12  |  mps RTF 0.39
        #   offline    cpu RTF 0.13  |  mps RTF 0.24
        # So the streaming pass needs the GPU to keep up with real time, while
        # the offline pass is faster on CPU — short utterances don't amortize
        # the MPS transfer overhead. Splitting them also stops the two passes
        # from fighting over the same device.
        self.device = device
        self.offline_device = offline_device or device
        self.streaming = None
        self.offline = None
        self.vad = None
        self.punc = None
        self._file_model = None

    @property
    def file_model(self):
        """Offline model with VAD + punc attached, for whole-file import.

        Built on first use rather than at startup: live recording is the common
        case and shouldn't pay for a second copy of the offline weights.
        """
        if self._file_model is None:
            from funasr import AutoModel

            log("[models] loading file-import model (paraformer-zh + vad + punc)")
            self._file_model = AutoModel(
                model="paraformer-zh",
                vad_model="fsmn-vad",
                vad_kwargs={"max_single_segment_time": 30000},
                punc_model="ct-punc",
                device=self.offline_device,
                disable_pbar=True,
                disable_log=True,
                disable_update=True,
            )
        return self._file_model

    def load(self):
        # FunASR prints a version banner to stdout on import and inside
        # AutoModel(). Swift scans stdout for the READY marker, so redirect
        # anything these libraries print into stderr (which is logged) for the
        # duration of loading, keeping stdout as a clean control channel.
        with contextlib.redirect_stdout(sys.stderr):
            self._load()

    def _load(self):
        from funasr import AutoModel

        # disable_update stops FunASR from phoning home for a version check on
        # every AutoModel(): it costs seconds at startup, hangs when offline,
        # and prints to stdout, which is the channel Swift scans for READY.
        common = dict(device=self.device, disable_pbar=True, disable_log=True,
                      disable_update=True)
        offline_common = dict(common, device=self.offline_device)

        log(f"[models] loading paraformer-zh-streaming on {self.device}")
        self.streaming = AutoModel(model="paraformer-zh-streaming", **common)
        log("[models] loading fsmn-vad")
        self.vad = AutoModel(model="fsmn-vad", **common)
        log(f"[models] loading paraformer-zh on {self.offline_device}")
        self.offline = AutoModel(model="paraformer-zh", **offline_common)
        log("[models] loading ct-punc")
        try:
            self.punc = AutoModel(model="ct-punc", **offline_common)
        except Exception as exc:
            # Punctuation is a nicety; transcription still works without it.
            log(f"[models] punc unavailable, continuing without it: {exc}")
            self.punc = None

        # First inference on MPS pays for kernel compilation and lazy weight
        # transfer (measured ~700ms vs ~240ms steady state). Burn that cost on
        # silence now, before the user's first words.
        log("[models] warming up")
        silence = b"\x00" * ASR_STEP_BYTES
        try:
            self.streaming.generate(
                input=silence, cache={}, is_final=True, chunk_size=ASR_CHUNK_SIZE,
                encoder_chunk_look_back=ENCODER_LOOK_BACK,
                decoder_chunk_look_back=DECODER_LOOK_BACK, disable_pbar=True,
            )
            self.vad.generate(input=b"\x00" * VAD_STEP_BYTES, cache={},
                              is_final=True, chunk_size=VAD_STEP_MS, disable_pbar=True)
        except Exception as exc:
            log(f"[models] warmup failed (harmless): {exc}")

        log("[models] all loaded")


class NemotronModels:
    """MLX-based English streaming ASR, an alternative to the FunASR stack.

    Single-pass: the model streams text deltas directly and has no separate
    offline refinement, so `Session` treats every flush as the segment's final.
    """

    NEMOTRON_CHUNK_MS = 160

    def __init__(self, model_id: str):
        self.model_id = model_id
        self.asr = None

    def load(self):
        with contextlib.redirect_stdout(sys.stderr):
            from nemotron_asr_mlx import from_pretrained

            log(f"[models] loading {self.model_id} (mlx)")
            self.asr = from_pretrained(self.model_id)
            log("[models] all loaded")

    def create_stream(self):
        return self.asr.create_stream(chunk_ms=self.NEMOTRON_CHUNK_MS)


class NemotronSession:
    """Streams PCM into a Nemotron MLX session, emitting partials and finals.

    Deliberately mirrors the FunASR `Session` surface (`start`/`enqueue`/
    `feed`/`finish`/`close`) so `handle_connection` does not branch per engine.
    """

    def __init__(self, ws, models: NemotronModels, executor: ThreadPoolExecutor,
                 language: str | None):
        self.ws = ws
        self.models = models
        self.executor = executor
        self.language = language
        self.stream = models.create_stream()

        self.segment_id = 0
        self.segment_start_ms = 0
        self.stream_ms = 0
        self.buf = bytearray()
        self.silence_ms = 0
        self.have_text = False

        self._inbox: asyncio.Queue = asyncio.Queue()
        self._worker: asyncio.Task | None = None

        # Nemotron has no VAD, so utterances are cut on an energy-based silence
        # run, the same heuristic the app's own VADGate uses.
        self.step_bytes = models.NEMOTRON_CHUNK_MS * BYTES_PER_MS

    async def start(self):
        self._worker = asyncio.create_task(self._process_loop())

    def enqueue(self, pcm: bytes):
        if pcm:
            self._inbox.put_nowait(pcm)

    async def _process_loop(self):
        while True:
            pcm = await self._inbox.get()
            try:
                await self.feed(pcm)
            except Exception:
                log(f"[process] {traceback.format_exc()}")

    async def _run(self, fn, *a, **kw):
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(self.executor, lambda: fn(*a, **kw))

    async def _send(self, payload: dict):
        try:
            await self.ws.send(json.dumps(payload, ensure_ascii=False))
        except websockets.ConnectionClosed:
            pass

    def _push_sync(self, pcm: bytes):
        import mlx.core as mx
        import numpy as np

        samples = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
        with contextlib.redirect_stdout(sys.stderr):
            return self.stream.push(mx.array(samples))

    def _flush_sync(self):
        with contextlib.redirect_stdout(sys.stderr):
            return self.stream.flush()

    async def feed(self, pcm: bytes):
        if len(pcm) % 2:
            pcm = pcm[:-1]
        if not pcm:
            return
        self.stream_ms += len(pcm) // BYTES_PER_MS
        self.buf.extend(pcm)

        # Track a trailing silence run to find utterance boundaries.
        if _is_silent(pcm):
            self.silence_ms += len(pcm) // BYTES_PER_MS
        else:
            self.silence_ms = 0

        while len(self.buf) >= self.step_bytes:
            chunk = bytes(self.buf[:self.step_bytes])
            del self.buf[:self.step_bytes]
            try:
                event = await self._run(self._push_sync, chunk)
            except Exception as exc:
                log(f"[nemotron] {exc}")
                continue
            if event is not None and event.text:
                self.have_text = True
                await self._send({
                    "type": "partial", "segmentId": self.segment_id,
                    "startMs": self.segment_start_ms, "endMs": self.stream_ms,
                    "text": event.text,
                })

        if self.have_text and self.silence_ms >= SILENCE_CUT_MS:
            await self._cut()

    async def _cut(self):
        try:
            event = await self._run(self._flush_sync)
        except Exception as exc:
            log(f"[nemotron] flush failed: {exc}")
            return
        text = (event.text if event is not None else "") or ""
        if text:
            await self._send({
                "type": "final", "segmentId": self.segment_id,
                "startMs": self.segment_start_ms, "endMs": self.stream_ms,
                "text": text,
            })
        # flush() ends the session's state, so a fresh one is needed to continue.
        self.stream = self.models.create_stream()
        self.segment_id += 1
        self.segment_start_ms = self.stream_ms
        self.silence_ms = 0
        self.have_text = False

    async def finish(self):
        while not self._inbox.empty():
            await asyncio.sleep(0.02)
        if self.buf:
            tail = bytes(self.buf)
            self.buf.clear()
            try:
                await self._run(self._push_sync, tail)
            except Exception as exc:
                log(f"[nemotron] tail push failed: {exc}")
        if self.have_text:
            await self._cut()
        await self._send({"type": "eof"})

    async def transcribe_file(self, path: str):
        if not os.path.exists(path):
            await self._send({"type": "error", "message": f"文件不存在: {path}"})
            return
        await self._send({"type": "progress", "completed": 0, "total": 1})
        try:
            result = await self._run(self._transcribe_file_sync, path)
        except Exception as exc:
            log(f"[nemotron file] {traceback.format_exc()}")
            await self._send({"type": "error", "message": f"文件转写失败: {exc}"})
            return
        if result:
            await self._send({
                "type": "final", "segmentId": self.segment_id,
                "startMs": 0, "endMs": 0, "text": result,
            })
            self.segment_id += 1
        await self._send({"type": "progress", "completed": 1, "total": 1})
        await self._send({"type": "eof"})

    def _transcribe_file_sync(self, path: str) -> str:
        with contextlib.redirect_stdout(sys.stderr):
            out = self.models.asr.transcribe(path)
        return getattr(out, "text", None) or (out if isinstance(out, str) else "")

    async def close(self):
        if self._worker is not None:
            self._worker.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._worker
            self._worker = None


class Session:
    """Per-connection two-pass streaming state.

    All model calls are blocking, so every one is pushed to a thread via
    ``_run``; the event loop stays free to keep reading audio. This is the fix
    for the previous version, where inference ran inline and stalled the socket
    until the buffer backed up.
    """

    def __init__(self, ws, models: Models, executor: ThreadPoolExecutor, language: str | None):
        self.ws = ws
        self.models = models
        self.executor = executor
        self.language = language

        self.asr_cache: dict = {}
        self.vad_cache: dict = {}
        self.punc_cache: dict = {}

        self.asr_buf = bytearray()   # audio not yet handed to the streaming pass
        self.vad_buf = bytearray()   # audio not yet handed to VAD
        self.utt_buf = bytearray()   # current utterance, for the offline pass
        self.preroll = bytearray()   # recent audio kept while no speech is active

        self.speech_active = False
        self.segment_id = 0
        self.stream_ms = 0           # total audio received, ms
        self.segment_start_ms = 0
        self.partial_text = ""       # streaming text accumulated for this segment
        # True when a partial was dropped inside this segment, which makes
        # partial_text unreliable as the segment's final text.
        self.segment_had_skip = False

        # In-flight offline revisions. Serialized by the lock so two utterances
        # never contend for the model, but kept off the read path entirely.
        self._revisions: set[asyncio.Task] = set()
        self._offline_lock = asyncio.Lock()

        self._stream_calls = 0
        self._stream_time = 0.0
        self._skipped_ms = 0

        # Audio arrives faster than the streaming model can consume it when the
        # machine is loaded, so reading and processing are separate tasks joined
        # by this queue.
        self._inbox: asyncio.Queue = asyncio.Queue()
        self._worker: asyncio.Task | None = None
        self._queued_bytes = 0

    # ---- plumbing -------------------------------------------------------

    async def _run(self, fn, *a, **kw):
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(self.executor, lambda: fn(*a, **kw))

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
        with contextlib.redirect_stdout(sys.stderr):
            return self._streaming_inner(pcm, is_final)

    def _streaming_inner(self, pcm: bytes, is_final: bool) -> str:
        res = self.models.streaming.generate(
            input=pcm,
            cache=self.asr_cache,
            is_final=is_final,
            chunk_size=ASR_CHUNK_SIZE,
            encoder_chunk_look_back=ENCODER_LOOK_BACK,
            decoder_chunk_look_back=DECODER_LOOK_BACK,
            disable_pbar=True,
        )
        return res[0].get("text", "") if res else ""

    def _vad_sync(self, pcm: bytes, is_final: bool):
        with contextlib.redirect_stdout(sys.stderr):
            return self._vad_inner(pcm, is_final)

    def _vad_inner(self, pcm: bytes, is_final: bool):
        res = self.models.vad.generate(
            input=pcm,
            cache=self.vad_cache,
            is_final=is_final,
            chunk_size=VAD_STEP_MS,
            disable_pbar=True,
        )
        return res[0].get("value", []) if res else []

    def _offline_sync(self, pcm: bytes) -> str:
        with contextlib.redirect_stdout(sys.stderr):
            return self._offline_inner(pcm)

    def _offline_inner(self, pcm: bytes) -> str:
        kwargs = {"input": pcm, "disable_pbar": True}
        if self.language:
            kwargs["language"] = self.language
        res = self.models.offline.generate(**kwargs)
        text = res[0].get("text", "") if res else ""
        if text and self.models.punc is not None:
            try:
                punc = self.models.punc.generate(
                    input=text, cache=self.punc_cache, disable_pbar=True
                )
                if punc and punc[0].get("text"):
                    text = punc[0]["text"]
            except Exception as exc:
                log(f"[punc] failed, keeping unpunctuated text: {exc}")
        return text

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
        self.vad_buf.extend(pcm)

        if self.speech_active:
            self.utt_buf.extend(pcm)
        else:
            # Not in speech yet: hold a rolling pre-roll so that when VAD does
            # fire we can prepend the audio just before the detected onset.
            self.preroll.extend(pcm)
            keep = PREROLL_MS * BYTES_PER_MS
            if len(self.preroll) > keep:
                del self.preroll[: len(self.preroll) - keep]

        await self._drain_streaming()
        await self._drain_vad()

        # Safety valve: VAD occasionally never reports an endpoint on
        # continuous speech. Cut anyway so the user keeps getting finals.
        if self.speech_active and len(self.utt_buf) >= MAX_UTTERANCE_MS * BYTES_PER_MS:
            log("[vad] max utterance length reached, forcing a cut")
            await self.close_segment()

    async def _drain_streaming(self):
        """Run the streaming model on every complete 600 ms stride available."""
        while len(self.asr_buf) >= ASR_STEP_BYTES:
            # Behind real time: drop this stride's partial instead of running
            # the model on it. Most of the lag sits in the inbox rather than in
            # asr_buf, so the backlog must be measured across both -- otherwise
            # this check reports nothing wrong while latency grows unbounded.
            # The audio is already in utt_buf, so the offline pass still
            # transcribes it: only the intermediate partial is lost, never
            # transcript text.
            backlog_ms = (len(self.asr_buf) + self._queued_bytes) // BYTES_PER_MS
            if backlog_ms > MAX_STREAM_BACKLOG_MS:
                del self.asr_buf[:ASR_STEP_BYTES]
                self._skipped_ms += ASR_STEP_MS
                self.segment_had_skip = True
                if self._skipped_ms % (ASR_STEP_MS * 5) == 0:
                    log(f"[streaming] behind by {backlog_ms}ms, "
                        f"{self._skipped_ms}ms of partials skipped so far")
                # Skipping leaves a hole in the streaming model's cache, so its
                # next output would splice across missing audio. Reset the cache
                # and let the partial restart from here.
                self.asr_cache = {}
                continue

            chunk = bytes(self.asr_buf[:ASR_STEP_BYTES])
            del self.asr_buf[:ASR_STEP_BYTES]
            started = time.monotonic()
            try:
                text = await self._run(self._streaming_sync, chunk, False)
            except Exception as exc:
                log(f"[streaming] {exc}")
                continue
            # RTF > 1 means the streaming pass cannot keep up and partials will
            # fall behind; surfacing it makes that diagnosable from the app log.
            elapsed = time.monotonic() - started
            self._stream_calls += 1
            self._stream_time += elapsed
            if self._stream_calls % 25 == 0:
                log(f"[streaming] {self._stream_calls} chunks, "
                    f"mean {self._stream_time / self._stream_calls * 1000:.0f}ms/"
                    f"{ASR_STEP_MS}ms audio "
                    f"(RTF {self._stream_time / self._stream_calls / (ASR_STEP_MS / 1000):.2f})")
            if text:
                self.partial_text += text
                await self._emit("partial", self.partial_text,
                                 self.segment_start_ms, self.stream_ms)

    async def _drain_vad(self):
        """Run FSMN-VAD on every complete 200 ms stride and act on endpoints."""
        while len(self.vad_buf) >= VAD_STEP_BYTES:
            chunk = bytes(self.vad_buf[:VAD_STEP_BYTES])
            del self.vad_buf[:VAD_STEP_BYTES]
            try:
                segments = await self._run(self._vad_sync, chunk, False)
            except Exception as exc:
                log(f"[vad] {exc}")
                continue
            for beg, end in segments:
                if beg != -1 and not self.speech_active:
                    self.speech_active = True
                    self.segment_start_ms = max(0, beg)
                    # Seed the utterance with the pre-roll so the offline pass
                    # hears the word onset, not the middle of it.
                    self.utt_buf = bytearray(self.preroll)
                    self.preroll.clear()
                if end != -1 and self.speech_active:
                    await self.close_segment(end_ms=end)

    async def close_segment(self, end_ms: int | None = None):
        """Finish the current utterance: emit a streaming final, then a revision."""
        if not self.utt_buf:
            self.speech_active = False
            return

        utterance = bytes(self.utt_buf)
        end = end_ms if end_ms is not None else self.stream_ms
        start = self.segment_start_ms

        # Flush whatever streaming audio is still buffered, with is_final so the
        # model releases its tail, then emit the first-pass result immediately.
        tail = bytes(self.asr_buf)
        self.asr_buf.clear()
        try:
            text = await self._run(self._streaming_sync, tail, True)
            if text:
                self.partial_text += text
        except Exception as exc:
            log(f"[streaming] final flush failed: {exc}")

        # If partials were skipped inside this segment, the accumulated text has
        # a hole in it and must not be committed as the segment's final. Emit
        # nothing now and let the offline pass -- which sees the whole
        # utterance -- produce the final instead.
        first_pass = "" if self.segment_had_skip else self.partial_text
        segment_id = self.segment_id
        if first_pass:
            await self._emit("final", first_pass, start, end, segment_id=segment_id)

        # Reset streaming state and advance to the next segment immediately, so
        # audio arriving during the offline pass is handled without waiting.
        self.asr_cache = {}
        self.partial_text = ""
        self.utt_buf.clear()
        self.speech_active = False
        self.segment_had_skip = False
        self.segment_id += 1
        self.segment_start_ms = end

        # The offline pass is slow (seconds for a long utterance). Run it in the
        # background so reading audio never blocks on it; the revision arrives
        # out of band and the client matches it by segmentId.
        task = asyncio.create_task(
            self._revise(utterance, first_pass, segment_id, start, end)
        )
        self._revisions.add(task)
        task.add_done_callback(self._revisions.discard)

    async def _revise(self, utterance: bytes, first_pass: str,
                      segment_id: int, start: int, end: int):
        async with self._offline_lock:
            try:
                revised = await self._run(self._offline_sync, utterance)
            except Exception as exc:
                log(f"[offline] {exc}")
                return
        if not revised:
            return
        if first_pass:
            if revised != first_pass:
                await self._emit("revised", revised, start, end, segment_id=segment_id)
        else:
            # Streaming produced nothing (common for very short utterances);
            # the offline result becomes the segment's only final.
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

        # Offline revisions run in the background, so eof must wait for them.
        # Sending it early makes the client disconnect while the last segment's
        # correction is still being computed, and that text is then lost.
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

    # ---- file import ----------------------------------------------------

    def _file_sync(self, path: str):
        with contextlib.redirect_stdout(sys.stderr):
            return self._file_inner(path)

    def _file_inner(self, path: str):
        """Transcribe a whole file with VAD segmentation and per-sentence times."""
        kwargs = {
            "input": path,
            "disable_pbar": True,
            "batch_size_s": 300,
            # sentence_timestamp is what actually populates sentence_info; without
            # it the result carries only whole-file text and the import would
            # collapse into one untimed segment the UI cannot seek within.
            "sentence_timestamp": True,
        }
        if self.language:
            kwargs["language"] = self.language
        return self.models.file_model.generate(**kwargs)

    async def transcribe_file(self, path: str):
        if not os.path.exists(path):
            await self._send({"type": "error", "message": f"文件不存在: {path}"})
            return
        await self._send({"type": "progress", "completed": 0, "total": 1})
        try:
            res = await self._run(self._file_sync, path)
        except Exception as exc:
            log(f"[file] {traceback.format_exc()}")
            await self._send({"type": "error", "message": f"文件转写失败: {exc}"})
            return

        item = res[0] if res else {}
        sentences = item.get("sentence_info") or []
        if sentences:
            for sent in sentences:
                text = (sent.get("text") or "").strip()
                if not text:
                    continue
                await self._emit("final", text,
                                 sent.get("start", 0), sent.get("end", 0))
                self.segment_id += 1
        else:
            # Some model/version combinations omit sentence_info; fall back to
            # the whole-file text as a single segment rather than dropping it.
            text = (item.get("text") or "").strip()
            if text:
                await self._emit("final", text, 0, 0)
                self.segment_id += 1
        await self._send({"type": "progress", "completed": 1, "total": 1})
        await self._send({"type": "eof"})


async def handle_connection(ws, models, executor: ThreadPoolExecutor,
                            default_language: str | None):
    if isinstance(models, NemotronModels):
        session = NemotronSession(ws, models, executor, default_language)
    else:
        session = Session(ws, models, executor, default_language)
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
                # "auto" is the app's own sentinel; FunASR wants it omitted.
                session.language = lang if lang and lang != "auto" else None
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


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--engine", default="funasr", choices=["funasr", "nemotron"])
    parser.add_argument("--nemotron-model", default="mlx-community/parakeet-tdt-0.6b-v2",
                        help="model id for the nemotron/mlx engine")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--device", default="auto",
                        choices=["auto", "cpu", "mps"],
                        help="device for the streaming pass; auto prefers mps")
    parser.add_argument("--offline-device", default="cpu",
                        choices=["cpu", "mps"],
                        help="device for the offline pass; cpu is faster here")
    parser.add_argument("--language", default=None)
    parser.add_argument("--threads", type=int, default=4)
    args = parser.parse_args()

    # Keep BLAS from oversubscribing cores; FunASR on CPU is already threaded
    # and contention here shows up directly as streaming latency.
    os.environ.setdefault("OMP_NUM_THREADS", str(max(1, args.threads)))

    device = args.device
    if device == "auto":
        # The streaming pass is ~2.9x faster on MPS and is the one bound by real
        # time, so prefer the GPU when this machine has one.
        try:
            import torch
            device = "mps" if torch.backends.mps.is_available() else "cpu"
        except Exception as exc:
            log(f"[device] mps probe failed, using cpu: {exc}")
            device = "cpu"
    log(f"[device] streaming={device} offline={args.offline_device}")

    if args.engine == "nemotron":
        models = NemotronModels(args.nemotron_model)
    else:
        models = Models(device, offline_device=args.offline_device)
    try:
        await asyncio.get_running_loop().run_in_executor(None, models.load)
    except Exception:
        log(f"[fatal] model load failed: {traceback.format_exc()}")
        # Swift waits for READY on stdout; without this it would block for the
        # full timeout instead of surfacing the failure.
        print("FATAL model load failed", flush=True)
        sys.exit(1)

    executor = ThreadPoolExecutor(max_workers=max(2, args.threads))

    async def handler(ws):
        await handle_connection(ws, models, executor, args.language)

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
