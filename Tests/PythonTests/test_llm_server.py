#!/usr/bin/env python3
"""Unit tests for llm_server.

Model-free: Qwen3-4B needs MLX, which only exists on Apple silicon, so what is
covered here is request parsing, the clamps that keep a laptop-sized model from
running away, prompt building and the parent watchdog.

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

import llm_server


class _Exited(BaseException):
    """Stands in for os._exit, which a test process cannot actually call. A
    BaseException so it is not swallowed by the code under test."""


class MessageTests(unittest.TestCase):
    def test_well_formed_turns_are_kept_in_order(self):
        messages = llm_server.normalize_messages([
            {"role": "system", "content": "You summarise lectures."},
            {"role": "user", "content": "Summarise this."},
        ])
        self.assertEqual([m["role"] for m in messages], ["system", "user"])

    def test_unusable_turns_are_dropped_rather_than_failing_the_request(self):
        # apply_chat_template raises on any of these, which would cost the whole
        # answer instead of one turn.
        messages = llm_server.normalize_messages([
            {"role": "user", "content": ""},
            {"role": "user", "content": "   "},
            {"role": "user"},
            {"role": "user", "content": 42},
            "not a turn",
            {"role": "user", "content": "keep me"},
        ])
        self.assertEqual(messages, [{"role": "user", "content": "keep me"}])

    def test_an_unknown_role_becomes_user(self):
        messages = llm_server.normalize_messages([{"role": "tool", "content": "hi"}])
        self.assertEqual(messages[0]["role"], "user")

    def test_no_messages_at_all(self):
        self.assertEqual(llm_server.normalize_messages(None), [])
        self.assertEqual(llm_server.normalize_messages([]), [])


class ClampTests(unittest.TestCase):
    def test_max_tokens_stays_inside_the_budget(self):
        self.assertEqual(llm_server.clamp_max_tokens(2048), 2048)
        self.assertEqual(llm_server.clamp_max_tokens(1), llm_server.MIN_MAX_TOKENS)
        self.assertEqual(llm_server.clamp_max_tokens(1_000_000), llm_server.MAX_MAX_TOKENS)

    def test_a_missing_or_broken_max_tokens_uses_the_default(self):
        self.assertEqual(llm_server.clamp_max_tokens(None), llm_server.DEFAULT_MAX_TOKENS)
        self.assertEqual(llm_server.clamp_max_tokens("lots"), llm_server.DEFAULT_MAX_TOKENS)

    def test_temperature_is_clamped_and_defaulted(self):
        self.assertEqual(llm_server.clamp_temperature(0.7), 0.7)
        self.assertEqual(llm_server.clamp_temperature(-1), 0.0)
        self.assertEqual(llm_server.clamp_temperature(9), 2.0)
        self.assertEqual(llm_server.clamp_temperature(None),
                         llm_server.DEFAULT_TEMPERATURE)
        self.assertEqual(llm_server.clamp_temperature("warm"),
                         llm_server.DEFAULT_TEMPERATURE)


class PromptTests(unittest.TestCase):
    MESSAGES = [{"role": "system", "content": "You summarise lectures."},
                {"role": "user", "content": "Summarise this."}]

    class _Tokenizer:
        def __init__(self, template=True):
            self.template = template
            self.kwargs = None

        def apply_chat_template(self, messages, **kwargs):
            if not self.template:
                raise ValueError("no chat template")
            self.kwargs = kwargs
            return "<|im_start|>" + messages[-1]["content"]

    def test_the_template_is_asked_for_text_not_token_ids(self):
        tokenizer = self._Tokenizer()
        prompt = llm_server.build_prompt(tokenizer, self.MESSAGES)
        self.assertEqual(tokenizer.kwargs,
                         {"add_generation_prompt": True, "tokenize": False})
        self.assertEqual(prompt, "<|im_start|>Summarise this.")

    def test_a_tokenizer_without_a_chat_template_falls_back_to_plain_turns(self):
        prompt = llm_server.build_prompt(self._Tokenizer(template=False), self.MESSAGES)
        self.assertEqual(prompt, "system: You summarise lectures.\n\n"
                                 "user: Summarise this.\n\nassistant:")


class ModelPathTests(unittest.TestCase):
    def test_a_local_directory_is_used_as_it_is(self):
        with tempfile.TemporaryDirectory() as path:
            self.assertEqual(llm_server.resolve_model_path(path, "abc123"), path)

    def test_the_revision_is_only_passed_when_there_is_one(self):
        with mock.patch.dict(sys.modules, {"huggingface_hub": mock.MagicMock()}):
            hub = sys.modules["huggingface_hub"]
            hub.snapshot_download.return_value = "/cache/models--x"
            llm_server.resolve_model_path("org/model", "")
            self.assertNotIn("revision", hub.snapshot_download.call_args.kwargs)
            llm_server.resolve_model_path("org/model", "deadbeef")
            self.assertEqual(hub.snapshot_download.call_args.kwargs["revision"],
                             "deadbeef")


class HandshakeChannelTests(unittest.TestCase):
    def test_handshake_lines_survive_a_redirected_stdout(self):
        real = io.StringIO()
        with mock.patch.object(llm_server, "_HANDSHAKE", real), \
                contextlib.redirect_stdout(io.StringIO()) as redirected:
            llm_server.handshake(llm_server.STAGE_LINE)
            llm_server.handshake("READY")
            print("a progress bar")
        self.assertEqual(real.getvalue(), "STAGE 1/1 llm\nREADY\n")
        self.assertEqual(redirected.getvalue(), "a progress bar\n")


class ParentWatchdogTests(unittest.TestCase):
    def test_exits_even_when_the_log_write_fails(self):
        # The parent being gone is exactly what closes the read end of the
        # stderr pipe, so the watchdog's own log line is the operation most
        # likely to raise in the one situation it exists for.
        with mock.patch.object(llm_server, "log", side_effect=BrokenPipeError), \
                mock.patch.object(llm_server.os, "kill", side_effect=ProcessLookupError), \
                mock.patch.object(llm_server.os, "_exit", side_effect=_Exited):
            with self.assertRaises(_Exited):
                llm_server.watch_parent(1, interval=0)

    def test_keeps_watching_while_the_parent_is_alive(self):
        seen = []

        def kill(pid, sig):
            seen.append(pid)
            if len(seen) >= 3:
                raise ProcessLookupError

        with mock.patch.object(llm_server, "log"), \
                mock.patch.object(llm_server.os, "kill", side_effect=kill), \
                mock.patch.object(llm_server.os, "_exit", side_effect=_Exited):
            with self.assertRaises(_Exited):
                llm_server.watch_parent(7, interval=0)
        self.assertEqual(seen, [7, 7, 7])

    def test_a_broken_probe_stops_the_watchdog(self):
        with mock.patch.object(llm_server.os, "kill", side_effect=OSError), \
                mock.patch.object(llm_server.os, "_exit", side_effect=_Exited):
            llm_server.watch_parent(1, interval=0)


if __name__ == "__main__":
    unittest.main()
