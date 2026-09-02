#!/usr/bin/env python3
"""Unit tests for asr_server.

Lives outside Scripts/ because that whole directory is a resources build phase,
so anything in it ships inside ClassNote.app.

The recogniser is faked: loading nemotron pulls ~650 MB of weights, so the real
model is only exercised by the end-to-end harness. What is covered here is the
model-free logic -- language mapping, cut placement, and the segment bookkeeping
that turns the recogniser's growing token list into partial/final events.

Run: python3 -m unittest discover -s Tests/PythonTests
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Scripts"))

import numpy as np

from asr_server import (
    BYTES_PER_MS,
    DEFAULT_CHUNK_MS,
    MIN_SENTENCE_CHARS,
    PAUSE_CLOSE_MS,
    SOFT_CUT_MS,
    TOKEN_TAIL_MS,
    SENT_MARK_KINDS,
    Transcriber,
    apply_marks,
    content_ends,
    cut_from_marks,
    ends_sentence,
    find_cut,
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
    def __init__(self):
        self.options = {}
        self.samples = 0
        self.finished = False

    def set_option(self, key, value):
        self.options[key] = value

    def accept_waveform(self, rate, samples):
        self.samples += len(samples)

    def input_finished(self):
        self.finished = True


class _FakeRecognizer:
    """The hypothesis only ever grows: tests append (token, onset_sec) pairs
    to `tokens` between feeds, mimicking greedy transducer output."""

    def __init__(self):
        self.tokens: list[tuple[str, float]] = []

    def create_stream(self):
        return _FakeStream()

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
        self.assertEqual(events[2]["text"], "Next")
        self.assertEqual(events[2]["segmentId"], 1)
        self.assertEqual(events[2]["startMs"], 110)

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


if __name__ == "__main__":
    unittest.main()
