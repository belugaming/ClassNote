#!/usr/bin/env python3
"""Local streaming ASR sidecar. Usage: asr_server.py --engine funasr|nemotron --port N"""
import argparse
import asyncio
import json
import struct

import websockets


class EngineAdapter:
    """Wraps a streaming ASR backend behind a uniform partial/final/revised API."""

    def __init__(self, name: str):
        self.name = name
        self._segment_id = 0

    async def load(self):
        raise NotImplementedError

    async def feed(self, pcm_bytes: bytes):
        """Yields dicts: {"type": "partial"|"final"|"revised", "segmentId", "startMs", "endMs", "text"}"""
        raise NotImplementedError


class FunASREngine(EngineAdapter):
    async def load(self):
        from funasr import AutoModel
        self.streaming_model = AutoModel(model="paraformer-zh-streaming")
        self.offline_model = AutoModel(model="iic/SenseVoiceSmall")
        self.chunk_buffer = bytearray()
        self.utterance_buffer = bytearray()
        self.ms_offset = 0

    async def feed(self, pcm_bytes: bytes):
        # Streaming pass: emit partials as chunks accumulate.
        self.chunk_buffer.extend(pcm_bytes)
        self.utterance_buffer.extend(pcm_bytes)
        events = []
        if len(self.chunk_buffer) >= 9600:  # ~300ms @16kHz/16bit mono
            text = self._run_streaming_chunk(bytes(self.chunk_buffer))
            self.chunk_buffer.clear()
            if text:
                events.append({
                    "type": "partial", "segmentId": self._segment_id,
                    "startMs": self.ms_offset, "endMs": self.ms_offset, "text": text,
                })
        return events

    def _run_streaming_chunk(self, chunk: bytes) -> str:
        res = self.streaming_model.generate(input=chunk, is_final=False)
        return res[0]["text"] if res else ""

    async def finalize_utterance(self, end_ms: int):
        """Called on VAD silence boundary: run offline pass, emit final then revised."""
        seg_id = self._segment_id
        self._segment_id += 1
        streaming_text = self._run_streaming_chunk(bytes(self.utterance_buffer))
        final_event = {
            "type": "final", "segmentId": seg_id,
            "startMs": self.ms_offset, "endMs": end_ms, "text": streaming_text,
        }
        offline_res = self.offline_model.generate(input=bytes(self.utterance_buffer))
        revised_text = offline_res[0]["text"] if offline_res else streaming_text
        self.utterance_buffer.clear()
        self.ms_offset = end_ms
        revised_event = None
        if revised_text and revised_text != streaming_text:
            revised_event = {
                "type": "revised", "segmentId": seg_id,
                "startMs": final_event["startMs"], "endMs": end_ms, "text": revised_text,
            }
        return final_event, revised_event


class NemotronEngine(EngineAdapter):
    async def load(self):
        from nemotron_asr_mlx import StreamingRecognizer
        self.recognizer = StreamingRecognizer.from_pretrained("nvidia/nemotron-3.5-asr-streaming")
        self.ms_offset = 0

    async def feed(self, pcm_bytes: bytes):
        events = []
        for result in self.recognizer.feed(pcm_bytes):
            events.append({
                "type": "final" if result.is_final else "partial",
                "segmentId": self._segment_id,
                "startMs": self.ms_offset, "endMs": self.ms_offset + result.duration_ms,
                "text": result.text,
            })
            if result.is_final:
                self._segment_id += 1
                self.ms_offset += result.duration_ms
        return events


def _is_silent(pcm_bytes: bytes, threshold: int = 400) -> bool:
    """Cheap RMS-based silence check on Int16LE mono PCM, mirrors VADGate.rms on the Swift side."""
    if not pcm_bytes:
        return True
    count = len(pcm_bytes) // 2
    if count == 0:
        return True
    samples = struct.unpack(f"<{count}h", pcm_bytes[: count * 2])
    mean_sq = sum(s * s for s in samples) / count
    return mean_sq ** 0.5 < threshold


async def handle_connection(ws, engine_name: str):
    engine = FunASREngine(engine_name) if engine_name == "funasr" else NemotronEngine(engine_name)
    await engine.load()
    silence_run_ms = 0
    try:
        async for message in ws:
            if not isinstance(message, bytes):
                continue
            events = await engine.feed(message)
            for ev in events:
                await ws.send(json.dumps(ev))
            if engine_name == "funasr":
                # ~10ms per 320-byte frame at 16kHz/16-bit mono is too fine-grained
                # to reason about per network message; approximate using the chunk
                # size actually received instead of a fixed constant.
                chunk_ms = int(len(message) / (16000 * 2) * 1000)
                if _is_silent(message):
                    silence_run_ms += chunk_ms
                else:
                    silence_run_ms = 0
                # Trailing ~500ms of silence after at least some voiced audio marks
                # an utterance boundary — trigger the offline 2-pass revision.
                if silence_run_ms >= 500 and engine.utterance_buffer:
                    final_ev, revised_ev = await engine.finalize_utterance(engine.ms_offset + chunk_ms)
                    await ws.send(json.dumps(final_ev))
                    if revised_ev:
                        await ws.send(json.dumps(revised_ev))
                    silence_run_ms = 0
    except websockets.ConnectionClosed:
        pass


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--engine", required=True, choices=["funasr", "nemotron"])
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()

    async def handler(ws):
        await handle_connection(ws, args.engine)

    server = await websockets.serve(handler, "127.0.0.1", args.port)
    print(f"READY port={args.port}", flush=True)
    await server.wait_closed()


if __name__ == "__main__":
    asyncio.run(main())
