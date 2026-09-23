#!/usr/bin/env python3
"""Local streaming ASR sidecar for ClassNote.

One process serves exactly one client. Started by LocalASRProcessManager.swift,
which waits for the ``READY port=N`` line on stdout before connecting.

WebSocket protocol
------------------
Client -> server:
  * binary frames -- raw Int16LE mono PCM at 16 kHz
  * text frames (JSON):
      {"type": "config", "language": "zh"}
      {"type": "eof"}                       flush and finalize the live stream
      {"type": "file", "path": "/abs.wav"}  transcribe a whole 16 kHz mono WAV
      {"type": "cancel"}                    stop a running file job

Server -> client (JSON text frames), all carrying the same envelope so the
Swift decoder can treat them uniformly:
  {"type": "status",   "stage": "ready"}
  {"type": "partial",  "segmentId", "startMs", "endMs", "text"}
  {"type": "final",    ..., "sentenceEnd"}
                                the segment's text once it is closed;
                                sentenceEnd is false when the line was only
                                broken for length and its sentence goes on
  {"type": "progress", "completed", "total"}
  {"type": "eof"}
  {"type": "error",    "code", "message"}

``code`` is one of ERROR_CODES; the app localizes on it, so ``message`` is a
developer-facing detail (a path, an exception) and never a UI string.

Engine
------
A single pass: NVIDIA nemotron-3.5-asr-streaming-0.6b, a cache-aware
FastConformer transducer covering 40 languages, run through sherpa-onnx on the
CPU. The chunk size is fixed at export time, so each latency setting is its own
ONNX export; at 160 ms a word reaches the screen roughly 200 ms after it is
spoken (measured: partials arrive ~30 ms after the frame that contains them, at
RTF ~0.15 on an M-series CPU).

The previous two-pass design (MLX streaming draft + Qwen3-ASR re-transcription)
is gone. Nemotron emits punctuation and casing itself, so there is nothing left
for a second pass to fix that is worth the delay and the extra 2-4 GB resident.

Segmentation
------------
One OnlineStream lives for the whole connection and is never reset. Measured on
this model, sherpa-onnx's ``reset()`` also drops roughly the next second of
speech, which is exactly the word after a pause. So every cut is virtual: the
transducer's greedy output only ever grows, and a segment is just a range of its
tokens. A segment closes on a pause (no new token for a while), on sentence
punctuation, or on a 6 s soft cut at the nearest clause or word boundary.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import json
import os
import re
import sys
import threading
import time
import traceback
import wave
from collections import deque
from concurrent.futures import ThreadPoolExecutor

import numpy as np
import websockets

SAMPLE_RATE = 16000
BYTES_PER_MS = SAMPLE_RATE * 2 // 1000  # Int16 mono -> 32 bytes per ms
FEATURE_DIM = 128                        # nemotron's mel front end

# Chunk sizes nemotron-3.5 was exported at. Each is a separate download.
CHUNK_CHOICES = (80, 160, 320, 560, 1120)
DEFAULT_CHUNK_MS = 160
MODEL_REPO = "csukuangfj2/sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-{chunk}ms-int8-2026-06-11"
# Commit to download, per chunk size. None means "whatever main points at"; the
# shas are read off the CI job that prints `model_info(...).sha` for every repo
# and pasted in here, so a re-export upstream cannot change the model under a
# user who already has the old weights cached. Bump together with MODEL_REPO.
MODEL_REVISIONS = {
    80: "2ac5952ae18a2cc010c25e3fd96ad20cf254bd09",
    160: "b3a4dbde84fba1a13cb4270e6730b525ac6a2db6",
    320: "424ce58898995b713f84341f2e1492f9207a26aa",
    560: "ab43d895f5985b1bbab8b6eac8607fcdc05343f3",
    1120: "cba1c96ca5ef0e8393b50584ae153a79145dc492",
}

# Punctuation restoration (CT-Transformer, Chinese + English, ~300 MB). Nemotron
# punctuates its own output only sporadically in continuous speech -- measured
# on a real interview it produced no marks at all for a minute -- and a
# streaming model cannot do better, because a sentence end is only certain
# once the next sentence has begun. This model reads the text instead and
# decides in a few milliseconds where the sentences are; those positions drive
# the line breaks and the marks are inserted into the transcript.
PUNCT_MODEL_REPO = "csukuangfj/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12"
PUNCT_MODEL_FILES = ("model.onnx", "tokens.json", "config.yaml")
# As MODEL_REVISIONS: None means main.
PUNCT_MODEL_REVISION = "432aeba669265e7aeb06b9359753419683b38597"

# A segment closes once the audio has been quiet -- no voice energy and no new
# token -- for this long. Both are required: the transducer sometimes holds a
# word back for close to a second while the speaker is still talking (measured
# on "丙酮酸": 0.9 s between "丙" and the next token), and a token-gap rule alone
# cut lines mid-word there. 800 ms is long enough that a breath at a comma
# does not break the sentence, while the punctuation model handles sentence
# ends without needing a pause at all.
PAUSE_CLOSE_MS = 800
# RMS of a 16-bit frame (normalised to [-1, 1]) above which it counts as voice.
# Same scale and neighbourhood as the app's own VADGate (0.008) and the cloud
# chunker (0.01).
VOICE_RMS_THRESHOLD = 0.01
# A token's timestamp is its onset; a closed line ends roughly this long after
# the onset of its last token. Used for the final's endMs so consecutive lines
# do not overlap in time.
TOKEN_TAIL_MS = 350

# Sentence-ending punctuation. A lecturer rarely pauses long enough mid-flow, so
# without this a segment would grow until the soft cut. Cutting on punctuation
# keeps each committed line to roughly one spoken sentence, which is what makes
# it readable. Nemotron often emits the mark together with the first token of
# the next sentence, so the cut is searched for near the end, not only at it.
SENTENCE_END_CHARS = ".!?。！？…"
CLAUSE_END_CHARS = ",;，；:："
# Don't cut on a period that is probably an abbreviation or decimal ("Dr.",
# "3.5"), and don't emit a fragment so short it reads as noise. Measured in
# display width, where a CJK character counts double: "他分为三个主要阶段。" is
# a complete sentence at ten characters, which twelve Latin letters are not.
MIN_SENTENCE_CHARS = 12
# Once a segment reaches this, cut at the nearest clause or word boundary even
# mid-thought, so a run-on speaker still gets broken into readable lines.
SOFT_CUT_MS = 6_000
# Tokens that only carry punctuation or whitespace belong to the sentence
# before them; when they arrive after a segment has already closed on a pause
# they are dropped rather than starting the next line with ". ".
LEADING_SKIP_CHARS = set(SENTENCE_END_CHARS + CLAUSE_END_CHARS + " 　▁")

# Report inference speed every this many frames.
STATS_EVERY = 200

# Language ids nemotron-3.5 was trained with, copied from the encoder's
# `prompt_dictionary` metadata so a code the app sends can be normalised without
# opening the 650 MB ONNX file. The app sends codes like "zh", "zh-Hans", "en";
# the model wants "zh-CN", "en". Anything it does not know falls back to auto.
PROMPT_LANGUAGES = (
    "af-ZA am-ET ar ar-AR auto ay-BO az-AZ bg bg-BG bn-IN cs cs-CZ da da-DK de "
    "de-DE el el-GR en en-GB en-US enGB es es-ES es-US esES et et-EE fa-IR fi "
    "fi-FI fr fr-CA fr-FR gn-PY gu-IN ha-NG haw-US he-IL hi hi-HI hi-IN hr hr-HR "
    "hu hu-HU hy-AM id-ID ig-NG it it-IT ja-JA ja-JP ka-GE km-KH kn-IN ko ko-KO "
    "ko-KR ku-TR ky-KG ln-CD lt lt-LT lv lv-LV mi-NZ ml-IN mr-IN ms-MY mt-MT "
    "nah-MX nb nb-NO ne-NP nl nl-NL nn nn-NO no no-NO ny-MW or-KE pl pl-PL pt "
    "pt-BR pt-PT qu-PE ro ro-RO ru ru-RU rw-RW si-LK sk sk-SK sl sl-SI sm-WS "
    "so-SO sv sv-SE sw-KE ta-IN te-IN tg-TJ th-TH to-TO tr tr-TR uk uk-UA ur-PK "
    "uz-UZ vi-VN yo-NG zh-CN zh-TW zh-ZH zu-ZA"
).split()
_PROMPT_LOOKUP = {code.lower(): code for code in PROMPT_LANGUAGES}
# Codes the app uses that the dictionary spells differently: scripts named by
# writing system rather than region, and bare codes whose canonical regional
# form should win over the dictionary's doubled "zh-ZH"/"ja-JA" spellings.
_ALIASES = {
    "zh": "zh-CN", "zh-hans": "zh-CN", "zh-hant": "zh-TW", "zh-hk": "zh-TW", "yue": "zh-TW",
    "ja": "ja-JP", "ko": "ko-KR",
}


# Error codes the app localizes on. The message beside them is a diagnostic.
ERROR_CODES = ("file.missing", "file.unreadable", "file.failed", "internal")

# The handshake channel: STAGE/READY/FATAL, the only three lines Swift parses.
# Engine.load() redirects sys.stdout to stderr so huggingface_hub's progress
# bars cannot corrupt it, and since print() looks sys.stdout up at call time
# that redirected the STAGE lines too. Hold the real stream instead.
_HANDSHAKE = sys.stdout
_handshake_lock = threading.Lock()


def handshake(line: str):
    """One handshake line. Locked because the download heartbeat runs on its own
    thread while the loader emits the next stage."""
    with _handshake_lock:
        print(line, file=_HANDSHAKE, flush=True)


def log(*a):
    print(*a, file=sys.stderr, flush=True)


@contextlib.contextmanager
def stage_heartbeat(repeat, interval: float = 5.0):
    """Re-emits the current STAGE line every `interval` seconds for as long as
    the block runs.

    The app extends its start-up deadline on every STAGE line it reads, and a
    650 MB download is otherwise minutes of complete silence on the handshake
    channel -- indistinguishable, from the outside, from a hung child.
    """
    stop = threading.Event()

    def beat():
        while not stop.wait(interval):
            repeat()

    thread = threading.Thread(target=beat, name="stage-heartbeat", daemon=True)
    thread.start()
    try:
        yield
    finally:
        stop.set()
        thread.join(timeout=1.0)


def resolve_language(code: str | None) -> str | None:
    """Maps an app language code onto a prompt id nemotron knows.

    Returns None for auto-detect, which is also what an unknown code becomes:
    sherpa-onnx would log a warning and fall back to auto on every decode call
    otherwise, so it is better to decide once here.
    """
    if not code:
        return None
    key = code.strip().lower().replace("_", "-")
    if not key or key == "auto":
        return None
    if key in _ALIASES:
        return _ALIASES[key]
    if key in _PROMPT_LOOKUP:
        return _PROMPT_LOOKUP[key]
    base = key.split("-")[0]
    if base in _ALIASES:
        return _ALIASES[base]
    if base in _PROMPT_LOOKUP:
        return _PROMPT_LOOKUP[base]
    for candidate in PROMPT_LANGUAGES:
        if candidate.lower().startswith(base + "-"):
            return candidate
    log(f"[language] {code!r} is not a nemotron language, using auto")
    return None


def pcm_to_float(pcm: bytes) -> np.ndarray:
    return np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0


def tokens_to_text(tokens) -> str:
    """How sherpa-onnx builds `result.text` from BPE pieces, with runs of
    whitespace collapsed (nemotron emits stray space tokens after punctuation)."""
    return re.sub(r"\s+", " ", "".join(tokens).replace("▁", " ")).strip()


def frame_rms(pcm: bytes) -> float:
    if len(pcm) < 2:
        return 0.0
    samples = pcm_to_float(pcm)
    return float(np.sqrt(np.mean(samples * samples)))


def _is_cjk(ch: str) -> bool:
    """Wide characters for layout purposes: Han, kana, CJK punctuation."""
    o = ord(ch)
    return 0x3000 <= o <= 0x9FFF or 0xF900 <= o <= 0xFAFF or 0xFF00 <= o <= 0xFFEF


def _is_han(ch: str) -> bool:
    """Chinese ideographs only -- kana and hangul are not Chinese."""
    o = ord(ch)
    return 0x4E00 <= o <= 0x9FFF or 0x3400 <= o <= 0x4DBF or 0xF900 <= o <= 0xFAFF


def text_width(text: str) -> int:
    """Display width: CJK characters count double, since one carries as much as
    a short Latin word."""
    return sum(2 if _is_cjk(ch) else 1 for ch in text)


def ends_sentence(text: str) -> bool:
    """Whether `text` reads as a finished sentence a reader can take as one line."""
    text = text.rstrip()
    if not text or text_width(text) < MIN_SENTENCE_CHARS or text[-1] not in SENTENCE_END_CHARS:
        return False
    if text[-1] == "." and len(text) >= 2:
        # "3.5" -- a period between digits is a decimal, not a sentence end.
        if text[-2].isdigit():
            return False
        # "Dr." / "Mr." / "U.S." -- a very short trailing word is far more
        # likely to be an abbreviation than a sentence. Capped at two letters
        # on purpose: three would also swallow genuine enders like "not."
        # or "can.", which are common in speech, and a missed cut here is
        # harmless anyway -- the soft cut still breaks the line.
        token = text.rsplit(" ", 1)[-1]
        letters = [c for c in token if c.isalpha()]
        if letters and len(letters) <= 2:
            return False
    return True


def find_cut(tokens, held_ms: int) -> int | None:
    """Where to close the segment made of `tokens`, as a count of tokens to
    commit, or None to keep it open. See `find_cut_kind`."""
    return find_cut_kind(tokens, held_ms)[0]


def find_cut_kind(tokens, held_ms: int) -> tuple[int | None, bool]:
    """Where to close the segment made of `tokens`, and whether the cut ends a
    sentence (False for a soft cut, whose line continues into the next one).

    Checks, in order: the last finished sentence anywhere in the segment (the
    punctuation usually arrives glued to the next sentence's first word, and a
    single decode step can deliver a whole burst of tokens, so only the tail is
    not enough), then a soft cut once the segment has run `SOFT_CUT_MS` -- at the
    last clause mark if there is one, else at the last word boundary, else
    everything.
    """
    n = len(tokens)
    if n == 0:
        return None, False

    for i in range(n - 1, -1, -1):
        piece = tokens[i].rstrip()
        if piece and piece[-1] in SENTENCE_END_CHARS and ends_sentence(tokens_to_text(tokens[: i + 1])):
            return i + 1, True

    if held_ms < SOFT_CUT_MS:
        return None, False

    for i in range(n - 1, 0, -1):
        piece = tokens[i].rstrip()
        if piece and piece[-1] in CLAUSE_END_CHARS:
            return i + 1, False
    # A word boundary: the last token that starts a new word (leading space).
    # CJK has no spaces, so a run of CJK tokens falls through to "everything",
    # which is fine -- any character boundary is a word boundary there.
    for i in range(n - 1, 0, -1):
        if tokens[i].startswith((" ", "▁")):
            return i, False
    log(f"[sentence] soft cut after {held_ms}ms (no boundary found)")
    return n, False


# ---------------------------------------------------------------------------
# Punctuation
# ---------------------------------------------------------------------------

# Every mark either model can produce. A character that is neither one of
# these nor whitespace is "content", and content characters are what the raw
# transcript and the punctuator's output have in common -- the punctuator only
# inserts marks and reflows spaces, so aligning on content is exact.
ALL_MARKS = set("。！？，、；：,;:!?…") | {"."}
_SENT_ASCII = {"。": ".", "！": "!", "？": "?"}
_CLAUSE_ASCII = {"，": ",", "、": ",", "；": ";", "：": ":"}
_TO_ASCII = {**_SENT_ASCII, **_CLAUSE_ASCII}
# Removes the marks the ASR model already placed before the text goes to the
# punctuator, which expects unpunctuated input (fed "gold. The" it produced
# "gold .，The"). A period is only removed when it ends a word: "3.5" and
# "U.S." keep theirs.
_STRIP_RE = re.compile(r"[。！？，、；：,;:!?…]|\.(?=\s|$)")


def strip_marks(text: str) -> str:
    return re.sub(r"\s+", " ", _STRIP_RE.sub("", text)).strip()


def punctuator_applies(text: str) -> bool:
    """The CT-Transformer was trained on Chinese and English. For any other
    script it only appends a mark at the end, so it is skipped there."""
    for ch in text:
        if ch.isalpha() and not (ch.isascii() or _is_han(ch)):
            return False
    return True


def content_ends(tokens) -> list[int]:
    """Cumulative count of content characters through each token."""
    ends, n = [], 0
    for tok in tokens:
        n += sum(1 for ch in tok if not ch.isspace() and ch not in ALL_MARKS)
        ends.append(n)
    return ends


class Punctuator:
    """Wraps sherpa-onnx's offline punctuation model.

    `marks(raw)` returns where the model would put marks, as (k, mark) pairs
    where k is the number of content characters before the mark. Positions
    rather than text, because the model's output drops the spaces between
    Chinese and English ("讲cellular") and re-splits decimals ("3 . 5"); the
    transcript keeps the ASR text verbatim and only gains the marks.
    """

    def __init__(self, model_dir: str, threads: int = 2):
        import sherpa_onnx

        self._punct = sherpa_onnx.OfflinePunctuation(
            sherpa_onnx.OfflinePunctuationConfig(
                model=sherpa_onnx.OfflinePunctuationModelConfig(
                    ct_transformer=os.path.join(model_dir, "model.onnx"),
                    num_threads=threads,
                )
            )
        )

    def marks(self, raw: str) -> list[tuple[int, str]]:
        cleaned = strip_marks(raw)
        if not cleaned or not punctuator_applies(cleaned):
            return []
        out = self._punct.add_punctuation(cleaned)
        marks: list[tuple[int, str]] = []
        k = 0
        for ch in out:
            if ch in ALL_MARKS:
                # The model can emit a mark next to a kept one ("U.S." + "。").
                # Only the first mark at a position counts.
                if not marks or marks[-1][0] != k:
                    marks.append((k, ch))
            elif not ch.isspace():
                k += 1
        expected = sum(1 for ch in cleaned if not ch.isspace() and ch not in ALL_MARKS)
        if k != expected:
            log(f"[punct] alignment failed ({k} vs {expected} content chars), skipping")
            return []
        return marks


def apply_marks(raw: str, marks, drop_trailing: bool) -> str:
    """Rebuilds `raw` with the punctuator's marks inserted at content positions.

    The ASR model's own marks are dropped (the punctuator has the final say),
    decimals and in-word periods are kept. After an ASCII letter or digit a mark
    is written in its ASCII form and followed by a space, and the next sentence
    starts with a capital. `drop_trailing` skips a mark after the very last
    character: the model always closes its input with one, which is right for a
    finished line and wrong for a sentence still being spoken.
    """
    positions = [i for i, ch in enumerate(raw) if not ch.isspace() and ch not in ALL_MARKS]
    total = len(positions)
    inserts: dict[int, str] = {}
    for k, mark in marks:
        if k <= 0 or k > total or (k == total and drop_trailing):
            continue
        inserts.setdefault(k, mark)

    def kept_mark(j: int) -> bool:
        """A period glued to content on both sides ("3.5", "U.S.") stays."""
        return raw[j] == "." and 0 < j < len(raw) - 1 \
            and not raw[j - 1].isspace() and not raw[j + 1].isspace() \
            and raw[j + 1] not in ALL_MARKS

    def next_content(j: int) -> str:
        for ch in raw[j:]:
            if not ch.isspace() and ch not in ALL_MARKS:
                return ch
        return ""

    out: list[str] = []
    count = 0
    capitalize_next = False
    for i, ch in enumerate(raw):
        if ch.isspace():
            out.append(ch)
            continue
        if ch in ALL_MARKS:
            if kept_mark(i):
                out.append(ch)
            continue
        if capitalize_next and ch.isascii() and ch.isalpha():
            ch = ch.upper()
        capitalize_next = False
        out.append(ch)
        count += 1
        mark = inserts.get(count)
        if mark is None:
            continue
        # The punctuator re-splits "3.5" into "3 . 5"; that "." is the one we
        # already keep, not a new mark.
        if i + 1 < len(raw) and raw[i + 1] in ALL_MARKS and kept_mark(i + 1):
            continue
        following = next_content(i + 1)
        if raw[i].isascii() and raw[i].isalnum() and not (following and _is_cjk(following)):
            mark = _TO_ASCII.get(mark, mark)
            out.append(mark)
            if i + 1 < len(raw) and not raw[i + 1].isspace():
                out.append(" ")
            capitalize_next = mark in ".!?"
        else:
            out.append(mark)
    return polish_text("".join(out))


_CJK_SPACE_RE = re.compile(r"(?<=[㐀-鿿＀-￯　-〿])\s+(?=[㐀-鿿])")


def polish_text(text: str) -> str:
    """Display clean-up shared by punctuated and raw lines.

    Dropping the ASR model's own comma can leave "唐酵解 发生" behind, and a
    fullwidth mark before a space token gives "呼吸， 也": Chinese takes no
    spaces between its own characters or after its own marks. And every line
    starts a sentence now, so it opens with a capital.
    """
    text = re.sub(r"\s+", " ", text).strip()
    text = _CJK_SPACE_RE.sub("", text)
    if text and text[0].isascii() and text[0].islower():
        text = text[0].upper() + text[1:]
    return text


def cut_from_marks(tokens, marks, kinds, ends=None) -> int | None:
    """Tokens to commit so the segment closes right after the last mark of one
    of `kinds` that (a) is not the artifact after the final character and
    (b) falls on a token boundary; None if there is no such mark."""
    ends = ends if ends is not None else content_ends(tokens)
    total = ends[-1] if ends else 0
    for k, mark in reversed(marks):
        if mark not in kinds or k <= 0 or k >= total:
            continue
        # The last token whose content ends exactly here; pure-mark tokens
        # right after it (a comma the ASR model placed) travel with it.
        idx = None
        for i, end in enumerate(ends):
            if end == k:
                idx = i
            elif end > k:
                break
        if idx is None:
            continue
        if mark in _SENT_ASCII or mark in ".!?":
            if not ends_sentence(apply_marks(tokens_to_text(tokens[: idx + 1]), [(k, mark)], False)):
                continue
        return idx + 1
    return None


SENT_MARK_KINDS = set("。！？.!?")
CLAUSE_MARK_KINDS = set("，、；：,;:")


def parse_chunk_ms(value) -> int:
    try:
        chunk = int(value)
    except (TypeError, ValueError):
        chunk = -1
    if chunk not in CHUNK_CHOICES:
        log(f"[args] bad --chunk-ms {value!r}, using {DEFAULT_CHUNK_MS}")
        return DEFAULT_CHUNK_MS
    return chunk


# ---------------------------------------------------------------------------
# Engine
# ---------------------------------------------------------------------------


class Engine:
    """The loaded sherpa-onnx recogniser. Built once at process start, before the
    READY line, because a first run downloads ~650 MB of weights."""

    def __init__(self, chunk_ms: int = DEFAULT_CHUNK_MS, threads: int = 4,
                 on_stage=None):
        self.chunk_ms = chunk_ms
        self.threads = threads
        self.on_stage = on_stage
        self.recognizer = None
        self.punctuator: Punctuator | None = None
        self.model_dir = None

    @property
    def repo(self) -> str:
        return MODEL_REPO.format(chunk=self.chunk_ms)

    @property
    def revision(self) -> str | None:
        return MODEL_REVISIONS.get(self.chunk_ms)

    def load(self):
        # huggingface_hub prints progress bars to stdout, which is the channel
        # Swift scans for READY. Redirect anything it prints to stderr.
        with contextlib.redirect_stdout(sys.stderr):
            self._load()

    def _load(self):
        cached = self._cached_snapshot(self.repo, ("encoder.int8.onnx", "decoder.int8.onnx",
                                                   "joiner.int8.onnx", "tokens.txt"),
                                       revision=self.revision)
        punct_cached = self._cached_snapshot(PUNCT_MODEL_REPO, PUNCT_MODEL_FILES,
                                             revision=PUNCT_MODEL_REVISION)
        total = 3 + (0 if cached and punct_cached else 1)
        step = 0
        current = ""

        def emit(key: str):
            log(f"[engine] ({step}/{total}) {key}")
            if self.on_stage:
                self.on_stage(key, step, total)

        def stage(key: str):
            """Report a loading step. Only the key crosses the boundary; the app
            localizes it, so the sidecar carries no UI strings."""
            nonlocal step, current
            step += 1
            current = key
            emit(key)

        def stage_repeat():
            """Re-announce the step in progress without advancing it."""
            if current:
                emit(current)

        if cached and punct_cached:
            self.model_dir, punct_dir = cached, punct_cached
        else:
            stage("download")
            with stage_heartbeat(stage_repeat):
                self.model_dir = cached or self._download(self.repo, self.revision)
                punct_dir = punct_cached or self._download(
                    PUNCT_MODEL_REPO, PUNCT_MODEL_REVISION,
                    allow_patterns=list(PUNCT_MODEL_FILES))

        stage("streaming")
        self.recognizer = self._build_recognizer(self.model_dir)

        stage("punct")
        try:
            self.punctuator = Punctuator(punct_dir)
        except Exception as exc:
            # Degraded but usable: line breaks fall back to the ASR model's own
            # sparse marks and the timed cuts.
            log(f"[engine] punctuation model unavailable, continuing without: {exc}")
            self.punctuator = None

        # First inference pays for onnxruntime session setup. Burn that on
        # silence now, before the user's first words.
        stage("warmup")
        try:
            warm = Transcriber(self, language=None)
            warm.feed(bytes(SAMPLE_RATE * 2))
            warm.finish()
        except Exception as exc:
            log(f"[engine] warmup failed (non-fatal): {exc}")
        log(f"[engine] ready: {self.repo} on {self.threads} threads")

    @staticmethod
    def _download(repo: str, revision: str | None, **kwargs) -> str:
        """snapshot_download with the pin applied only when there is one: the
        hub treats a missing `revision` as main, and the pins in
        MODEL_REVISIONS start out empty."""
        from huggingface_hub import snapshot_download

        if revision:
            kwargs["revision"] = revision
        return snapshot_download(repo, **kwargs)

    @classmethod
    def _cached_snapshot(cls, repo: str, required, revision: str | None = None) -> str | None:
        """Path of an already-downloaded model, or None. Avoids reporting a
        download stage (and touching the network) when nothing is needed."""
        try:
            path = cls._download(repo, revision, local_files_only=True)
        except Exception:
            return None
        if all(os.path.exists(os.path.join(path, name)) for name in required):
            return path
        return None

    def _build_recognizer(self, model_dir: str):
        import sherpa_onnx

        return sherpa_onnx.OnlineRecognizer.from_transducer(
            tokens=os.path.join(model_dir, "tokens.txt"),
            encoder=os.path.join(model_dir, "encoder.int8.onnx"),
            decoder=os.path.join(model_dir, "decoder.int8.onnx"),
            joiner=os.path.join(model_dir, "joiner.int8.onnx"),
            num_threads=self.threads,
            sample_rate=SAMPLE_RATE,
            feature_dim=FEATURE_DIM,
            # Segmentation is done here from token timestamps (see module doc);
            # sherpa's endpointing would only be useful together with reset().
            enable_endpoint_detection=False,
            # nemotron only supports greedy search in sherpa-onnx today.
            decoding_method="greedy_search",
            provider="cpu",
        )


# ---------------------------------------------------------------------------
# Transcriber: one stream plus segment bookkeeping
# ---------------------------------------------------------------------------


class Transcriber:
    """Owns one sherpa-onnx OnlineStream and turns its ever-growing token list
    into the partial/final events the app expects.

    Synchronous and single-threaded by design: the live session drives it from
    one executor thread, file import from another instance. It never touches the
    socket, so it can be unit-tested with a fake recogniser.
    """

    def __init__(self, engine: Engine, language: str | None):
        self.engine = engine
        self.recognizer = engine.recognizer
        self.language = resolve_language(language)
        self.stream = self.recognizer.create_stream()
        if self.language:
            self.stream.set_option("language", self.language)
        self.punctuator = engine.punctuator if self._punctuator_fits(self.language) else None
        # Marks for the current raw segment text, recomputed only when it changes.
        self._marks_for: str | None = None
        self._marks: list[tuple[int, str]] = []

        # Audio fed so far, counted in samples rather than milliseconds. A mic
        # frame is 4096/3 samples at 16 kHz, so rounding each one down to whole
        # ms lost ~0.33 ms per 85 ms -- 4.8 s after twenty minutes, by which
        # point nothing could stay quiet long enough to close a line, because
        # the token timestamps this clock is compared against come from sherpa
        # and are sample-accurate.
        self.stream_samples = 0
        self.offset = 0             # tokens already committed to closed segments
        self.segment_id = 0
        self.partial_text = ""
        # Of the open segment: onset of its first token, and of the newest token.
        self.first_token_ms: int | None = None
        self.last_token_ms: int | None = None
        # End of the most recent frame whose energy read as voice.
        self.last_voiced_ms: int | None = None

        self._decode_calls = 0
        # (seconds spent decoding, ms of audio fed) per frame, bounded so the
        # reported speed reflects now rather than a lifetime average.
        self._recent: deque[tuple[float, int]] = deque(maxlen=STATS_EVERY)

    def set_language(self, language: str | None):
        """Re-pins the language; nemotron reads it on every decode call, so it
        takes effect from the next chunk without touching the encoder cache."""
        self.language = resolve_language(language)
        self.stream.set_option("language", self.language or "")
        self.punctuator = self.engine.punctuator if self._punctuator_fits(self.language) else None
        self._marks_for = None

    @staticmethod
    def _punctuator_fits(language: str | None) -> bool:
        """The punctuation model covers Chinese and English; with auto-detect
        the text itself is checked per call (see punctuator_applies)."""
        return language is None or language.split("-")[0].lower() in ("en", "zh")

    def _marks_for_text(self, raw: str) -> list[tuple[int, str]]:
        if self.punctuator is None or not raw:
            return []
        if raw != self._marks_for:
            self._marks_for = raw
            try:
                self._marks = self.punctuator.marks(raw)
            except Exception as exc:
                log(f"[punct] {exc}")
                self._marks = []
        return self._marks

    @property
    def stream_ms(self) -> int:
        """Audio fed so far. Derived from the sample count every time, so the
        error against sherpa's own clock stays below one millisecond however
        the frames are cut."""
        return self.stream_samples * 1000 // SAMPLE_RATE

    @property
    def held_ms(self) -> int:
        if self.first_token_ms is None:
            return 0
        return self.stream_ms - self.first_token_ms

    def feed(self, pcm: bytes) -> list[dict]:
        """Consume one PCM frame; returns the events it produced."""
        if len(pcm) % 2:
            pcm = pcm[:-1]  # keep Int16 alignment across frame boundaries
        if not pcm:
            return []
        before_ms = self.stream_ms
        self.stream_samples += len(pcm) // 2
        frame_ms = self.stream_ms - before_ms
        if frame_rms(pcm) >= VOICE_RMS_THRESHOLD:
            self.last_voiced_ms = self.stream_ms
        self.stream.accept_waveform(SAMPLE_RATE, pcm_to_float(pcm))
        return self._decode(frame_ms=frame_ms)

    def finish(self) -> list[dict]:
        """End of audio: flush the encoder and close whatever is open."""
        # Tail padding lets the encoder's look-ahead release the last tokens;
        # without it the final word of a recording is often missing.
        self.stream.accept_waveform(SAMPLE_RATE, np.zeros(SAMPLE_RATE // 2, dtype=np.float32))
        self.stream.input_finished()
        events = self._decode(closing=True)
        result = self.recognizer.get_result_all(self.stream)
        tokens, timestamps = self._segment_tokens(result)
        if tokens:
            events += self._commit(tokens, len(tokens), result, timestamps,
                                   self._marks_for_text(tokens_to_text(tokens)))
        return events

    # ---- internals ------------------------------------------------------

    def _decode(self, closing: bool = False, frame_ms: int = 0) -> list[dict]:
        started = time.monotonic()
        while self.recognizer.is_ready(self.stream):
            self.recognizer.decode_stream(self.stream)
            self._decode_calls += 1
        self._recent.append((time.monotonic() - started, frame_ms))
        if len(self._recent) == self._recent.maxlen:
            self._log_stats()
            self._recent.clear()

        result = self.recognizer.get_result_all(self.stream)
        tokens, timestamps = self._segment_tokens(result)
        events: list[dict] = []

        if tokens:
            if self.first_token_ms is None:
                self.first_token_ms = self._ms(result, timestamps[0])
            self.last_token_ms = self._ms(result, timestamps[-1])

        raw = tokens_to_text(tokens)
        marks = self._marks_for_text(raw)
        # A partial is a sentence still being spoken, so the mark the
        # punctuator always puts after the last word is left off.
        text = apply_marks(raw, marks, drop_trailing=True) if marks else polish_text(raw)
        if text != self.partial_text:
            self.partial_text = text
            if text:
                events.append(self._event("partial", text))

        if closing or not tokens:
            return events

        cut, sentence_end = self._find_cut(tokens, marks)
        if cut is None and self._in_pause():
            cut, sentence_end = len(tokens), True
        if cut:
            events += self._commit(tokens, cut, result, timestamps, marks,
                                   sentence_end=sentence_end)
            # Whatever remains after the cut is the start of the next segment;
            # report it right away so the screen never goes blank mid-word.
            rest, rest_ts = self._segment_tokens(result)
            if rest:
                self.first_token_ms = self._ms(result, rest_ts[0])
                self.last_token_ms = self._ms(result, rest_ts[-1])
                rest_raw = tokens_to_text(rest)
                rest_marks = self._marks_for_text(rest_raw)
                self.partial_text = apply_marks(rest_raw, rest_marks, True) if rest_marks \
                    else polish_text(rest_raw)
                if self.partial_text:
                    events.append(self._event("partial", self.partial_text))
        return events

    def _find_cut(self, tokens, marks) -> tuple[int | None, bool]:
        """Where to close the open segment, and whether that ends a sentence.
        Prefers the punctuation model's sentence ends, then its clause marks
        once the soft cut is due, then the ASR model's own marks and word
        boundaries (`find_cut_kind`)."""
        if marks:
            ends = content_ends(tokens)
            cut = cut_from_marks(tokens, marks, SENT_MARK_KINDS, ends)
            if cut is not None:
                return cut, True
            if self.held_ms >= SOFT_CUT_MS:
                cut = cut_from_marks(tokens, marks, CLAUSE_MARK_KINDS, ends)
                if cut is not None:
                    return cut, False
        return find_cut_kind(tokens, self.held_ms)

    def _segment_tokens(self, result):
        """The open segment's tokens and timestamps, skipping any leading
        punctuation-only pieces (which belonged to the previous sentence)."""
        tokens = result.tokens
        timestamps = result.timestamps
        start = self.offset
        while start < len(tokens) and all(ch in LEADING_SKIP_CHARS for ch in tokens[start]):
            start += 1
        if start != self.offset:
            self.offset = start
        return list(tokens[start:]), list(timestamps[start:])

    def _in_pause(self) -> bool:
        """Quiet for PAUSE_CLOSE_MS: no voice energy and no new token."""
        if self.last_token_ms is None:
            return False
        quiet_since = self.last_token_ms
        if self.last_voiced_ms is not None:
            quiet_since = max(quiet_since, self.last_voiced_ms)
        return self.stream_ms - quiet_since >= PAUSE_CLOSE_MS

    def _commit(self, tokens, count: int, result, timestamps, marks=(),
                sentence_end: bool = True) -> list[dict]:
        """Closes the segment made of the first `count` open tokens.

        `sentence_end` is False for a soft cut: the line was broken only to
        keep it readable, and its sentence carries on in the next one. The app
        translates such lines together with their continuation rather than as
        a half sentence on their own."""
        text = tokens_to_text(tokens[:count])
        if marks:
            # Marks up to and including the one this line ends on. A line closed
            # by a pause keeps the trailing mark: that is where its sentence ends.
            limit = content_ends(tokens[:count])[-1] if count else 0
            text = apply_marks(text, [(k, m) for k, m in marks if k <= limit], drop_trailing=False)
        else:
            text = polish_text(text)
        events: list[dict] = []
        if text:
            self.partial_text = text
            end = self.stream_ms
            if count <= len(timestamps):
                end = min(end, self._ms(result, timestamps[count - 1]) + TOKEN_TAIL_MS)
            final = self._event("final", text, end_ms=end)
            final["sentenceEnd"] = sentence_end
            events.append(final)
            self.segment_id += 1
        self.offset += count
        self.partial_text = ""
        self.first_token_ms = None
        self.last_token_ms = None
        self._marks_for = None
        return events

    @staticmethod
    def _ms(result, timestamp: float) -> int:
        return int((result.start_time + timestamp) * 1000)

    def _event(self, kind: str, text: str, end_ms: int | None = None) -> dict:
        start = self.first_token_ms if self.first_token_ms is not None else self.stream_ms
        # A closed line ends shortly after its last token; a partial is still
        # growing, so it runs to now.
        end = self.stream_ms if end_ms is None else end_ms
        return {
            "type": kind,
            "segmentId": self.segment_id,
            "startMs": max(0, min(int(start), end)),
            "endMs": max(0, int(end)),
            "text": text,
        }

    def _log_stats(self):
        spent = sum(t for t, _ in self._recent)
        audio_ms = sum(ms for _, ms in self._recent)
        if audio_ms <= 0:
            return
        log(f"[streaming] {self._decode_calls} decode calls, "
            f"last {audio_ms}ms of audio took {spent * 1000:.0f}ms "
            f"(RTF {spent / (audio_ms / 1000):.2f})")


# ---------------------------------------------------------------------------
# Session
# ---------------------------------------------------------------------------


class Session:
    def __init__(self, ws, engine: Engine, default_language: str | None):
        self.ws = ws
        self.engine = engine
        self.language = default_language
        # Inference off the event loop, and on exactly one thread so frames are
        # decoded in order.
        self._pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="asr")
        self._transcriber: Transcriber | None = None

        # Audio arrives faster than it can be decoded when the machine is
        # loaded, so reading and processing are separate tasks joined by this
        # queue. Nothing is ever dropped: with no second pass, a skipped frame
        # would be a hole in the transcript rather than a lost partial.
        self._inbox: asyncio.Queue = asyncio.Queue()
        self._worker: asyncio.Task | None = None
        self._queued_bytes = 0
        self._warned_lag_ms = 0

        # A file import runs as its own task so the socket keeps being read
        # while it does -- that is what makes cancelling one possible at all.
        self.file_task: asyncio.Task | None = None
        # Set once a send has failed with ConnectionClosed: the client is gone
        # and a file job has nobody left to transcribe for.
        self._peer_gone = False
        # Set by finish(): the live transcriber is dropped there, so a frame
        # arriving afterwards would build a second one whose clock starts at 0.
        self._finished = False
        self._warned_late_frame = False

    # ---- plumbing -------------------------------------------------------

    async def _run(self, fn, *a, **kw):
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(self._pool, lambda: fn(*a, **kw))

    async def _send(self, payload: dict):
        try:
            await self.ws.send(json.dumps(payload, ensure_ascii=False))
        except websockets.ConnectionClosed:
            # Still swallowed -- a disconnect must not raise out of a decode --
            # but remembered, so a file job can stop instead of spending an hour
            # transcribing for a client that has already gone.
            self._peer_gone = True

    async def _send_error(self, code: str, message: str):
        """`code` is what the app localizes on; `message` only ever reaches a
        log, so it carries the path or the exception rather than UI text."""
        await self._send({"type": "error", "code": code, "message": message})

    async def _emit_all(self, events: list[dict]):
        for ev in events:
            await self._send(ev)

    def _get_transcriber(self) -> Transcriber:
        if self._transcriber is None:
            self._transcriber = Transcriber(self.engine, self.language)
        return self._transcriber

    # ---- live streaming -------------------------------------------------

    async def start(self):
        self._worker = asyncio.create_task(self._process_loop())

    def enqueue(self, pcm: bytes):
        """Called from the socket read loop. Never blocks on inference."""
        if self._finished:
            if not self._warned_late_frame:
                self._warned_late_frame = True
                log("[ws] audio arrived after eof, dropping it")
            return
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
        while not self._inbox.empty():
            await asyncio.sleep(0.02)

    async def feed(self, pcm: bytes):
        transcriber = self._get_transcriber()
        events = await self._run(transcriber.feed, pcm)
        await self._emit_all(events)

        lag_ms = self._queued_bytes // BYTES_PER_MS
        if lag_ms > 2000 and lag_ms >= self._warned_lag_ms + 2000:
            self._warned_lag_ms = lag_ms
            log(f"[streaming] decoding is {lag_ms}ms behind the microphone")
        elif lag_ms < 500:
            self._warned_lag_ms = 0

    async def set_language(self, language: str | None):
        self.language = language
        if self._transcriber is not None:
            await self._run(self._transcriber.set_language, language)

    async def finish(self):
        """Client signalled end of audio: decode what is queued, close the open
        segment, and say goodbye."""
        self._finished = True
        await self.drain_inbox()
        if self._transcriber is not None:
            events = await self._run(self._transcriber.finish)
            await self._emit_all(events)
            self._transcriber = None
        await self._send({"type": "eof"})

    async def cancel_file(self):
        """Stops a running file import. The slice already handed to the worker
        thread (200 ms of audio) finishes and its result is dropped."""
        task, self.file_task = self.file_task, None
        if task is None or task.done():
            return
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task

    async def close(self):
        await self.cancel_file()
        if self._worker is not None:
            self._worker.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._worker
            self._worker = None
        self._pool.shutdown(wait=False)

    # ---- file import ----------------------------------------------------

    async def transcribe_file(self, path: str):
        if not os.path.exists(path):
            await self._send_error("file.missing", f"file not found: {path}")
            return
        try:
            reader = await self._run(open_wav_pcm16_mono_16k, path)
        except Exception as exc:
            log(f"[file] {traceback.format_exc()}")
            await self._send_error("file.unreadable", f"cannot read audio: {exc}")
            return

        # Bytes of PCM, straight from the header, so the very first progress
        # frame already carries the real size instead of a placeholder.
        total = reader.getnframes() * 2
        await self._send({"type": "progress", "completed": 0, "total": total})
        # A private transcriber, so a file import never disturbs a live stream
        # on the same connection.
        transcriber = Transcriber(self.engine, self.language)
        # Small slices so pause detection has the same resolution as live audio,
        # and so only 200 ms of PCM is resident rather than the whole lecture.
        slice_frames = 200 * SAMPLE_RATE // 1000
        done = 0
        slices = 0
        try:
            try:
                while True:
                    # A cancel scheduled while the last slice decoded is
                    # delivered here, before another one is started.
                    await asyncio.sleep(0)
                    if self._peer_gone or self.ws.close_code is not None:
                        log("[file] client is gone, aborting")
                        return
                    chunk = await self._run(reader.readframes, slice_frames)
                    if not chunk:
                        break
                    done += len(chunk)
                    slices += 1
                    events = await self._run(transcriber.feed, chunk)
                    # Only committed lines matter for an import; partials would
                    # just churn the UI.
                    await self._emit_all([ev for ev in events if ev["type"] == "final"])
                    if slices % 10 == 0:
                        await self._send({"type": "progress", "completed": done, "total": total})
                events = await self._run(transcriber.finish)
                await self._emit_all([ev for ev in events if ev["type"] == "final"])
            except asyncio.CancelledError:
                # BaseException, so the handler below never sees it; caught only
                # to say in the log why the job stopped.
                log("[file] cancelled")
                raise
            except Exception as exc:
                log(f"[file] {traceback.format_exc()}")
                await self._send_error("file.failed", f"file transcription failed: {exc}")
                return
        finally:
            with contextlib.suppress(Exception):
                reader.close()
        # A truncated file holds fewer frames than its header promises; report
        # what was really decoded so the bar still reaches the end.
        total = max(total, done)
        await self._send({"type": "progress", "completed": total, "total": total})
        await self._send({"type": "eof"})


def open_wav_pcm16_mono_16k(path: str) -> wave.Wave_read:
    """Opens a WAV the app has already converted to 16 kHz mono Int16.

    The Swift side does the format conversion with AVFoundation, which handles
    every container macOS can play; this only has to validate the header. The
    caller reads it slice by slice and closes it -- a three-hour lecture is
    ~350 MB of PCM, which is not worth holding beside the models.
    """
    w = wave.open(path, "rb")
    try:
        rate, channels, width = w.getframerate(), w.getnchannels(), w.getsampwidth()
        if (rate, channels, width) != (SAMPLE_RATE, 1, 2):
            raise ValueError(f"expected 16 kHz mono 16-bit WAV, got {rate} Hz, "
                             f"{channels} ch, {width * 8}-bit")
    except Exception:
        w.close()
        raise
    return w


# ---------------------------------------------------------------------------
# Server
# ---------------------------------------------------------------------------

# Tasks that must outlive the call that created them. asyncio keeps only weak
# references to running tasks, so anything not held here can be collected.
_BACKGROUND_TASKS: set[asyncio.Task] = set()


async def _exit_when_parent_gone(parent_pid: int, interval: float = 5.0):
    """Exit once the app that spawned us is gone.

    The sidecar is kept warm across recordings, so nothing else would reap it if
    the app crashed or was force-quit -- it would sit there holding the model and
    its port. signal 0 only checks whether the pid is still alive.
    """
    while True:
        await asyncio.sleep(interval)
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
        # and the sidecar stayed resident with the model loaded.
        with contextlib.suppress(Exception):
            log(f"[parent] pid {parent_pid} is gone, exiting")
        os._exit(0)


def _report_file_job(task: asyncio.Task):
    """Retrieves a finished file job's result. Nothing awaits these tasks on the
    success path, and an unretrieved exception would only surface as asyncio's
    'never retrieved' warning at collection time."""
    if task.cancelled():
        return
    exc = task.exception()
    if exc is not None:
        log(f"[file] job failed: {exc!r}")


async def handle_connection(ws, engine: Engine, default_language: str | None):
    session = Session(ws, engine, default_language)
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
                # The model is multilingual, so a language change is just a new
                # prompt on the stream -- no restart, no model swap.
                await session.set_language(lang if lang and lang != "auto" else None)
            elif kind == "eof":
                await session.finish()
            elif kind == "file":
                # As a task, so this loop keeps reading: a cancel -- or the
                # ConnectionClosed that ends it -- has to be able to arrive
                # while the job runs, which is the whole point.
                if session.file_task is not None and not session.file_task.done():
                    await session._send_error("file.failed",
                                              "a file job is already running")
                    continue
                session.file_task = asyncio.create_task(
                    session.transcribe_file(cmd.get("path", "")))
                session.file_task.add_done_callback(_report_file_job)
            elif kind == "cancel":
                await session.cancel_file()
                await session._send({"type": "eof"})
            else:
                log(f"[ws] unknown command: {kind}")
    except websockets.ConnectionClosed:
        log("[ws] client disconnected")
    except Exception:
        log(f"[ws] {traceback.format_exc()}")
        await session._send_error("internal", "local engine internal error")
    finally:
        await session.close()


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--language", default=None,
                        help="source language hint, e.g. zh, en, ja; omit for auto")
    parser.add_argument("--chunk-ms", default=DEFAULT_CHUNK_MS,
                        help=f"streaming chunk size, one of {CHUNK_CHOICES}")
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--exit-with-parent", type=int, default=0,
                        help="pid to watch; exit when it goes away")
    # Older builds of the app passed engine/device/quality flags to the MLX
    # sidecar. Accept and ignore anything unknown so they keep starting.
    args, unknown = parser.parse_known_args()
    if unknown:
        log(f"[args] ignoring {unknown}")

    # Model loading happens before the WebSocket exists, so progress has to go out
    # on stdout -- the same channel Swift already reads for READY. Without this the
    # app looks frozen while weights download. It goes through handshake() because
    # Engine.load() has sys.stdout redirected for the duration.
    def emit_stage(key: str, step: int, total: int):
        handshake(f"STAGE {step}/{total} {key}")

    engine = Engine(chunk_ms=parse_chunk_ms(args.chunk_ms), threads=args.threads,
                    on_stage=emit_stage)
    try:
        await asyncio.get_running_loop().run_in_executor(None, engine.load)
    except Exception:
        log(f"[fatal] model load failed: {traceback.format_exc()}")
        # Swift waits for READY on stdout; without this it would block for the
        # full timeout instead of surfacing the failure.
        handshake("FATAL model load failed")
        sys.exit(1)

    language = args.language if args.language and args.language != "auto" else None

    async def handler(ws):
        await handle_connection(ws, engine, language)

    if args.exit_with_parent:
        # The loop holds only a weak reference to a task, so the watchdog has to
        # be kept alive here or it can be collected mid-run and nothing is left
        # to reap the sidecar.
        watchdog = asyncio.create_task(_exit_when_parent_gone(args.exit_with_parent))
        _BACKGROUND_TASKS.add(watchdog)
        watchdog.add_done_callback(_BACKGROUND_TASKS.discard)

    server = await websockets.serve(
        handler, "127.0.0.1", args.port,
        max_size=None,        # audio frames are small, but never truncate one
        ping_interval=20,
        ping_timeout=60,
    )
    handshake(f"READY port={args.port}")
    await server.wait_closed()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
