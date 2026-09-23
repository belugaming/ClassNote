#!/usr/bin/env python3
"""Unit tests for translate_server.

Model-free: loading Hy-MT2 pulls ~1.2 GB and needs MLX, which only exists on
Apple silicon, so what is covered here is the handshake channel, the parent
watchdog and prompt/path plumbing.

Run: python3 -m unittest discover -s Tests/PythonTests
"""
import contextlib
import io
import os
import sys
import tempfile
import unittest
import unittest.mock as mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Scripts"))

import translate_server


class _Exited(BaseException):
    """Stands in for os._exit, which a test process cannot actually call. A
    BaseException so it is not swallowed by the code under test."""


class HandshakeChannelTests(unittest.TestCase):
    def test_handshake_lines_survive_a_redirected_stdout(self):
        # huggingface_hub rebinds sys.stdout while it draws progress bars; the
        # three lines Swift parses have to go to the stream this process
        # started with, not to whatever stdout happens to be.
        real = io.StringIO()
        with mock.patch.object(translate_server, "_HANDSHAKE", real), \
                contextlib.redirect_stdout(io.StringIO()) as redirected:
            translate_server.handshake(translate_server.STAGE_LINE)
            translate_server.handshake("READY")
            print("a progress bar")
        self.assertEqual(real.getvalue(), "STAGE 1/1 translation\nREADY\n")
        self.assertEqual(redirected.getvalue(), "a progress bar\n")


class ParentWatchdogTests(unittest.TestCase):
    def test_exits_even_when_the_log_write_fails(self):
        # The parent being gone is exactly what closes the read end of the
        # stderr pipe, so the watchdog's own log line is the operation most
        # likely to raise in the one situation it exists for.
        with mock.patch.object(translate_server, "log", side_effect=BrokenPipeError), \
                mock.patch.object(translate_server.os, "kill",
                                  side_effect=ProcessLookupError), \
                mock.patch.object(translate_server.os, "_exit", side_effect=_Exited):
            with self.assertRaises(_Exited):
                translate_server.watch_parent(1, interval=0)

    def test_keeps_watching_while_the_parent_is_alive(self):
        seen = []

        def kill(pid, sig):
            seen.append(pid)
            if len(seen) >= 3:
                raise ProcessLookupError

        with mock.patch.object(translate_server, "log"), \
                mock.patch.object(translate_server.os, "kill", side_effect=kill), \
                mock.patch.object(translate_server.os, "_exit", side_effect=_Exited):
            with self.assertRaises(_Exited):
                translate_server.watch_parent(7, interval=0)
        self.assertEqual(seen, [7, 7, 7])

    def test_a_broken_probe_stops_the_watchdog(self):
        with mock.patch.object(translate_server.os, "kill", side_effect=OSError), \
                mock.patch.object(translate_server.os, "_exit", side_effect=_Exited):
            translate_server.watch_parent(1, interval=0)


class ModelPathTests(unittest.TestCase):
    def test_a_local_directory_is_used_as_it_is(self):
        # A developer pointing --model at a converted checkout must not make the
        # sidecar go to the hub for a repo of that name.
        with tempfile.TemporaryDirectory() as path:
            self.assertEqual(translate_server.resolve_model_path(path, "abc123"), path)

    def test_the_revision_is_only_passed_when_there_is_one(self):
        with mock.patch.dict(sys.modules, {"huggingface_hub": mock.MagicMock()}):
            hub = sys.modules["huggingface_hub"]
            hub.snapshot_download.return_value = "/cache/models--x"
            translate_server.resolve_model_path("org/model", "")
            self.assertNotIn("revision", hub.snapshot_download.call_args.kwargs)
            translate_server.resolve_model_path("org/model", "deadbeef")
            self.assertEqual(hub.snapshot_download.call_args.kwargs["revision"],
                             "deadbeef")


class PromptTests(unittest.TestCase):
    class _Tokenizer:
        def __init__(self, template=True):
            self.template = template

        def apply_chat_template(self, messages, add_generation_prompt=False):
            if not self.template:
                raise ValueError("no chat template")
            return "<|user|>" + messages[0]["content"]

    def test_a_pair_with_chinese_uses_the_chinese_template(self):
        prompt = translate_server.build_prompt(self._Tokenizer(), "hello", "en", "zh")
        self.assertIn("将以下文本翻译为中文", prompt)
        self.assertTrue(prompt.endswith("hello"))

    def test_a_pair_without_chinese_uses_the_english_template(self):
        prompt = translate_server.build_prompt(self._Tokenizer(), "bonjour", "fr", "en")
        self.assertIn("Translate the following text into English", prompt)
        self.assertTrue(prompt.endswith("bonjour"))

    def test_a_tokenizer_without_a_chat_template_falls_back_to_the_instruction(self):
        prompt = translate_server.build_prompt(self._Tokenizer(template=False),
                                               "hello", "en", "zh")
        self.assertTrue(prompt.startswith("将以下文本"))
        self.assertIn("hello", prompt)

    def test_context_goes_in_as_background_not_as_text_to_translate(self):
        prompt = translate_server.build_instruction(
            "It breaks glucose down.", "en", "zh",
            context=["Old line.", "Glycolysis happens in the cytoplasm."])
        self.assertIn("【背景信息】\nOld line. Glycolysis happens in the cytoplasm.", prompt)
        self.assertTrue(prompt.endswith("【待翻译文本】\nIt breaks glucose down."))

    def test_background_keeps_only_the_nearest_sentences(self):
        prompt = translate_server.build_instruction(
            "x", "en", "zh", context=["one.", "two.", "three."])
        self.assertIn("two. three.", prompt)
        self.assertNotIn("one.", prompt)

    def test_only_terms_in_the_sentence_are_sent_and_flipped_to_match_it(self):
        terms = [["eigenvalue", "特征值"], ["矩阵", "matrix"], ["kernel", "核"]]
        prompt = translate_server.build_instruction(
            "The eigenvalue of this matrix is two.", "en", "zh", terms=terms)
        self.assertIn("参考下面的翻译：\neigenvalue 翻译成 特征值\nmatrix 翻译成 矩阵\n", prompt)
        self.assertNotIn("kernel", prompt)

    def test_a_latin_term_must_be_a_whole_word(self):
        prompt = translate_server.build_instruction(
            "This program uses a lot of memory.", "en", "zh", terms=[["RAM", "内存"]])
        self.assertNotIn("RAM", prompt)
        prompt = translate_server.build_instruction(
            "It needs more RAM.", "en", "zh", terms=[["RAM", "内存"]])
        self.assertIn("RAM 翻译成 内存", prompt)

    def test_malformed_terms_are_ignored(self):
        prompt = translate_server.build_instruction(
            "hello", "en", "zh", terms=[["hello"], "hello", ["", "x"], None])
        self.assertNotIn("参考", prompt)

if __name__ == "__main__":
    unittest.main()
