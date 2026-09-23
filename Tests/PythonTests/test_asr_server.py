#!/usr/bin/env python3
"""Unit tests for asr_server.

Lives outside Scripts/ because that whole directory is a resources build phase,
so anything in it ships inside ClassNote.app.

The recogniser is faked: loading nemotron pulls ~650 MB of weights, so the real
model is only exercised by the end-to-end harness. What is covered here is the
model-free logic -- language mapping, cut placement, the segment bookkeeping
that turns the recogniser's growing token list into partial/final events, and
the process plumbing around them: the handshake channel, the parent watchdog and
a file import's cancellation.

Run: python3 -m unittest discover -s Tests/PythonTests
"""
import asyncio
import contextlib
import io
import json
import os
import sys
import tempfile
import time
import unittest
import unittest.mock as mock
import wave

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Scripts"))

import numpy as np
import websockets

import asr_server
from asr_server import (
    BYTES_PER_MS,
    DEFAULT_CHUNK_MS,
    MIN_SENTENCE_CHARS,
    PAUSE_CLOSE_MS,
    SAMPLE_RATE,
    SOFT_CUT_MS,
    TOKEN_TAIL_MS,
    SENT_MARK_KINDS,
    Transcriber,
    apply_marks,
    content_ends,
    cut_from_marks,
    ends_sentence,
    find_cut,
    find_cut_kind,
    parse_chunk_ms,
    pcm_to_float,
    punctuator_applies,
    resolve_language,
    strip_marks,
    text_width,
    tokens_to_text,
)


class PcmToFloatTests(unittest.TestCase):
    def test_converts_int16_to_unit_range(self):
        pcm = np.array([0, 32767, -32768], dtype="<i2").tobytes()
        out = pcm_to_float(pcm)
        self.assertAlmostEqual(out[0], 0.0)
        self.assertAlmostEqual(out[1], 32767 / 32768, places=5)
        self.assertAlmostEqual(out[2], -1.0)

    def test_empty_input_yields_empty_array(self):
        self.assertEqual(pcm_to_float(b"").size, 0)


class ParseChunkTests(unittest.TestCase):
    def test_accepts_an_exported_size(self):
        self.assertEqual(parse_chunk_ms("560"), 560)
        self.assertEqual(parse_chunk_ms(80), 80)

    def test_falls_back_on_garbage(self):
        # A bad value must not take the sidecar down.
        self.assertEqual(parse_chunk_ms("nonsense"), DEFAULT_CHUNK_MS)
        self.assertEqual(parse_chunk_ms("200"), DEFAULT_CHUNK_MS)
        self.assertEqual(parse_chunk_ms(None), DEFAULT_CHUNK_MS)


class ResolveLanguageTests(unittest.TestCase):
    """The app sends its own codes; nemotron's prompt dictionary has no bare
    "zh" or "ja", so these have to be normalised or every decode call would
    log a warning and silently fall back to auto."""

    def test_auto_and_empty_mean_auto(self):
        self.assertIsNone(resolve_language(None))
        self.assertIsNone(resolve_language(""))
        self.assertIsNone(resolve_language("auto"))

    def test_bare_codes_the_model_knows_pass_through(self):
        self.assertEqual(resolve_language("en"), "en")
        self.assertEqual(resolve_language("de"), "de")

    def test_chinese_variants_map_to_region_codes(self):
        self.assertEqual(resolve_language("zh"), "zh-CN")
        self.assertEqual(resolve_language("zh-Hans"), "zh-CN")
        self.assertEqual(resolve_language("zh-CN"), "zh-CN")
        self.assertEqual(resolve_language("zh-Hant"), "zh-TW")
        self.assertEqual(resolve_language("zh-TW"), "zh-TW")

    def test_bare_code_without_entry_uses_a_regional_one(self):
        self.assertEqual(resolve_language("ja"), "ja-JP")
        self.assertEqual(resolve_language("vi"), "vi-VN")
        self.assertEqual(resolve_language("th"), "th-TH")

    def test_unknown_code_is_auto(self):
        self.assertIsNone(resolve_language("xx"))
        self.assertIsNone(resolve_language("tlh-QO"))


class EndsSentenceTests(unittest.TestCase):
    def test_finished_sentences(self):
        self.assertTrue(ends_sentence("This is a complete thought."))
        self.assertTrue(ends_sentence("今天我们来讲细胞呼吸的过程。"))

    def test_mid_sentence(self):
        self.assertFalse(ends_sentence("This is only half of"))

    def test_fragment_is_too_short(self):
        self.assertLess(len("Yes."), MIN_SENTENCE_CHARS)
        self.assertFalse(ends_sentence("Yes."))
        self.assertFalse(ends_sentence("好的。"))

    def test_cjk_counts_double_so_a_short_chinese_sentence_passes(self):
        # Ten characters, but a complete sentence; twelve Latin letters are not.
        self.assertGreaterEqual(text_width("他分为三个主要阶段。"), MIN_SENTENCE_CHARS)
        self.assertTrue(ends_sentence("他分为三个主要阶段。"))

    def test_decimal_and_abbreviation(self):
        self.assertFalse(ends_sentence("the value is about 3.5"))
        self.assertFalse(ends_sentence("we asked Dr."))


def words(text):
    """Splits into nemotron-style pieces: one token per word, leading space."""
    return [" " + w for w in text.split()]


class FindCutTests(unittest.TestCase):
    def test_keeps_an_unfinished_segment_open(self):
        self.assertIsNone(find_cut(words("this is only half of"), held_ms=1000))

    def test_cuts_after_a_sentence_end(self):
        toks = words("this is a complete thought.")
        self.assertEqual(find_cut(toks, 1000), len(toks))

    def test_cuts_after_punctuation_glued_to_the_next_word(self):
        # nemotron emits "gold." together with " The", so the mark is one
        # token back from the end when we see it.
        toks = words("fifty pieces of gold.") + [" The"]
        self.assertEqual(find_cut(toks, 1000), len(toks) - 1)

    def test_cuts_after_a_sentence_end_buried_in_a_token_burst(self):
        # One decode step can deliver a whole burst of tokens, so the period
        # may be many tokens back by the time we look.
        toks = words("fifty pieces of gold.") + words("It happens in three main")
        self.assertEqual(find_cut(toks, 1000), 4)

    def test_soft_cut_prefers_a_clause_mark(self):
        toks = words("first part of it, second part going on and on")
        cut = find_cut(toks, SOFT_CUT_MS)
        self.assertEqual(tokens_to_text(toks[:cut]), "first part of it,")

    def test_soft_cut_falls_back_to_a_word_boundary(self):
        toks = words("still going on and") + [" an", "d"]
        cut = find_cut(toks, SOFT_CUT_MS)
        # Never split inside "and": the cut lands before its first piece.
        self.assertEqual(tokens_to_text(toks[:cut]), "still going on and")

    def test_soft_cut_with_no_boundary_takes_everything(self):
        toks = ["今", "天", "我", "们", "来", "讲"]
        self.assertEqual(find_cut(toks, SOFT_CUT_MS), len(toks))

    def test_soft_cut_needs_the_time(self):
        self.assertIsNone(find_cut(words("still going on and on and on"), SOFT_CUT_MS - 1))

    def test_cut_kind_says_whether_the_sentence_ended(self):
        # A soft cut only breaks the line for length; the app translates it
        # together with its continuation, so it must not claim a sentence end.
        self.assertEqual(find_cut_kind(words("fifty pieces of gold."), 1000), (4, True))
        cut, sentence_end = find_cut_kind(words("first part of it, second part"), SOFT_CUT_MS)
        self.assertEqual(cut, 4)
        self.assertFalse(sentence_end)
        self.assertEqual(find_cut_kind(words("still going"), 1000), (None, False))


class PunctuationHelperTests(unittest.TestCase):
    def test_strip_marks_keeps_decimals_and_acronyms(self):
        self.assertEqual(strip_marks("gold. The value, is 3.5 in the U.S. now"),
                         "gold The value is 3.5 in the U.S now")

    def test_punctuator_only_for_chinese_and_english(self):
        self.assertTrue(punctuator_applies("today we talk about 细胞呼吸 and ATP"))
        self.assertFalse(punctuator_applies("私は学生です"))
        self.assertFalse(punctuator_applies("Привет мир"))

    def test_apply_marks_english_uses_ascii_marks_and_capitalizes(self):
        raw = "three years ago for oppenheimer uh we had a talk"
        marks = [(27, "。"), (29, "，"), (39, "。")]  # after "oppenheimer", "uh", the end
        self.assertEqual(apply_marks(raw, marks, drop_trailing=True),
                         "Three years ago for oppenheimer. Uh, we had a talk")
        self.assertEqual(apply_marks(raw, marks, drop_trailing=False),
                         "Three years ago for oppenheimer. Uh, we had a talk.")

    def test_apply_marks_chinese_keeps_fullwidth_marks(self):
        raw = "今天我们来讲细胞呼吸也就是能量的过程"
        marks = [(10, "，"), (18, "。")]
        self.assertEqual(apply_marks(raw, marks, drop_trailing=False), "今天我们来讲细胞呼吸，也就是能量的过程。")

    def test_apply_marks_preserves_spacing_between_scripts(self):
        # The punctuator's own output glues "讲cellular"; the transcript keeps
        # the ASR spacing and only gains the marks.
        raw = "今天讲 cellular respiration 也就是细胞呼吸"
        marks = _FakePunctuator({strip_marks(raw): "今天讲cellular respiration，也就是细胞呼吸。"}).marks(raw)
        self.assertEqual(apply_marks(raw, marks, False), "今天讲 cellular respiration，也就是细胞呼吸。")

    def test_apply_marks_removes_the_space_left_by_a_dropped_chinese_comma(self):
        raw = "第一个阶段是糖酵解, 发生在细胞质里"
        marks = _FakePunctuator({strip_marks(raw): "第一个阶段是糖酵解，发生在细胞质里。"}).marks(raw)
        self.assertEqual(apply_marks(raw, marks, False), "第一个阶段是糖酵解，发生在细胞质里。")

    def test_apply_marks_drops_the_asr_models_own_marks_but_not_decimals(self):
        raw = "what, about 3.5 percent. of it"
        marks = _FakePunctuator({strip_marks(raw): "what about 3 . 5 percent？of it。"}).marks(raw)
        self.assertEqual(apply_marks(raw, marks, True), "What about 3.5 percent? Of it")

    def test_cut_from_marks_lands_on_a_token_boundary_and_skips_the_artifact(self):
        toks = words("fifty pieces of gold the tribal chief")
        ends = content_ends(toks)
        # A sentence end after "gold" (content 17) and the artifact at the end.
        marks = [(17, "。"), (ends[-1], "。")]
        self.assertEqual(cut_from_marks(toks, marks, SENT_MARK_KINDS), 4)

    def test_cut_from_marks_ignores_a_mark_inside_a_token(self):
        toks = words("fifty pieces of gold")
        self.assertIsNone(cut_from_marks(toks, [(3, "。")], SENT_MARK_KINDS))

    def test_cut_from_marks_respects_minimum_sentence_length(self):
        toks = words("yes the tribal chief then called")
        self.assertIsNone(cut_from_marks(toks, [(3, "。")], SENT_MARK_KINDS))


# ---------------------------------------------------------------------------
# Transcriber against a scripted recogniser
# ---------------------------------------------------------------------------


class _Result:
    def __init__(self, tokens, timestamps):
        self.tokens = list(tokens)
        self.timestamps = list(timestamps)
        self.start_time = 0.0
        self.text = tokens_to_text(tokens)


class _FakeStream:
    def __init__(self, owner=None):
        self.owner = owner
        self.options = {}
        self.samples = 0
        self.finished = False

    def set_option(self, key, value):
        self.options[key] = value

    def accept_waveform(self, rate, samples):
        self.samples += len(samples)
        if self.owner is not None:
            self.owner.feeds += 1

    def input_finished(self):
        self.finished = True


class _FakeRecognizer:
    """The hypothesis only ever grows: tests append (token, onset_sec) pairs
    to `tokens` between feeds, mimicking greedy transducer output."""

    def __init__(self):
        self.tokens: list[tuple[str, float]] = []
        self.feeds = 0          # slices accepted, for the file-import tests

    def create_stream(self):
        return _FakeStream(self)

    def is_ready(self, stream):
        return False

    def decode_stream(self, stream):
        pass

    def get_result_all(self, stream):
        return _Result([t for t, _ in self.tokens], [ts for _, ts in self.tokens])


class _FakeEngine:
    def __init__(self, recognizer, punctuator=None):
        self.recognizer = recognizer
        self.punctuator = punctuator


class _FakePunctuator:
    """Places marks by content position, the way the real one reports them:
    tests give it the punctuated form of the text it will be asked about."""

    def __init__(self, punctuated_by_raw):
        self.table = punctuated_by_raw
        self.calls = 0

    def marks(self, raw):
        self.calls += 1
        out = self.table.get(strip_marks(raw))
        if out is None:
            return []
        marks, k = [], 0
        for ch in out:
            if ch in "。！？，、；：,;:!?.":
                marks.append((k, ch))
            elif not ch.isspace():
                k += 1
        return marks


class TranscriberTests(unittest.TestCase):
    def setUp(self):
        self.rec = _FakeRecognizer()

    def make(self, language=None):
        return Transcriber(_FakeEngine(self.rec), language)

    def feed(self, t, ms=100, new=()):
        """Adds `new` (token, onset_sec) pairs then feeds `ms` of audio."""
        self.rec.tokens += list(new)
        return t.feed(bytes(ms * BYTES_PER_MS))

    def test_language_is_pinned_on_the_stream(self):
        t = self.make("zh-Hans")
        self.assertEqual(t.stream.options["language"], "zh-CN")

    def test_auto_leaves_the_option_unset(self):
        t = self.make("auto")
        self.assertNotIn("language", t.stream.options)

    def test_partials_only_when_text_changes(self):
        t = self.make()
        kinds = []
        kinds += [e["type"] for e in self.feed(t)]
        kinds += [e["type"] for e in self.feed(t, new=[(" hello", 0.15)])]
        kinds += [e["type"] for e in self.feed(t)]
        kinds += [e["type"] for e in self.feed(t, new=[(" world", 0.32)])]
        self.assertEqual(kinds, ["partial", "partial"])

    def test_start_ms_comes_from_the_first_token_onset(self):
        t = self.make()
        ev = self.feed(t, new=[(" hi", 0.05), (" there", 0.08)])[0]
        self.assertEqual(ev["startMs"], 50)
        self.assertEqual(ev["endMs"], 100)

    def test_pause_closes_the_segment(self):
        t = self.make()
        self.feed(t, new=[(" hello", 0.02), (" world", 0.06)])
        events = []
        elapsed = 100
        while elapsed < PAUSE_CLOSE_MS + 200:
            events += self.feed(t)
            elapsed += 100
        self.assertEqual([e["type"] for e in events], ["final"])
        self.assertEqual(events[0]["text"], "Hello world")
        self.assertEqual(events[0]["segmentId"], 0)
        self.assertEqual(events[0]["startMs"], 20)
        # Ends shortly after its last token, not at "now".
        self.assertEqual(events[0]["endMs"], 60 + TOKEN_TAIL_MS)

    def test_voice_energy_holds_the_segment_open_through_a_token_gap(self):
        # The model sometimes withholds a word for close to a second while the
        # speaker is still talking; audible speech must veto the pause rule.
        t = self.make()
        self.feed(t, new=[(" hello", 0.02)])
        loud = (np.full(100 * 16, 8000, dtype="<i2")).tobytes()  # 100 ms, rms ~0.24
        events = []
        for _ in range(PAUSE_CLOSE_MS // 100 + 3):
            events += t.feed(loud)
        self.assertEqual(events, [])
        # Once it goes quiet, the pause closes the line.
        for _ in range(PAUSE_CLOSE_MS // 100 + 1):
            events += self.feed(t)
        self.assertEqual([e["type"] for e in events], ["final"])

    def test_sentence_punctuation_cuts_and_the_rest_starts_the_next_segment(self):
        t = self.make()
        self.feed(t, new=[(" This", 0.01), (" is", 0.02), (" a", 0.03),
                          (" whole", 0.04), (" sentence", 0.05)])
        events = self.feed(t, new=[(".", 0.09), (" Next", 0.11)])
        self.assertEqual([e["type"] for e in events], ["partial", "final", "partial"])
        self.assertEqual(events[1]["text"], "This is a whole sentence.")
        self.assertEqual(events[1]["segmentId"], 0)
        self.assertTrue(events[1]["sentenceEnd"])
        self.assertEqual(events[2]["text"], "Next")
        self.assertEqual(events[2]["segmentId"], 1)
        self.assertEqual(events[2]["startMs"], 110)

    def test_a_soft_cut_line_says_its_sentence_goes_on(self):
        t = self.make()
        # Continuous speech, a word every 400 ms and one clause mark, until the
        # line has been held past the soft cut.
        words_in = ["first", "part", "of", "it,", "then", "more", "and", "more",
                    "words", "keep", "coming", "without", "a", "stop", "at", "all"]
        events = []
        for i, word in enumerate(words_in):
            events += self.feed(t, ms=400, new=[(" " + word, i * 0.4)])
        finals = [e for e in events if e["type"] == "final"]
        self.assertTrue(finals)
        self.assertEqual(finals[0]["text"], "First part of it,")
        self.assertFalse(finals[0]["sentenceEnd"])

    def test_leading_punctuation_after_a_pause_is_dropped(self):
        t = self.make()
        self.feed(t, new=[(" pieces", 0.01), (" of", 0.03), (" gold", 0.05)])
        for _ in range(PAUSE_CLOSE_MS // 100 + 1):
            self.feed(t)
        # The period for "gold" only arrives with the next sentence.
        # Onsets lie inside the audio fed so far (0.9 s by now).
        events = self.feed(t, new=[(".", 0.82), (" ", 0.83), (" The", 0.85)])
        self.assertEqual([e["type"] for e in events], ["partial"])
        self.assertEqual(events[0]["text"], "The")
        self.assertEqual(events[0]["startMs"], 850)

    def test_committed_text_is_never_re_emitted(self):
        t = self.make()
        self.feed(t, new=[(" one", 0.01), (" two", 0.02), (" three", 0.03), (" four", 0.04),
                          (" five", 0.05), (" six.", 0.06)])
        events = self.feed(t, new=[(" seven", 0.12)])
        texts = [e["text"] for e in events]
        self.assertNotIn("one", texts[-1])
        self.assertEqual(texts[-1], "Seven")

    def test_finish_flushes_the_open_segment(self):
        t = self.make()
        self.feed(t, new=[(" last", 0.01), (" words", 0.03)])
        self.rec.tokens.append((" here", 0.06))
        events = t.finish()
        self.assertEqual([e["type"] for e in events], ["partial", "final"])
        self.assertEqual(events[-1]["text"], "Last words here")
        self.assertTrue(t.stream.finished)
        self.assertTrue(events[-1]["sentenceEnd"])

    def test_finish_with_nothing_open_emits_nothing(self):
        t = self.make()
        self.assertEqual(t.finish(), [])

    def test_punctuator_drives_the_cut_and_the_line_text(self):
        # The ASR model emits no marks at all; the punctuator's sentence end
        # after "years" both closes the line and punctuates it.
        punct = _FakePunctuator({
            "we sat here three years ago for oppenheimer":
                "we sat here three years。ago for oppenheimer。",
        })
        t = Transcriber(_FakeEngine(self.rec, punct), None)
        toks = [(" we", 0.01), (" sat", 0.02), (" here", 0.03), (" three", 0.04),
                (" years", 0.05), (" ago", 0.06), (" for", 0.07), (" oppenheimer", 0.08)]
        events = self.feed(t, new=toks)
        kinds = [e["type"] for e in events]
        self.assertEqual(kinds, ["partial", "final", "partial"])
        self.assertEqual(events[1]["text"], "We sat here three years.")
        self.assertEqual(events[2]["text"], "Ago for oppenheimer")  # no artifact mark
        self.assertEqual(events[2]["startMs"], 60)

    def test_punctuator_is_skipped_for_other_languages(self):
        punct = _FakePunctuator({})
        t = Transcriber(_FakeEngine(self.rec, punct), "ja")
        self.assertIsNone(t.punctuator)
        t.set_language("en")
        self.assertIs(t.punctuator, punct)

    def test_pause_closed_line_keeps_the_trailing_mark(self):
        punct = _FakePunctuator({"how are you doing": "how are you doing？"})
        t = Transcriber(_FakeEngine(self.rec, punct), "en")
        self.feed(t, new=[(" how", 0.01), (" are", 0.02), (" you", 0.03), (" doing", 0.04)])
        events = []
        for _ in range(PAUSE_CLOSE_MS // 100 + 1):
            events += self.feed(t)
        self.assertEqual([e["type"] for e in events], ["final"])
        self.assertEqual(events[0]["text"], "How are you doing?")

    def test_odd_byte_frame_is_realigned(self):
        t = self.make()
        t.feed(bytes(BYTES_PER_MS * 10 + 1))
        self.assertEqual(t.stream_ms, 10)

    def test_clock_does_not_drift_on_fractional_mic_frames(self):
        t = self.make()
        mic = _MicClock()
        with mock.patch.object(asr_server, "log"):      # ten minutes of RTF stats
            while mic.fed < 10 * 60 * SAMPLE_RATE:
                t.feed(mic.next_frame())
        # Summing per-frame floors lost ~0.33 ms per 85 ms buffer: 2.4 s here.
        self.assertLessEqual(abs(t.stream_ms - mic.true_ms), 1)

    def test_pause_still_closes_a_line_after_ten_minutes_of_fractional_frames(self):
        # The pause rule compares this clock against sherpa's own token
        # timestamps, which are sample-accurate. A clock that drifts behind them
        # makes every silence look shorter than it was, until after twenty
        # minutes nothing can stay quiet long enough to close a line.
        t = self.make()
        mic = _MicClock()
        with mock.patch.object(asr_server, "log"):      # ten minutes of RTF stats
            while mic.fed < 10 * 60 * SAMPLE_RATE:
                t.feed(mic.next_frame())
        self.rec.tokens.append((" hello", mic.true_ms / 1000.0))
        t.feed(mic.next_frame())
        events = []
        quiet_until = mic.true_ms + PAUSE_CLOSE_MS + 200
        while mic.true_ms < quiet_until:
            events += t.feed(mic.next_frame())
        self.assertEqual([e["type"] for e in events], ["final"])
        self.assertEqual(events[0]["text"], "Hello")


class _MicClock:
    """Frames the way AVAudioEngine delivers them: a 4096-frame tap at 48 kHz is
    1365.33 samples at 16 kHz, so buffers alternate 1365/1366 samples and no
    frame is ever a whole number of milliseconds."""

    def __init__(self):
        self.exact = 0.0
        self.fed = 0

    def next_frame(self) -> bytes:
        self.exact += 4096 / 3.0
        want = int(self.exact) - self.fed
        self.fed += want
        return bytes(want * 2)

    @property
    def true_ms(self) -> float:
        return self.fed * 1000.0 / SAMPLE_RATE


# ---------------------------------------------------------------------------
# Handshake channel
# ---------------------------------------------------------------------------


class HandshakeChannelTests(unittest.TestCase):
    def test_stage_lines_survive_a_redirected_stdout(self):
        # Engine.load() redirects sys.stdout to stderr for the whole model load
        # so huggingface_hub's progress bars cannot corrupt the channel Swift
        # parses for READY -- which used to take the STAGE lines with it,
        # leaving the app with no progress and an unextendable deadline.
        real = io.StringIO()
        with mock.patch.object(asr_server, "_HANDSHAKE", real), \
                contextlib.redirect_stdout(io.StringIO()) as redirected:
            def emit_stage(key, step, total):
                asr_server.handshake(f"STAGE {step}/{total} {key}")

            emit_stage("download", 1, 4)
            print("a progress bar")
        self.assertEqual(real.getvalue(), "STAGE 1/4 download\n")
        self.assertEqual(redirected.getvalue(), "a progress bar\n")

    def test_a_slow_download_keeps_reporting_its_stage(self):
        # The one case the app cannot tell from a hang: a first run spends
        # minutes inside snapshot_download with nothing to say. Every STAGE line
        # extends the app's start-up deadline, so the stage in progress is
        # re-announced until the download returns.
        original_heartbeat = asr_server.stage_heartbeat
        real = io.StringIO()

        def slow_download(repo, revision, **kwargs):
            print("a tqdm progress bar")        # what huggingface_hub does
            time.sleep(0.12)
            return "/models/" + repo.replace("/", "--")

        with mock.patch.object(asr_server, "_HANDSHAKE", real), \
                mock.patch.object(asr_server, "stage_heartbeat",
                                  lambda repeat, interval=5.0: original_heartbeat(repeat, 0.02)), \
                mock.patch.object(asr_server.Engine, "_cached_snapshot",
                                  staticmethod(lambda *a, **kw: None)), \
                mock.patch.object(asr_server.Engine, "_download", staticmethod(slow_download)), \
                mock.patch.object(asr_server.Engine, "_build_recognizer",
                                  lambda self, model_dir: _FakeRecognizer()), \
                mock.patch.object(asr_server, "Punctuator", lambda model_dir: None), \
                contextlib.redirect_stderr(io.StringIO()) as stderr:
            engine = asr_server.Engine(
                chunk_ms=160,
                on_stage=lambda key, step, total: asr_server.handshake(
                    f"STAGE {step}/{total} {key}"))
            engine.load()

        lines = real.getvalue().splitlines()
        self.assertGreaterEqual(lines.count("STAGE 1/4 download"), 3)
        self.assertEqual(lines[-3:], ["STAGE 2/4 streaming", "STAGE 3/4 punct",
                                      "STAGE 4/4 warmup"])
        # Whatever the hub printed went to stderr, not onto the channel Swift
        # parses -- that is what the redirect inside Engine.load() is for.
        self.assertIn("a tqdm progress bar", stderr.getvalue())
        self.assertNotIn("tqdm", real.getvalue())

    def test_stage_heartbeat_repeats_until_the_block_ends(self):
        beats = []
        with asr_server.stage_heartbeat(lambda: beats.append(1), interval=0.01):
            time.sleep(0.1)
        self.assertGreaterEqual(len(beats), 2)
        settled = len(beats)
        time.sleep(0.05)
        self.assertEqual(len(beats), settled)


# ---------------------------------------------------------------------------
# Parent watchdog
# ---------------------------------------------------------------------------


class _Exited(BaseException):
    """Stands in for os._exit, which a test process cannot actually call. A
    BaseException so it is not swallowed by the code under test."""


class ParentWatchdogTests(unittest.IsolatedAsyncioTestCase):
    async def test_exits_even_when_the_log_write_fails(self):
        # The parent being gone is exactly what closes the read end of the
        # stderr pipe, so the watchdog's own log line is the operation most
        # likely to raise in the one situation it exists for.
        with mock.patch.object(asr_server, "log", side_effect=BrokenPipeError), \
                mock.patch.object(asr_server.os, "kill", side_effect=ProcessLookupError), \
                mock.patch.object(asr_server.os, "_exit", side_effect=_Exited):
            with self.assertRaises(_Exited):
                await asr_server._exit_when_parent_gone(1, interval=0)

    async def test_keeps_watching_while_the_parent_is_alive(self):
        seen = []

        def kill(pid, sig):
            seen.append(pid)
            if len(seen) >= 3:
                raise ProcessLookupError

        with mock.patch.object(asr_server, "log"), \
                mock.patch.object(asr_server.os, "kill", side_effect=kill), \
                mock.patch.object(asr_server.os, "_exit", side_effect=_Exited):
            with self.assertRaises(_Exited):
                await asr_server._exit_when_parent_gone(7, interval=0)
        self.assertEqual(seen, [7, 7, 7])

    async def test_a_broken_probe_stops_the_watchdog(self):
        # Anything other than "the pid is gone" must not turn into an exit, and
        # must not spin either.
        with mock.patch.object(asr_server.os, "kill", side_effect=OSError), \
                mock.patch.object(asr_server.os, "_exit", side_effect=_Exited):
            await asr_server._exit_when_parent_gone(1, interval=0)


# ---------------------------------------------------------------------------
# File import: cancellation, disconnects, error codes
# ---------------------------------------------------------------------------


def _write_silence_wav(seconds: float) -> str:
    fd, path = tempfile.mkstemp(suffix=".wav")
    os.close(fd)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(bytes(int(seconds * SAMPLE_RATE) * 2))
    return path


class _FakeWS:
    """Just enough of a websockets server connection for Session and
    handle_connection: text frames out, a scripted script of frames in, and a
    close_code that flips when the client goes away."""

    def __init__(self, incoming=()):
        self.sent: list[dict] = []
        self.close_code = None
        self._incoming = list(incoming)

    async def send(self, message):
        if self.close_code is not None:
            raise websockets.ConnectionClosedOK(None, None)
        self.sent.append(json.loads(message))

    def __aiter__(self):
        return self._receive()

    async def _receive(self):
        for message in self._incoming:
            await asyncio.sleep(0)
            yield message
        self.close_code = 1000      # the client hung up

    def kinds(self) -> list[str]:
        return [ev["type"] for ev in self.sent]


class FileImportTests(unittest.IsolatedAsyncioTestCase):
    """Drives Session.transcribe_file against a fake socket and the scripted
    recogniser. The WAV is a minute of silence -- 300 slices of 200 ms -- so a
    job that ignored a cancel would be obvious."""

    SLICES = 300

    async def asyncSetUp(self):
        self.rec = _FakeRecognizer()
        self.ws = _FakeWS()
        self.session = asr_server.Session(self.ws, _FakeEngine(self.rec), None)
        self.path = _write_silence_wav(60)
        self.addCleanup(os.unlink, self.path)

    async def asyncTearDown(self):
        await self.session.close()

    def start_job(self, path=None):
        self.session.file_task = asyncio.create_task(
            self.session.transcribe_file(path or self.path))

    async def wait_for_slices(self, count: int, timeout: float = 5.0):
        deadline = time.monotonic() + timeout
        while self.rec.feeds < count:
            self.assertLess(time.monotonic(), deadline, "the file job never ran")
            await asyncio.sleep(0.005)

    async def test_cancel_stops_the_job_within_two_slices(self):
        self.start_job()
        await self.wait_for_slices(3)
        fed = self.rec.feeds
        await self.session.cancel_file()
        self.assertLessEqual(self.rec.feeds - fed, 2)
        self.assertLess(self.rec.feeds, self.SLICES)
        self.assertNotIn("eof", self.ws.kinds())

    async def test_a_closed_socket_stops_the_job_within_two_slices(self):
        self.start_job()
        await self.wait_for_slices(3)
        fed = self.rec.feeds
        self.ws.close_code = 1000
        await asyncio.wait_for(self.session.file_task, timeout=5.0)
        self.assertLessEqual(self.rec.feeds - fed, 2)
        self.assertLess(self.rec.feeds, self.SLICES)

    async def test_a_whole_file_ends_with_a_full_progress_frame_and_eof(self):
        path = _write_silence_wav(1)
        self.addCleanup(os.unlink, path)
        await self.session.transcribe_file(path)
        total = SAMPLE_RATE * 2
        # The first progress frame already carries the real size: it comes from
        # the WAV header, not from a PCM buffer read into memory.
        self.assertEqual(self.ws.sent[0], {"type": "progress", "completed": 0,
                                           "total": total})
        self.assertEqual(self.ws.sent[-2], {"type": "progress", "completed": total,
                                            "total": total})
        self.assertEqual(self.ws.sent[-1], {"type": "eof"})

    async def test_a_missing_file_reports_a_code(self):
        await self.session.transcribe_file("/nowhere/missing.wav")
        self.assertEqual(self.ws.sent[-1]["type"], "error")
        self.assertEqual(self.ws.sent[-1]["code"], "file.missing")
        self.assertIn("missing.wav", self.ws.sent[-1]["message"])

    async def test_a_file_that_is_not_a_16k_mono_wav_reports_a_code(self):
        fd, path = tempfile.mkstemp(suffix=".wav")
        os.close(fd)
        self.addCleanup(os.unlink, path)
        with wave.open(path, "wb") as w:
            w.setnchannels(2)
            w.setsampwidth(2)
            w.setframerate(44100)
            w.writeframes(bytes(4000))
        await self.session.transcribe_file(path)
        self.assertEqual(self.ws.sent[-1]["code"], "file.unreadable")

    async def test_frames_that_arrive_after_eof_are_dropped(self):
        # finish() drops the transcriber; without the guard the next frame would
        # build a fresh one whose clock starts again at zero.
        await self.session.start()
        self.session.enqueue(bytes(320))
        await self.session.finish()
        self.session.enqueue(bytes(320))
        self.assertTrue(self.session._inbox.empty())


class ConnectionDispatchTests(unittest.IsolatedAsyncioTestCase):
    async def test_a_second_file_job_is_refused_and_the_first_is_cancelled(self):
        # The read loop keeps running while a file job does, which is what makes
        # both the refusal and the disconnect-driven cancel possible.
        rec = _FakeRecognizer()
        path = _write_silence_wav(60)
        self.addCleanup(os.unlink, path)
        ws = _FakeWS([json.dumps({"type": "file", "path": path}),
                      json.dumps({"type": "file", "path": path})])
        await asr_server.handle_connection(ws, _FakeEngine(rec), None)
        errors = [ev for ev in ws.sent if ev["type"] == "error"]
        self.assertEqual([ev["code"] for ev in errors], ["file.failed"])
        self.assertLess(rec.feeds, FileImportTests.SLICES)

    async def test_cancel_answers_with_eof(self):
        rec = _FakeRecognizer()
        path = _write_silence_wav(60)
        self.addCleanup(os.unlink, path)
        ws = _FakeWS([json.dumps({"type": "file", "path": path}),
                      json.dumps({"type": "cancel"})])
        await asr_server.handle_connection(ws, _FakeEngine(rec), None)
        self.assertEqual(ws.kinds()[-1], "eof")
        self.assertLess(rec.feeds, FileImportTests.SLICES)


if __name__ == "__main__":
    unittest.main()
