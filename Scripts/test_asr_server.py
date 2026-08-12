#!/usr/bin/env python3
"""Unit tests for asr_server helpers. Run: python3 -m unittest Scripts.test_asr_server"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from asr_server import _is_cjk, _is_silent, _join_partial


class JoinPartialTests(unittest.TestCase):
    """The streaming model emits each chunk without leading whitespace, so
    naive concatenation fused English words ("the" + "cell" -> "thecell")."""

    def test_inserts_space_between_latin_words(self):
        self.assertEqual(_join_partial("the", "cell"), "the cell")
        self.assertEqual(_join_partial("mitochondria is", "the"), "mitochondria is the")

    def test_never_spaces_cjk(self):
        self.assertEqual(_join_partial("试错的", "过程"), "试错的过程")
        self.assertEqual(_join_partial("过程很简单", "，而今"), "过程很简单，而今")

    def test_no_space_at_script_boundary(self):
        self.assertEqual(_join_partial("cell", "的"), "cell的")
        self.assertEqual(_join_partial("的", "cell"), "的cell")

    def test_punctuation_stays_attached(self):
        self.assertEqual(_join_partial("the", "."), "the.")
        self.assertEqual(_join_partial("word", ","), "word,")

    def test_hyphen_and_apostrophe_bind_forward(self):
        self.assertEqual(_join_partial("multi-", "word"), "multi-word")
        self.assertEqual(_join_partial("it", "'s"), "it's")

    def test_existing_whitespace_is_not_doubled(self):
        self.assertEqual(_join_partial("the ", "cell"), "the cell")
        self.assertEqual(_join_partial("the", " cell"), "the cell")

    def test_first_chunk_is_left_stripped(self):
        self.assertEqual(_join_partial("", "  the"), "the")

    def test_empty_addition_is_a_noop(self):
        self.assertEqual(_join_partial("the", ""), "the")


class CJKDetectionTests(unittest.TestCase):
    def test_detects_scripts_that_need_no_spacing(self):
        for ch in "试错的过程，。「」ひらカタ한글":
            self.assertTrue(_is_cjk(ch), ch)

    def test_latin_is_not_cjk(self):
        for ch in "abcXYZ019 .,":
            self.assertFalse(_is_cjk(ch), ch)


class SilenceTests(unittest.TestCase):
    def test_digital_silence_is_silent(self):
        self.assertTrue(_is_silent(b"\x00" * 3200))

    def test_empty_buffer_is_silent(self):
        self.assertTrue(_is_silent(b""))

    def test_loud_tone_is_not_silent(self):
        import struct
        loud = b"".join(struct.pack("<h", 12000 if i % 2 else -12000) for i in range(1600))
        self.assertFalse(_is_silent(loud))


if __name__ == "__main__":
    unittest.main()
