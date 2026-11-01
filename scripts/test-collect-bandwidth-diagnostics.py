import importlib.util
from pathlib import Path
import tempfile
import unittest


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DiagnosticBoundaryTests(unittest.TestCase):
    @staticmethod
    def varint(value):
        result = bytearray()
        while value > 127:
            result.append((value & 127) | 128)
            value >>= 7
        result.append(value)
        return bytes(result)

    def event(self, tag, values):
        payload = b"".join(self.varint(key << 3) + self.varint(value) for key, value in values.items())
        return self.varint((tag << 3) | 2) + self.varint(len(payload)) + payload

    def test_only_numeric_decoder_timing_survives(self):
        collector = load("collector", "collect-bandwidth-diagnostics.py")
        rows = [
            {"event": "frame-timing", "time": 123.5, "stage": "decode-input",
             "samples": [[1000, 42, 56]], "address": "PRIVATE"},
            {"event": "rtc", "address": "PRIVATE"},
            {"event": "frame-timing", "stage": "decode-output", "samples": [[2000, 99, 0]]},
            {"event": "frame-timing", "stage": "other", "samples": [[1, 2, 3]]},
        ]
        self.assertEqual(collector.decoder_rows(rows), [
            {"stage": "decode-input", "uptimeUs": 1000, "timestamp": 42, "detail": 56},
            {"stage": "decode-output", "uptimeUs": 2000, "timestamp": 99, "detail": 0},
        ])

    def test_malformed_timing_fails_closed(self):
        collector = load("collector", "collect-bandwidth-diagnostics.py")
        with self.assertRaises(ValueError):
            collector.decoder_rows([{"event": "frame-timing", "stage": "decode-input",
                                     "samples": [[1, "PRIVATE", 3]]}])

    def test_missing_decoder_boundary_is_not_zero(self):
        collector = load("collector", "collect-bandwidth-diagnostics.py")
        with self.assertRaises(ValueError):
            collector.decoder_rows([])

    def test_network_events_sorted_and_complete_with_unknown_fields_excluded(self):
        collector = load("collector", "collect-bandwidth-diagnostics.py")
        raw = (self.event(16, {1: 1000, 2: 2, 3: 100000}) +
               self.event(24, {1: 2000, 2: 1, 100: 999}) +
               self.event(21, {1: 1500, 2: 4, 3: 400000, 4: 5, 5: 1000}) +
               self.event(17, {1: 3000}))
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "test.rtc"
            path.write_bytes(raw)
            result = collector.network_summary(path)
            self.assertEqual(result["durationSeconds"], 2)
            self.assertEqual([r["kind"] for r in result["events"]], ["begin", "probe", "alr"])
            self.assertEqual(result["events"][-1], {"kind": "alr", "monotonic_ms": 2000, "utc_ms": 101000, "in_alr": 1})
            path.write_bytes(self.event(16, {1: 1000, 2: 2, 3: 100000}))
            with self.assertRaises(ValueError):
                collector.network_summary(path)


if __name__ == "__main__":
    unittest.main()
