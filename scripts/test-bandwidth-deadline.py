#!/usr/bin/env python3
"""Fail-closed recovery-detail acceptance, independent of the sampler."""
import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("acceptance", Path(__file__).with_name("accept-bandwidth-correction.py"))
acceptance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acceptance)


class DeadlineTests(unittest.TestCase):
    def fixture(self):
        return {
            "rows": [
                {"stage": "source", "index": 123, "t": 30.5},
                {"stage": "encode-output", "rtp": 99, "width": 3840, "height": 2160, "t": 31.0},
                {"stage": "renderer-entry", "rtp": 99, "width": 3840, "height": 2160, "t": 31.99},
                {"stage": "renderer", "rtp": 99, "index": 123, "width": 3840, "height": 2160, "t": 31.991},
            ],
            "detail": [{"phase": "recovery-2s", "allocationAtSeconds": 30.0,
                        "deadlineAtSeconds": 32.0, "decodedAtSeconds": 31.99, "index": 123,
                        "rtp": 99, "width": 3840, "height": 2160,
                        "textROIPsnr": 35.0, "textEdgeMeanAbsoluteError": 10.0, "textEdgePixels": 100}],
        }

    def check(self, trace):
        return acceptance.recovery_deadline(trace, 30.0, 30.4)

    def test_fresh_matched_sharp_native_frame_at_deadline_passes(self):
        self.assertTrue(self.check(self.fixture())["pass"])

    def test_missing_checkpoint_cannot_use_final_detail(self):
        trace = self.fixture()
        trace["detail"][0]["phase"] = "recovery"
        self.assertFalse(self.check(trace)["pass"])

    def test_blurry_native_frame_fails(self):
        for field, value in [("textROIPsnr", 34.9), ("textEdgeMeanAbsoluteError", 10.1)]:
            trace = self.fixture()
            trace["detail"][0][field] = value
            self.assertFalse(self.check(trace)["pass"])

    def test_stale_source_late_frame_wrong_deadline_or_scaled_frame_fails(self):
        for change in ("stale", "late", "deadline", "scaled", "allocation", "invalid"):
            trace = self.fixture()
            if change == "stale": trace["rows"][0]["t"] = 30.3
            if change == "late": trace["detail"][0]["decodedAtSeconds"] = 32.001
            if change == "deadline": trace["detail"][0]["deadlineAtSeconds"] = 32.5
            if change == "scaled": trace["rows"][1]["width"] = 1920
            if change == "allocation": trace["detail"][0]["allocationAtSeconds"] = 30.5
            if change == "invalid": trace["detail"][0]["index"] = -1
            with self.subTest(change=change): self.assertFalse(self.check(trace)["pass"])

    def test_missing_or_ambiguous_identity_fails(self):
        for change in ("no-entry", "no-encode", "no-renderer", "duplicate-source", "duplicate-encode"):
            trace = self.fixture()
            if change.startswith("no-"):
                stage = {"no-entry": "renderer-entry", "no-encode": "encode-output", "no-renderer": "renderer"}[change]
                trace["rows"] = [r for r in trace["rows"] if r["stage"] != stage]
            else: trace["rows"].append(copy.deepcopy(trace["rows"][0 if change == "duplicate-source" else 1]))
            with self.subTest(change=change): self.assertFalse(self.check(trace)["pass"])

    def test_older_good_frame_cannot_hide_latest_bad_frame(self):
        trace = self.fixture()
        trace["rows"].append({"stage": "encode-output", "rtp": 100, "width": 1920, "height": 1080, "t": 31.993})
        trace["rows"].append({"stage": "renderer-entry", "rtp": 100, "width": 1920, "height": 1080, "t": 31.995})
        self.assertFalse(self.check(trace)["pass"])

    def test_later_frame_does_not_disqualify_frozen_sample(self):
        trace = self.fixture()
        trace["rows"].append({"stage": "encode-output", "rtp": 100, "width": 1920, "height": 1080, "t": 32.0})
        trace["rows"].append({"stage": "renderer-entry", "rtp": 100, "width": 1920, "height": 1080, "t": 32.001})
        self.assertTrue(self.check(trace)["pass"])

    def test_unknown_allocation_fails_without_exception(self):
        self.assertFalse(acceptance.recovery_deadline(self.fixture(), None, None)["pass"])

    def test_unique_causal_sender_to_receiver_rtp_offset_is_supported(self):
        trace = self.fixture()
        trace["rows"][1]["rtp"] = 2**32 - 10
        self.assertTrue(self.check(trace)["pass"])
        self.assertEqual(self.check(trace)["senderToReceiverRTPOffset"], 109)

    def test_duplicate_entry_or_noncausal_source_or_renderer_fails(self):
        for change in ("duplicate-entry", "source-after-encode", "renderer-before-entry"):
            trace = self.fixture()
            if change == "duplicate-entry": trace["rows"].append(copy.deepcopy(trace["rows"][2]))
            if change == "source-after-encode": trace["rows"][0]["t"] = 31.1
            if change == "renderer-before-entry": trace["rows"][3]["t"] = 31.989
            with self.subTest(change=change): self.assertFalse(self.check(trace)["pass"])


if __name__ == "__main__":
    unittest.main()
