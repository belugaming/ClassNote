#!/usr/bin/env python3
"""Confucius4-R2T2 streaming recogniser on MLX, for asr_server.py.

R2T2 (NetEase Youdao, Apache-2.0) is Qwen3-ASR-1.7B fine-tuned for "longest
stable prefix" decoding. Every step re-decodes the audio heard so far with the
text already committed as the start of the assistant turn, generates a few
tokens, and commits everything but the last token -- so committed text is only
ever appended to, never rewritten.

The reference implementation (github.com/netease-youdao/Confucius4-R2T2,
``streaming_transcribe_no_reset``) runs on vLLM. This is a port of that
algorithm onto mlx-audio's Qwen3-ASR model, which loads the same weights:

* The audio is a rolling window. Once it passes WINDOW_MAX_S, the oldest
  WINDOW_DROP_S are dropped together with the text committed while they were
  current, so a two-hour lecture costs the same per step as its first minute.
* The prompt is built here rather than by mlx-audio, whose helper adds a
  newline after the system prompt that the model was not trained with.
* Audio that piles up while a step runs is decoded together in the next one,
  so a slow machine falls behind by one step rather than by a growing queue.

Only ``R2T2Model`` touches MLX. ``R2T2Stream`` is plain Python over a small
model interface (generate/encode/decode), which is what the tests drive.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field

import numpy as np

SAMPLE_RATE = 16000

# mlx-community's 8-bit conversion of netease-youdao/Confucius4-R2T2: ~2.5 GB,
# the audio tower left unquantized.
MODEL_REPO = "mlx-community/Confucius4-R2T2-8bit"
# Commit to download. None means "whatever main points at"; pinned from the CI
# job that prints model_info(...).sha, as for every other model the app uses.
MODEL_REVISION: str | None = "2d6d997c3e09c65a65b1b2576b6b9b7728df8eab"

# Rolling audio window (seconds). The reference implementation's values.
WINDOW_MAX_S = 16
WINDOW_DROP_S = 8
# Tokens held back from each decode: the last one may still change once more
# audio arrives. 1 is what every reference caller uses.
UNFIXED_TOKENS = 1
# Tokens generated per step. Small on purpose: a step only needs to reach a
# little past what is already committed, and each token costs a forward pass.
BASE_NEW_TOKENS = 2
MAX_NEW_TOKENS = 8
# A flush (a pause, or the end of audio) commits everything, so it may need to
# write out a whole trailing clause.
FLUSH_NEW_TOKENS = 32
# Text kept in the prompt as the system turn, capped like the reference server.
MAX_CONTEXT_CHARS = 4000

ASR_TEXT_TAG = "<asr_text>"

# Qwen3-ASR's language names, keyed by the codes the app uses.
LANGUAGE_NAMES = {
    "zh": "Chinese", "yue": "Cantonese", "en": "English", "ja": "Japanese",
    "ko": "Korean", "fr": "French", "de": "German", "es": "Spanish",
    "pt": "Portuguese", "it": "Italian", "ru": "Russian", "ar": "Arabic",
    "id": "Indonesian", "th": "Thai", "vi": "Vietnamese", "tr": "Turkish",
    "hi": "Hindi", "ms": "Malay", "nl": "Dutch", "sv": "Swedish",
    "da": "Danish", "fi": "Finnish", "pl": "Polish", "cs": "Czech",
    "fil": "Filipino", "fa": "Persian", "el": "Greek", "ro": "Romanian",
    "hu": "Hungarian", "mk": "Macedonian",
}


def language_name(code: str | None) -> str | None:
    """Qwen3-ASR's name for an app language code, or None for auto-detect."""
    if not code:
        return None
    base = code.strip().lower().replace("_", "-")
    if base in ("", "auto"):
        return None
    if base.startswith("zh-hk") or base.startswith("yue"):
        return "Cantonese"
    return LANGUAGE_NAMES.get(base.split("-")[0])


# ---------------------------------------------------------------------------
# Text helpers (after the reference implementation)
# ---------------------------------------------------------------------------

_EN2ZH_PUNCT = {",": "，", ".": "。", "!": "！", "?": "？", ";": "；", ":": "：",
                "(": "（", ")": "）"}
_ZH2EN_PUNCT = {v: k for k, v in _EN2ZH_PUNCT.items()}
_ALL_PUNCT_RE = re.compile(r"[,\.!?;:()，。！？；：（）]")
_CJK_GAP_RE = re.compile(r"(?<=[一-鿿])\s+(?=[一-鿿])")


def normalize_punct(text: str) -> str:
    """Fullwidth marks after Chinese, ASCII marks after Latin letters/digits.

    The model mixes the two in code-switched speech; the reference normalizes
    every generated piece this way, and the prefix it feeds back is what the
    model conditions on next.
    """
    def replace(m):
        mark = m.group()
        prev = ""
        for i in range(m.start() - 1, -1, -1):
            if not text[i].isspace():
                prev = text[i]
                break
        if not prev:
            return mark
        if "一" <= prev <= "鿿":
            return _EN2ZH_PUNCT.get(mark, mark)
        if prev.isascii() and (prev.isalnum() or prev in "\"'"):
            return _ZH2EN_PUNCT.get(mark, mark)
        return mark
    return _ALL_PUNCT_RE.sub(replace, text)


def split_output(raw: str, forced: str | None) -> tuple[str | None, str | None]:
    """(language, text) from a decode. With a forced language the prompt
    already ends in ``language X<asr_text>``, so everything is text. With
    auto-detect the model writes that header itself; until it has, there is no
    text yet (None)."""
    raw = raw.split("|")[0]
    if forced:
        return forced, raw
    if ASR_TEXT_TAG not in raw:
        return None, None
    meta, text = raw.split(ASR_TEXT_TAG, 1)
    lang = meta.strip()
    if lang.lower().startswith("language"):
        lang = lang[len("language"):].strip()
    return (lang or None), text


def is_hallucinating(text: str, repeats: int = 5, max_len: int = 50) -> bool:
    """A tail pattern repeated `repeats` times ("okay. okay. okay. ..."): the
    decoder is stuck in a loop and its prefix must be dropped."""
    tail = text[-256:]
    n = len(tail)
    for k in range(1, max_len + 1):
        if n < k * repeats:
            break
        pattern = tail[-k:]
        if not pattern.strip(" \t,.!?;:，。！？；："):
            continue
        if all(tail[-(r + 1) * k:-r * k] == pattern for r in range(1, repeats)):
            return True
    return False


# ---------------------------------------------------------------------------
# Streaming state
# ---------------------------------------------------------------------------


@dataclass
class _Piece:
    text: str
    end_sample: int  # absolute sample count when it was committed


@dataclass
class R2T2Stream:
    """Longest-stable-prefix decoding over a rolling audio window.

    `model` needs three methods:
      generate(audio: np.float32[], context: str, language: str|None,
               prefix: str, max_new_tokens: int) -> str   (text after prefix)
      encode(text) -> list[int]
      decode(ids) -> str
    """

    model: object
    language: str | None = None          # forced language name, None = auto
    context: str = ""
    step_samples: int = 160 * SAMPLE_RATE // 1000

    audio: np.ndarray = field(default_factory=lambda: np.zeros(0, np.float32))
    pending: np.ndarray = field(default_factory=lambda: np.zeros(0, np.float32))
    window_start: int = 0                # absolute sample index of audio[0]
    pieces: list = field(default_factory=list)
    detected_language: str | None = None
    new_tokens: int = BASE_NEW_TOKENS
    steps: int = 0

    @property
    def total_samples(self) -> int:
        return self.window_start + len(self.audio) + len(self.pending)

    @property
    def committed(self) -> str:
        """Committed text still inside the window (the prompt prefix)."""
        return "".join(p.text for p in self.pieces)

    def accept(self, samples: np.ndarray) -> list[tuple[str, int]]:
        """Adds audio and runs a step if enough has arrived. Returns the newly
        committed pieces as (text, absolute end sample)."""
        if len(samples):
            self.pending = np.concatenate([self.pending, samples.astype(np.float32)])
        # The first step waits for two chunks: one step plus one of look-ahead,
        # as the reference caller does.
        needed = self.step_samples * (2 if self.steps == 0 and not len(self.audio) else 1)
        if len(self.pending) < needed:
            return []
        return self._step(flush=False)

    def flush(self) -> list[tuple[str, int]]:
        """Commits everything the audio so far supports, the held-back token
        included. Used on a pause and at the end of the stream."""
        if not len(self.pending) and not len(self.audio):
            return []
        return self._step(flush=True)

    def reset_text(self):
        """Starts afresh after a decoder loop. The audio goes too: decoding
        the same window again with no prefix would commit, a second time,
        everything already sent."""
        self.pieces.clear()
        self.window_start += len(self.audio)
        self.audio = np.zeros(0, np.float32)
        self.new_tokens = BASE_NEW_TOKENS

    # ---- internals ------------------------------------------------------

    def _step(self, flush: bool) -> list[tuple[str, int]]:
        if len(self.pending):
            self.audio = np.concatenate([self.audio, self.pending])
            self.pending = np.zeros(0, np.float32)
        self._trim_window()
        self.steps += 1

        prefix_text = self.committed
        prefix = prefix_text
        if not self.language and self.detected_language:
            prefix = f"language {self.detected_language}{ASR_TEXT_TAG}" + prefix_text
        prefix = prefix.split("|")[0]

        budget = FLUSH_NEW_TOKENS if flush else int(self.new_tokens)
        if not self.language and not self.detected_language:
            # Auto-detect: the model writes "language X<asr_text>" before any
            # text, which a step's usual budget cannot reach.
            budget = FLUSH_NEW_TOKENS
        generated = self.model.generate(self.audio, self.context[:MAX_CONTEXT_CHARS],
                                        self.language, prefix, budget)
        raw = normalize_punct(prefix + generated).replace("�", "")
        lang, text = split_output(raw, self.language)
        if text is None:
            # Auto-detect has not produced its language header yet.
            return []
        # Qwen3-ASR writes "language None" for audio without speech; locking
        # onto that would force "no language" on the rest of the lecture.
        if not self.language and lang and lang.lower() != "none" and text.strip():
            self.detected_language = lang
        if (lang or "") == "Chinese":
            text = _CJK_GAP_RE.sub("", text)

        fixed = text if flush else self._roll_back(text)
        new = self._new_part(fixed, prefix_text)
        out: list[tuple[str, int]] = []
        if new:
            end = self.window_start + len(self.audio)
            self.pieces.append(_Piece(new, end))
            out.append((new, end))
            self.new_tokens = BASE_NEW_TOKENS
        else:
            # Nothing stable yet: let the next step reach a little further.
            # Chinese needs about twice the tokens per second of speech.
            grow = 2 if self._last_is_cjk() else 1
            self.new_tokens = min(MAX_NEW_TOKENS, self.new_tokens + grow)

        if is_hallucinating(self.committed):
            self.reset_text()
        return out

    def _roll_back(self, text: str) -> str:
        """`text` minus its last UNFIXED_TOKENS tokens, stepping back further
        rather than cutting a multi-byte character in half."""
        ids = self.model.encode(text)
        k = UNFIXED_TOKENS
        while True:
            end = max(0, len(ids) - k)
            fixed = self.model.decode(ids[:end]) if end > 0 else ""
            if "�" not in fixed:
                return fixed
            if end == 0:
                return ""
            k += 1

    @staticmethod
    def _new_part(fixed: str, prefix_text: str) -> str:
        """What `fixed` adds after the committed prefix. The prefix was forced
        into the prompt, so a decode that does not start with it only means the
        tokenizer split its end differently; nothing is committed then."""
        f, p = fixed.strip(), prefix_text.strip()
        if not f.startswith(p):
            return ""
        new = f[len(p):]
        if not p:
            new = new.lstrip()
        return new

    def _last_is_cjk(self) -> bool:
        tail = self.committed.rstrip()
        return bool(tail) and "一" <= tail[-1] <= "鿿"

    def _trim_window(self):
        max_samples = WINDOW_MAX_S * SAMPLE_RATE
        if len(self.audio) <= max_samples:
            return
        drop = WINDOW_DROP_S * SAMPLE_RATE
        # Drop whole seconds from the front, as many as needed to get back
        # under the cap (a long stall can overshoot it by more than one drop).
        while len(self.audio) > max_samples:
            self.audio = self.audio[drop:]
            self.window_start += drop
        self.pieces = [p for p in self.pieces if p.end_sample > self.window_start]


# ---------------------------------------------------------------------------
# MLX model
# ---------------------------------------------------------------------------


class R2T2Model:
    """mlx-audio's Qwen3-ASR loaded with R2T2 weights, plus the one decode step
    the streaming algorithm needs: an arbitrary assistant prefix and a small
    token budget, greedy."""

    def __init__(self, path: str):
        from mlx_audio.stt import load

        wrapper = load(path)
        # mlx-audio wraps the model in a proxy whose __call__ takes *args, which
        # its own generate_step cannot see input_embeddings through.
        self.model = getattr(wrapper, "_model", wrapper)
        self.tokenizer = self.model._tokenizer
        self.eos = set(self.model._eos_token_ids())
        self.audio_token_id = self.model.config.audio_token_id

    def encode(self, text: str) -> list[int]:
        return self.tokenizer.encode(text, add_special_tokens=False)

    def decode(self, ids) -> str:
        return self.tokenizer.decode(list(ids), skip_special_tokens=False)

    @staticmethod
    def prompt(context: str, language: str | None, n_audio: int) -> str:
        """The Qwen3-ASR chat prompt, exactly as the model was trained on it:
        the context is the system turn with no newline after it."""
        text = ("<|im_start|>system\n" + (context or "") + "<|im_end|>\n"
                "<|im_start|>user\n<|audio_start|>" + "<|audio_pad|>" * n_audio
                + "<|audio_end|><|im_end|>\n<|im_start|>assistant\n")
        if language:
            text += f"language {language}{ASR_TEXT_TAG}"
        return text

    def generate(self, audio: np.ndarray, context: str, language: str | None,
                 prefix: str, max_new_tokens: int) -> str:
        import mlx.core as mx
        from mlx_audio.lm.generate import generate_step

        features, mask, n_audio = self.model._preprocess_audio(audio)
        audio_embeds = self.model.get_audio_features(features, mask)
        ids = self.tokenizer.encode(self.prompt(context, language, n_audio) + prefix,
                                    add_special_tokens=False)
        ids_mx = mx.array(ids)
        embeds = self.model.model.embed_tokens(ids_mx[None])[0]
        # The audio pads are one contiguous run, so splice the encoder output in
        # with one concatenate (mlx-audio's own merge loops per token).
        start = ids.index(self.audio_token_id)
        count = min(n_audio, audio_embeds.shape[0])
        embeds = mx.concatenate([embeds[:start],
                                 audio_embeds[:count].astype(embeds.dtype),
                                 embeds[start + count:]])
        out: list[int] = []
        for token, _ in generate_step(prompt=ids_mx, input_embeddings=embeds,
                                      model=self.model, max_tokens=max_new_tokens):
            token = int(token)
            if token in self.eos:
                break
            out.append(token)
        text = self.decode(out)
        for special in ("<|im_end|>", "<|endoftext|>"):
            text = text.replace(special, "")
        return text


def resolve_model_path(repo: str = MODEL_REPO, revision: str | None = MODEL_REVISION,
                       local_only: bool = False) -> str:
    """Local directory of the weights, downloading them unless `local_only`."""
    if os.path.isdir(repo):
        return repo
    from huggingface_hub import snapshot_download

    kwargs = {"local_files_only": local_only}
    if revision:
        kwargs["revision"] = revision
    return snapshot_download(repo, **kwargs)
