#!/usr/bin/env python3
"""Unit tests for simt_server (Confucius4-T3PO).

Model-free: a scripted model answers each prompt, so what is covered is the
interleaved-history protocol, the READ/WRITE bookkeeping and the request loop.

Run: python3 -m unittest discover -s Tests/PythonTests
"""
import json
import os
import shutil
import sys
import tempfile
import types
import unittest
import unittest.mock as mock

import huggingface_hub
from huggingface_hub import constants as hub_constants

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Scripts"))

import simt_server  # noqa: E402
from simt_server import SimulSession  # noqa: E402


class ScriptedModel:
    def __init__(self, answers):
        self.answers = list(answers)
        self.calls = []

    def complete(self, prompt, force, latency, on_text=None):
        self.calls.append((prompt, force, latency))
        answer = self.answers.pop(0) if self.answers else ""
        if on_text is not None:
            # As generation would: the completion so far, a character a time.
            for i in range(1, len(answer) + 1):
                on_text(answer[:i])
        return answer


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


class BoundaryTests(unittest.TestCase):
    def test_latin_words_from_two_lines_stay_apart_in_zh2en(self):
        model = ScriptedModel(["", "x"])
        s = SimulSession(model, "zh2en")
        s.feed("我们用 Python")
        s.feed("NumPy 来算")
        self.assertIn("Python NumPy", model.calls[-1][0])


class PartialTests(unittest.TestCase):
    def test_the_translation_arrives_as_it_grows(self):
        seen = []
        session = SimulSession(ScriptedModel(["细胞膜"]), "en2zh")
        events = session.feed("The cell membrane", seen.append)
        self.assertEqual(seen, ["细", "细胞", "细胞膜"])
        self.assertEqual(events[0]["text"], "细胞膜")

    def test_a_wait_sends_nothing(self):
        seen = []
        session = SimulSession(ScriptedModel(["", "<WAIT>"]), "en2zh")
        session.feed("The cell", seen.append)
        session.feed("membrane", seen.append)
        self.assertEqual(seen, [])

    def test_a_marker_is_held_until_it_cannot_be_one(self):
        self.assertEqual(simt_server.partial_text("W"), "")
        self.assertEqual(simt_server.partial_text("<TRA"), "")
        self.assertEqual(simt_server.partial_text("Tra"), "")
        self.assertEqual(simt_server.partial_text("Transport"), "Transport")
        self.assertEqual(simt_server.partial_text("TRANS: 细胞"), "细胞")
        self.assertEqual(simt_server.partial_text("We"), "We")
        self.assertEqual(simt_server.partial_text("细\ufffd"), "细")
        self.assertEqual(simt_server.partial_text("a¦b"), "a｜b")

    def test_flush_streams_too(self):
        seen = []
        session = SimulSession(ScriptedModel(["", "你好"]), "en2zh")
        session.feed("hello")
        session.flush(seen.append)
        self.assertEqual(seen, ["你", "你好"])


class ServerTests(unittest.TestCase):
    def test_partials_go_out_before_the_answer(self):
        sent = []
        server = simt_server.Server(ScriptedModel(["你好"]), send=sent.append)
        server.handle({"id": 1, "op": "start", "session": "a", "direction": "en2zh"})
        out = server.handle({"id": 2, "op": "flush", "session": "a"})
        self.assertEqual(out, {"id": 2, "events": []})   # nothing held yet
        server.handle({"id": 3, "op": "feed", "session": "a", "text": "hello " * 20})
        self.assertEqual(sent, [{"id": 3, "partial": "你"}, {"id": 3, "partial": "你好"}])

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


class _Interrupted(Exception):
    """The network going away, or the app quitting, mid-download."""


class ConvertModelTests(unittest.TestCase):
    """convert_model's bookkeeping around the ~28 GB bf16 download, on a fake
    hub cache: the download and the conversion are stubbed, the cache lookups
    are huggingface_hub's own."""

    SHARDS = ("model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors")

    def setUp(self):
        root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        self.cache = os.path.join(root, "hub")
        self.repo_dir = os.path.join(self.cache, "models--" + simt_server.SOURCE_REPO.replace("/", "--"))
        self.snapshot = os.path.join(self.repo_dir, "snapshots", simt_server.SOURCE_REVISION)
        self.model_dir = os.path.join(root, "models", "Confucius4-T3PO-4bit")
        self.marker = self.model_dir + ".source-ours"
        self.free = 10 ** 12
        self.interrupt = False
        self.downloads = 0
        mlx_lm = types.ModuleType("mlx_lm")
        mlx_lm.convert = self.convert
        for patcher in (mock.patch.object(hub_constants, "HF_HUB_CACHE", self.cache),
                        mock.patch.object(huggingface_hub, "snapshot_download", self.download),
                        mock.patch.dict(sys.modules, {"mlx_lm": mlx_lm}),
                        mock.patch.object(simt_server.shutil, "disk_usage",
                                          lambda path: types.SimpleNamespace(free=self.free)),
                        mock.patch.object(simt_server, "REQUIRED_FREE_BYTES", 1000)):
            patcher.start()
            self.addCleanup(patcher.stop)

    def put(self, name, size=100):
        """A finished file, laid out as huggingface_hub does: the bytes in
        blobs/, the snapshot entry a link to them."""
        blobs = os.path.join(self.repo_dir, "blobs")
        os.makedirs(blobs, exist_ok=True)
        os.makedirs(self.snapshot, exist_ok=True)
        blob = os.path.join(blobs, name + ".blob")
        if name.endswith(".index.json"):
            data = json.dumps({"weight_map": {f"w{i}": s for i, s in enumerate(self.SHARDS)}}).encode()
        else:
            data = bytes(size)
        with open(blob, "wb") as f:
            f.write(data)
        os.symlink(blob, os.path.join(self.snapshot, name))

    def download(self, repo, revision=None, allow_patterns=None):
        self.downloads += 1
        if self.interrupt:
            # config.json lands in the first seconds; the weights take hours.
            self.put("config.json")
            self.put("model.safetensors.index.json")
            self.put(self.SHARDS[0])
            with open(os.path.join(self.repo_dir, "blobs", "next.incomplete"), "wb") as f:
                f.write(bytes(50))
            raise _Interrupted()
        for name in ("config.json", "model.safetensors.index.json") + self.SHARDS:
            if not os.path.exists(os.path.join(self.snapshot, name)):
                self.put(name)
        return self.snapshot

    def convert(self, source, mlx_path, **kwargs):
        os.makedirs(mlx_path)
        with open(os.path.join(mlx_path, "config.json"), "w") as f:
            f.write("{}")

    def run_convert(self):
        return simt_server.convert_model(self.model_dir, lambda key: None)

    def test_an_interrupted_first_download_is_still_deleted_after_conversion(self):
        self.interrupt = True
        with self.assertRaises(_Interrupted):
            self.run_convert()
        self.assertTrue(os.path.exists(self.marker))
        self.interrupt = False
        self.assertEqual(self.run_convert(), self.model_dir)
        self.assertTrue(os.path.exists(os.path.join(self.model_dir, "config.json")))
        self.assertFalse(os.path.exists(self.repo_dir))
        self.assertFalse(os.path.exists(self.marker))

    def test_a_complete_checkpoint_that_was_already_there_is_kept(self):
        for name in ("config.json", "model.safetensors.index.json") + self.SHARDS:
            self.put(name)
        self.free = 0                       # nothing left to download
        self.run_convert()
        self.assertTrue(os.path.exists(os.path.join(self.model_dir, "config.json")))
        self.assertTrue(os.path.isdir(self.snapshot))
        self.assertFalse(os.path.exists(self.marker))

    def test_the_disk_check_counts_only_what_is_left_to_download(self):
        self.interrupt = True
        with self.assertRaises(_Interrupted):
            self.run_convert()
        self.interrupt = False
        blobs = os.path.join(self.repo_dir, "blobs")
        already = sum(os.path.getsize(os.path.join(blobs, name)) for name in os.listdir(blobs))
        self.assertGreater(already, 300)    # three files and a partial one
        self.free = 1000 - already - 1
        with self.assertRaises(RuntimeError):
            self.run_convert()
        self.assertEqual(self.downloads, 1)
        self.free = 1000 - already
        self.run_convert()
        self.assertFalse(os.path.exists(self.repo_dir))

    def test_a_first_download_needs_the_whole_margin(self):
        self.free = 999
        with self.assertRaises(RuntimeError):
            self.run_convert()
        self.assertEqual(self.downloads, 0)


if __name__ == "__main__":
    unittest.main()
