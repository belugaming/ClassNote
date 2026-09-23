#!/usr/bin/env python3
"""Unit tests for simt_server (Confucius4-T3PO).

Model-free: a scripted model answers each prompt, so what is covered is the
interleaved-history protocol, the READ/WRITE bookkeeping and the request loop.

Run: python3 -m unittest discover -s Tests/PythonTests
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Scripts"))

import simt_server  # noqa: E402
from simt_server import SimulSession  # noqa: E402


class ScriptedModel:
    def __init__(self, answers):
        self.answers = list(answers)
        self.calls = []

    def complete(self, prompt, force, latency):
        self.calls.append((prompt, force, latency))
        return self.answers.pop(0) if self.answers else ""


class ProtocolTests(unittest.TestCase):
    def test_a_wait_keeps_the_input_and_the_next_call_sends_all_of_it(self):
        model = ScriptedModel(["", "细胞膜是可渗透的"])
        s = SimulSession(model, "en2zh")
        self.assertEqual(s.feed("the cell membrane"), [{"type": "wait"}])
        events = s.feed("is permeable")
        self.assertEqual(events[0]["type"], "translation")
        self.assertEqual(events[0]["source"], "the cell membrane is permeable")
        self.assertIn("<CURRENT_INPUT>\nthe cell membrane is permeable", model.calls[1][0])
        self.assertEqual(s.buffer, [])

    def test_history_is_interleaved(self):
        model = ScriptedModel(["甲", "乙"])
        s = SimulSession(model, "en2zh")
        s.feed("one")
        s.feed("two")
        self.assertIn("<STREAMING_HISTORY>\none¦甲§\n", model.calls[1][0])

    def test_prompt_is_chatml_with_the_reference_system_prompt(self):
        model = ScriptedModel(["x"])
        SimulSession(model, "zh2en").feed("你好")
        prompt = model.calls[0][0]
        self.assertTrue(prompt.startswith("<|im_start|>system\nYou are a helpful assistant.<|im_end|>\n"))
        self.assertIn("Chinese-to-English simultaneous interpreter", prompt)
        self.assertTrue(prompt.endswith("<|im_start|>assistant\n"))

    def test_a_long_buffer_is_forced(self):
        model = ScriptedModel(["x"])
        s = SimulSession(model, "en2zh")
        s.feed(" ".join(["word"] * simt_server.FORCE_BREAK_UNITS))
        self.assertTrue(model.calls[0][1])

    def test_chinese_units_are_characters_and_a_trailing_english_word_waits(self):
        model = ScriptedModel(["x"])
        s = SimulSession(model, "zh2en")
        self.assertEqual(s.feed("我们今天讲 mitochondria"), [])
        self.assertEqual(model.calls, [])
        self.assertEqual(simt_server.source_units(s.buffer, "zh2en"), 6)

    def test_flush_forces_what_is_held(self):
        model = ScriptedModel(["", "最后"])
        s = SimulSession(model, "en2zh")
        s.feed("last")
        events = s.flush()
        self.assertEqual(events[0]["text"], "最后")
        self.assertTrue(model.calls[-1][1])
        self.assertEqual(s.flush(), [])

    def test_glossary_only_lists_terms_in_the_input_after_the_history(self):
        model = ScriptedModel(["x"])
        s = SimulSession(model, "en2zh", terms=[["eigenvalue", "特征值"], ["kernel", "核"]])
        s.feed("the eigenvalue is two")
        prompt = model.calls[0][0]
        self.assertIn("- eigenvalue -> 特征值", prompt)
        self.assertNotIn("kernel", prompt)
        self.assertLess(prompt.index("<STREAMING_HISTORY>"), prompt.index("### Terminology"))

    def test_history_is_trimmed_in_batches(self):
        model = ScriptedModel(["t"] * 40)
        s = SimulSession(model, "en2zh")
        for i in range(simt_server.HISTORY_MAX):
            s.feed(f"w{i}")
        self.assertEqual(len(s.history), simt_server.HISTORY_KEEP)

    def test_responses_are_parsed_like_the_reference(self):
        self.assertEqual(simt_server.parse_response(""), ("WAIT", ""))
        self.assertEqual(simt_server.parse_response("<WAIT>"), ("WAIT", ""))
        self.assertEqual(simt_server.parse_response("TRANS: 你好"), ("TRANS", "你好"))
        self.assertEqual(simt_server.parse_response("a¦b§c"), ("TRANS", "a｜b；c"))

    def test_unknown_direction_is_refused(self):
        with self.assertRaises(ValueError):
            SimulSession(ScriptedModel([]), "fr2de")


class ServerTests(unittest.TestCase):
    def test_request_loop(self):
        server = simt_server.Server(ScriptedModel(["", "你好世界"]))
        self.assertEqual(server.handle({"id": 1, "op": "start", "session": "a", "direction": "en2zh"}),
                         {"id": 1, "events": []})
        self.assertEqual(server.handle({"id": 2, "op": "feed", "session": "a", "text": "hello"}),
                         {"id": 2, "events": [{"type": "wait"}]})
        out = server.handle({"id": 3, "op": "flush", "session": "a"})
        self.assertEqual(out["events"][0]["text"], "你好世界")
        server.handle({"id": 4, "op": "end", "session": "a"})
        self.assertIn("error", server.handle({"id": 5, "op": "feed", "session": "a", "text": "x"}))

    def test_a_bad_start_is_an_error_not_a_crash(self):
        server = simt_server.Server(ScriptedModel([]))
        self.assertIn("error", server.handle({"id": 1, "op": "start", "session": "a",
                                              "direction": "xx"}))


if __name__ == "__main__":
    unittest.main()
