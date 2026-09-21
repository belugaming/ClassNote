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

    def test_prompt_names_both_languages(self):
        prompt = translate_server.build_prompt(self._Tokenizer(), "hello", "en", "zh")
        self.assertIn("English", prompt)
        self.assertIn("Chinese", prompt)
        self.assertIn("hello", prompt)

    def test_a_tokenizer_without_a_chat_template_falls_back_to_the_instruction(self):
        prompt = translate_server.build_prompt(self._Tokenizer(template=False),
                                               "hello", "en", "zh")
        self.assertTrue(prompt.startswith("Translate"))
        self.assertIn("hello", prompt)


if __name__ == "__main__":
    unittest.main()
