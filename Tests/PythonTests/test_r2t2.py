#!/usr/bin/env python3
"""Unit tests for the Confucius4-R2T2 streaming port (r2t2_engine.py) and the
line segmentation asr_server.py builds on it.

Model-free: a scripted model reveals a known transcript as audio arrives, one
character per token, the way a greedy decoder conditioned on a forced prefix
would. What is covered is the algorithm around the model -- the append-only
commit, the held-back token, the rolling window and the line events.

Run: python3 -m unittest discover -s Tests/PythonTests
"""
import json
import os
import re
import sys
import unittest

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Scripts"))

import asr_server  # noqa: E402
import r2t2_engine  # noqa: E402
from r2t2_engine import R2T2Stream, SAMPLE_RATE  # noqa: E402


def tokens(text):
    """Word-level tokens with their leading space, like a BPE vocabulary."""
    return re.findall(r"\s*\S+|\s+", text)


class ScriptedModel:
    """Knows the transcript and when each character of it was spoken. A decode
    over `audio` returns what follows `prefix` among the characters spoken
    within that audio, `max_new_tokens` word tokens at most."""

    def __init__(self, text, chars_per_second=10.0, language=None):
        self.text = text
        self.cps = chars_per_second
        self.language = language      # what auto-detect "hears"
        self.offset_s = 0.0           # audio dropped from the window so far
        self.calls = []

    def spoken(self, audio_seconds):
        return self.text[: int(audio_seconds * self.cps)]

    def generate(self, audio, context, language, prefix, max_new_tokens):
        self.calls.append((len(audio), context, language, prefix, max_new_tokens))
        header = ""
        if language is None and self.language:
            header = f"language {self.language}<asr_text>"
        heard = header + self.spoken(self.total_s)
        if not heard.startswith(prefix):
            return ""
        return "".join(tokens(heard[len(prefix):])[:max_new_tokens])

    def encode(self, text):
        return tokens(text)

    def decode(self, ids):
        return "".join(ids)


class WindowModel:
    """Hears only the window it is given, which ScriptedModel does not: word i
    ("w<i>", one token) is spoken at times[i] seconds, and a decode returns the
    words after the last committed one that lie inside the stream's current
    window, `max_new_tokens` at most. A word whose audio left the window before
    it was committed is gone for good, as it is for the real model."""

    def __init__(self, times):
        self.times = list(times)
        self.stream = None            # the R2T2Stream whose window this is
        self.calls = []               # max_new_tokens of each decode

    def generate(self, audio, context, language, prefix, max_new_tokens):
        self.calls.append(max_new_tokens)
        start = self.stream.window_start / SAMPLE_RATE
        end = start + len(audio) / SAMPLE_RATE
        said = prefix.split()
        last = int(said[-1][1:]) if said else -1
        heard = [f" w{i}" for i, t in enumerate(self.times) if i > last and start <= t < end]
        return "".join(heard[:max_new_tokens])

    def encode(self, text):
        return tokens(text)

    def decode(self, ids):
        return "".join(ids)


def speech(seconds, words_per_second, start=0.0):
    """Word times for continuous speech."""
    return [start + i / words_per_second for i in range(int(seconds * words_per_second))]


def transcript(events):
    return " ".join(e["text"] for e in events if e["type"] == "final").lower().split()


def samples(seconds, level=0.1):
    return np.full(int(seconds * SAMPLE_RATE), level, np.float32)


class StreamTests(unittest.TestCase):
    def feed(self, stream, model, seconds, step=0.16):
        out = []
        t = 0.0
        while t < seconds - 1e-9:
            model.total_s += step
            out += stream.accept(samples(step))
            t += step
        return out

    def make(self, text, **kw):
        model = ScriptedModel(text, **kw)
        model.total_s = 0.0
        stream = R2T2Stream(model=model, language="English")
        return model, stream

    def test_commits_only_append_and_hold_back_the_last_token(self):
        model, stream = self.make("hello there world")
        pieces = self.feed(stream, model, 1.0)
        committed = "".join(p for p, _ in pieces)
        # Everything committed is a prefix of the truth, one token short of
        # what the audio so far supports.
        self.assertTrue("hello there world".startswith(committed))
        self.assertLess(len(committed), len(model.spoken(model.total_s)))

    def test_flush_commits_the_held_back_token(self):
        model, stream = self.make("hi you")
        self.feed(stream, model, 1.0)
        stream.flush()
        self.assertEqual(stream.committed, "hi you")

    def test_the_first_step_waits_for_a_look_ahead_chunk(self):
        model, stream = self.make("abc")
        model.total_s = 0.16
        self.assertEqual(stream.accept(samples(0.16)), [])
        self.assertEqual(model.calls, [])
        model.total_s = 0.32
        stream.accept(samples(0.16))
        self.assertEqual(len(model.calls), 1)

    def test_the_committed_text_is_fed_back_as_the_prefix(self):
        model, stream = self.make("abcdefghij")
        self.feed(stream, model, 1.0)
        last_prefix = model.calls[-1][3]
        self.assertTrue(stream.committed.startswith(last_prefix))

    def test_audio_that_piles_up_is_decoded_in_one_step(self):
        model, stream = self.make("abcdefghij")
        model.total_s = 2.0
        stream.accept(samples(2.0))
        self.assertEqual(len(model.calls), 1)
        self.assertEqual(model.calls[0][0], 2 * SAMPLE_RATE)

    def test_the_window_drops_old_audio_and_its_text(self):
        model, stream = self.make("x" * 400, chars_per_second=10)
        self.feed(stream, model, 20.0, step=0.5)
        self.assertLessEqual(len(stream.audio), r2t2_engine.WINDOW_MAX_S * SAMPLE_RATE)
        self.assertGreater(stream.window_start, 0)
        self.assertTrue(all(p.end_sample > stream.window_start for p in stream.pieces))

    def test_auto_detect_learns_the_language_from_the_header(self):
        model = ScriptedModel("bonjour", language="French")
        model.total_s = 0.0
        stream = R2T2Stream(model=model, language=None)
        self.feed(stream, model, 1.0)
        self.assertEqual(stream.detected_language, "French")
        self.assertTrue(model.calls[-1][3].startswith("language French<asr_text>"))

    def test_silence_does_not_lock_auto_detect_onto_none(self):
        model = ScriptedModel("", language="None")
        model.total_s = 0.0
        stream = R2T2Stream(model=model, language=None)
        self.feed(stream, model, 1.0)
        self.assertIsNone(stream.detected_language)

    def test_a_reset_drops_the_audio_it_already_transcribed(self):
        model, stream = self.make("abcdefghij")
        self.feed(stream, model, 1.0)
        stream.reset_text()
        self.assertEqual(len(stream.audio), 0)
        self.assertEqual(stream.pieces, [])

    def test_the_token_budget_grows_while_nothing_is_stable(self):
        model, stream = self.make("")
        self.feed(stream, model, 1.0)
        self.assertEqual(stream.new_tokens, r2t2_engine.MAX_NEW_TOKENS)

    def test_a_decoder_loop_drops_the_prefix(self):
        self.assertTrue(r2t2_engine.is_hallucinating("ok. ok. ok. ok. ok. "))
        self.assertFalse(r2t2_engine.is_hallucinating("the cell membrane is permeable"))

    def test_the_budget_follows_the_audio_a_step_takes_in(self):
        # A 160 ms live step stays about as cheap as it always was; a 2 s
        # step may write out everything a fast speaker (~5 tokens/s) said in
        # it, plus the token it holds back.
        for step_s, low, high in ((0.16, 2, 3), (2.0, 2 * 5 + 1, r2t2_engine.FLUSH_NEW_TOKENS)):
            with self.subTest(step_s=step_s):
                model = WindowModel(speech(12, 20.0))    # always more to say
                stream = R2T2Stream(model=model, language="English",
                                    step_samples=int(step_s * SAMPLE_RATE))
                model.stream = stream
                for _ in range(5):
                    stream.accept(samples(step_s))
                # The first step also takes in its look-ahead chunk.
                for budget in model.calls[1:]:
                    self.assertGreaterEqual(budget, low)
                    self.assertLessEqual(budget, high)

    def test_a_backlog_longer_than_the_window_is_decoded_not_trimmed(self):
        # Twenty seconds at once: in one step, the trim would drop the first
        # twelve before a word of them was decoded.
        model = WindowModel(speech(20, 3.0))
        stream = R2T2Stream(model=model, language="English")
        model.stream = stream
        pieces = stream.accept(samples(20.0)) + stream.flush()
        said = " ".join(text for text, _ in pieces).split()
        self.assertEqual(said, [f"w{i}" for i in range(60)])
        self.assertEqual(len(model.calls), 11)    # ten 2 s steps and the flush


class ContinuousSpeechTests(unittest.TestCase):
    """A minute without a pause against a model that only hears its window.
    A step has to commit at least what was said during it: a decoder that
    falls behind never catches up without a pause, and the window trim then
    drops audio it never reached (2 s steps used to lose two words in three)."""

    def run_speech(self, transcriber, model, seconds, frame_ms):
        model.stream = transcriber.stream
        frame = np.full(frame_ms * SAMPLE_RATE // 1000, 3000, np.int16).tobytes()
        events = []
        for _ in range(seconds * 1000 // frame_ms):
            events += transcriber.feed(frame)
        return events + transcriber.finish()

    def test_a_file_import_keeps_every_word(self):
        for rate in (3.0, 5.0):
            with self.subTest(words_per_second=rate):
                engine = asr_server.R2T2Engine(chunk_ms=160)
                engine.model = WindowModel(speech(60, rate))
                t = engine.new_transcriber("en", file=True)
                # 200 ms slices, as Session.transcribe_file reads them.
                events = self.run_speech(t, engine.model, 60, 200)
                self.assertEqual(transcript(events), [f"w{i}" for i in range(int(60 * rate))])

    def test_the_1120_ms_setting_keeps_every_word(self):
        for rate in (3.0, 5.0):
            with self.subTest(words_per_second=rate):
                model = WindowModel(speech(60, rate))
                t = asr_server.R2T2Transcriber(model, "en", step_ms=1120)
                events = self.run_speech(t, model, 60, 100)
                self.assertEqual(transcript(events), [f"w{i}" for i in range(int(60 * rate))])


class _Socket:
    """What Session sends, as decoded JSON."""

    def __init__(self):
        self.sent = []
        self.close_code = None

    async def send(self, message):
        self.sent.append(json.loads(message))


class _WindowEngine:
    def __init__(self, model, step_ms=160):
        self.model = model
        self.step_ms = step_ms

    def new_transcriber(self, language, context="", file=False):
        t = asr_server.R2T2Transcriber(self.model, language, context, step_ms=self.step_ms)
        self.model.stream = t.stream
        return t


class BacklogTests(unittest.IsolatedAsyncioTestCase):
    """Frames that queue up while a step runs, as on a Mac too slow for one
    step per 160 ms. Here they are all queued before the worker first runs."""

    async def run_session(self, model, frames):
        ws = _Socket()
        session = asr_server.Session(ws, _WindowEngine(model), "en")
        await session.start()
        for pcm in frames:
            session.enqueue(pcm)
        await session.finish()
        await session.close()
        return ws.sent

    @staticmethod
    def frames(seconds, voiced=True):
        level = 3000 if voiced else 0
        return [np.full(100 * SAMPLE_RATE // 1000, level, np.int16).tobytes()] * round(seconds * 10)

    async def test_a_backlog_is_decoded_in_a_few_big_steps_before_eof(self):
        # Ten seconds behind. One step per frame or two (fifty here), each
        # re-encoding the window, is what kept a slow Mac behind until Stop
        # gave up on the rest; one call decodes it in 2 s steps.
        model = WindowModel(speech(10, 3.0))
        sent = await self.run_session(model, self.frames(10))
        self.assertEqual(transcript(sent), [f"w{i}" for i in range(30)])
        self.assertLessEqual(len(model.calls), 6)     # five 2 s steps and the flush
        self.assertEqual(sent[-1], {"type": "eof"})

    async def test_a_pause_inside_a_backlog_still_closes_its_line(self):
        # Voice is followed frame by frame even when the audio is decoded in
        # one go, so the pause flushes the first line where it happened.
        model = WindowModel(speech(2, 3.0) + speech(1.2, 3.0, start=3.2))
        frames = self.frames(2) + self.frames(1.2, voiced=False) + self.frames(1.2)
        sent = await self.run_session(model, frames)
        finals = [e for e in sent if e["type"] == "final"]
        self.assertEqual([f["text"] for f in finals], ["W0 w1 w2 w3 w4 w5", "W6 w7 w8"])
        self.assertTrue(finals[0]["sentenceEnd"])
        self.assertLess(finals[0]["endMs"], 3200)


class HelperTests(unittest.TestCase):
    def test_language_names(self):
        self.assertEqual(r2t2_engine.language_name("zh-Hans"), "Chinese")
        self.assertEqual(r2t2_engine.language_name("en"), "English")
        self.assertEqual(r2t2_engine.language_name("zh-HK"), "Cantonese")
        self.assertIsNone(r2t2_engine.language_name("auto"))
        self.assertIsNone(r2t2_engine.language_name(None))
        self.assertIsNone(r2t2_engine.language_name("tlh"))

    def test_punctuation_follows_the_script_before_it(self):
        self.assertEqual(r2t2_engine.normalize_punct("你好, world。"), "你好， world.")

    def test_split_output(self):
        self.assertEqual(r2t2_engine.split_output("abc|junk", "English"), ("English", "abc"))
        self.assertEqual(r2t2_engine.split_output("language Chinese<asr_text>你好", None),
                         ("Chinese", "你好"))
        self.assertEqual(r2t2_engine.split_output("langu", None), (None, None))

    def test_prompt_has_no_newline_after_the_context(self):
        prompt = r2t2_engine.R2T2Model.prompt("Linear Algebra", "English", 2)
        self.assertIn("<|im_start|>system\nLinear Algebra<|im_end|>\n", prompt)
        self.assertIn("<|audio_pad|><|audio_pad|><|audio_end|>", prompt)
        self.assertTrue(prompt.endswith("<|im_start|>assistant\nlanguage English<asr_text>"))


class LineTests(unittest.TestCase):
    """R2T2Transcriber: the same partial/final contract as nemotron's."""

    def make(self, text, cps=12.0):
        model = ScriptedModel(text, chars_per_second=cps)
        model.total_s = 0.0
        t = asr_server.R2T2Transcriber(model, "en", step_ms=160)
        return model, t

    def run_audio(self, model, t, seconds, voiced=True):
        events = []
        frame = 0.08
        n = int(round(seconds / frame))
        for _ in range(n):
            model.total_s += frame
            level = 3000 if voiced else 0
            pcm = np.full(int(frame * SAMPLE_RATE), level, np.int16).tobytes()
            events += t.feed(pcm)
        return events

    def finals(self, events):
        return [e for e in events if e["type"] == "final"]

    def test_a_sentence_mark_closes_a_line(self):
        model, t = self.make("This is the first sentence. And a second one")
        events = self.run_audio(model, t, 4.0)
        finals = self.finals(events)
        self.assertEqual(finals[0]["text"], "This is the first sentence.")
        self.assertTrue(finals[0]["sentenceEnd"])

    def test_a_pause_commits_the_held_back_word_and_closes_the_line(self):
        model, t = self.make("short line")
        events = self.run_audio(model, t, 1.2)
        # Silence: no more voice, and the model has nothing more to say.
        events += self.run_audio(model, t, 1.2, voiced=False)
        finals = self.finals(events)
        self.assertEqual([f["text"] for f in finals], ["Short line"])
        self.assertTrue(finals[0]["sentenceEnd"])

    def test_a_long_run_on_line_is_soft_cut_and_says_it_continues(self):
        text = "one two three, four five six seven eight nine ten eleven twelve thirteen fourteen"
        model, t = self.make(text, cps=10)
        events = self.run_audio(model, t, 8.5)
        finals = self.finals(events)
        self.assertTrue(finals)
        self.assertFalse(finals[0]["sentenceEnd"])
        self.assertEqual(finals[0]["text"], "One two three,")

    def test_finish_closes_whatever_is_open(self):
        model, t = self.make("the last words")
        self.run_audio(model, t, 1.5)
        finals = self.finals(t.finish())
        self.assertEqual(finals[-1]["text"], "The last words")

    def test_committed_text_is_never_rewritten(self):
        model, t = self.make("alpha beta gamma. delta epsilon zeta. eta theta")
        events = self.run_audio(model, t, 5.0)
        partials = [e["text"] for e in events if e["type"] == "partial"]
        for a, b in zip(partials, partials[1:]):
            # Within a line a partial only grows; a new line starts over.
            if not b.startswith(a):
                self.assertFalse(a.startswith(b))
        text = " ".join(f["text"] for f in self.finals(events))
        self.assertTrue("Alpha beta gamma. Delta epsilon zeta.".startswith(text) or
                        text.startswith("Alpha beta gamma."))

    def test_context_reaches_the_prompt(self):
        model, t = self.make("abc")
        t.set_context("Linear Algebra\neigenvalue")
        self.run_audio(model, t, 1.0)
        self.assertEqual(model.calls[-1][1], "Linear Algebra\neigenvalue")

    def test_file_imports_decode_in_long_steps(self):
        engine = asr_server.R2T2Engine(chunk_ms=160)
        engine.model = ScriptedModel("abc")
        live = engine.new_transcriber("en")
        file = engine.new_transcriber("en", file=True)
        self.assertEqual(live.stream.step_samples, 160 * SAMPLE_RATE // 1000)
        self.assertEqual(file.stream.step_samples, asr_server.R2T2_FILE_STEP_MS * SAMPLE_RATE // 1000)


if __name__ == "__main__":
    unittest.main()
