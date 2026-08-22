#!/usr/bin/env python3
"""Unit tests for asr_server helpers.

Lives outside Scripts/ because that whole directory is a resources build phase,
so anything in it ships inside ClassNote.app.

Only model-free logic is covered here: loading nemotron/Qwen3-ASR pulls GBs of
weights, so the streaming and offline passes are exercised by the end-to-end
harness instead, not by unit tests.

Run: python3 -m unittest discover -s Tests/PythonTests
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Scripts"))

import numpy as np

from asr_server import (
    DEFAULT_ATT_CONTEXT,
    MIN_SENTENCE_CHARS,
    Session,
    _is_cjk,
    _parse_att_context,
    pcm_to_float,
)


class IsCjkTests(unittest.TestCase):
    def test_detects_scripts_that_need_no_spacing(self):
        self.assertTrue(_is_cjk("过"))
        self.assertTrue(_is_cjk("，"))
        self.assertTrue(_is_cjk("。"))

    def test_latin_is_not_cjk(self):
        self.assertFalse(_is_cjk("a"))
        self.assertFalse(_is_cjk(" "))
        self.assertFalse(_is_cjk("."))


class PcmToFloatTests(unittest.TestCase):
    def test_converts_int16_to_unit_range(self):
        pcm = np.array([0, 32767, -32768], dtype="<i2").tobytes()
        out = pcm_to_float(pcm)
        self.assertAlmostEqual(out[0], 0.0)
        self.assertAlmostEqual(out[1], 32767 / 32768, places=5)
        self.assertAlmostEqual(out[2], -1.0)

    def test_empty_input_yields_empty_array(self):
        self.assertEqual(pcm_to_float(b"").size, 0)


class ParseAttContextTests(unittest.TestCase):
    def test_parses_a_pair(self):
        self.assertEqual(_parse_att_context("56,3"), [56, 3])

    def test_falls_back_on_garbage(self):
        # A bad value must not take the sidecar down; [56,13] is both the most
        # accurate and the fastest setting, so it is the safe default.
        self.assertEqual(_parse_att_context("nonsense"), list(DEFAULT_ATT_CONTEXT))
        self.assertEqual(_parse_att_context("56"), list(DEFAULT_ATT_CONTEXT))


class _StubSession(Session):
    """Session with the socket and models stubbed out.

    ``_should_cut_on_sentence`` reads only ``partial_text`` and ``utt_buf``, so it
    can be exercised without loading any weights.
    """

    def __init__(self, partial_text: str, held_ms: int):
        self.partial_text = partial_text
        self.utt_buf = bytearray(held_ms * 32)  # 32 bytes per ms of Int16 @16k


class SentenceCutTests(unittest.TestCase):
    def cut(self, text: str, held_ms: int = 1000) -> bool:
        return _StubSession(text, held_ms)._should_cut_on_sentence()

    def test_cuts_on_a_finished_sentence(self):
        self.assertTrue(self.cut("This is a complete thought."))
        self.assertTrue(self.cut("今天我们来讲细胞呼吸的过程。"))

    def test_does_not_cut_mid_sentence(self):
        self.assertFalse(self.cut("This is only half of"))

    def test_does_not_cut_on_a_fragment(self):
        # Too short to read as its own line even though it ends in a period.
        self.assertLess(len("Yes."), MIN_SENTENCE_CHARS)
        self.assertFalse(self.cut("Yes."))

    def test_does_not_split_a_decimal(self):
        self.assertFalse(self.cut("the value is about 3.5"))

    def test_does_not_split_an_abbreviation(self):
        self.assertFalse(self.cut("we asked Dr."))

    def test_soft_cut_fires_without_punctuation(self):
        # A speaker who never pauses would otherwise produce one wall of text
        # until the 20s force-cut.
        self.assertTrue(self.cut("still going on and on and on", held_ms=6_000))

    def test_soft_cut_needs_some_text(self):
        self.assertFalse(self.cut("", held_ms=6_000))


if __name__ == "__main__":
    unittest.main()
