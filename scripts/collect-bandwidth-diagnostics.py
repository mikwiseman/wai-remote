#!/usr/bin/env python3
"""Export numeric diagnostics from one isolated synthetic benchmark process.

Raw RTC logs and performance files stay outside the artifact directory.
BWE records are sparse first-in-batch observations, not a complete trajectory.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path


def decoder_rows(rows):
    result = []
    for row in rows:
        if row.get("event") != "frame-timing" or row.get("stage") not in {"decode-input", "decode-output"}:
            continue
        for sample in row.get("samples", []):
            if not isinstance(sample, list) or len(sample) != 3 or any(type(v) is not int for v in sample):
                raise ValueError("Malformed decoder timing sample")
            result.append(dict(stage=row["stage"], uptimeUs=sample[0], timestamp=sample[1], detail=sample[2]))
    if {r["stage"] for r in result} != {"decode-input", "decode-output"}:
        raise ValueError("A decoder boundary was not recorded")
    return sorted(result, key=lambda row: row["uptimeUs"])


def network_summary(path):
    spec = importlib.util.spec_from_file_location("network_summary", Path(__file__).with_name("summarize-network-trace.py"))
    parser = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(parser)
    raw = path.read_bytes()
    events = parser.summarize(path)
    endings = []
    for tag, payload in parser.fields(raw):
        if tag == 17 and isinstance(payload, bytes):
            endings.extend(value for field, value in parser.fields(payload) if field == 1 and type(value) is int)
    beginnings = [row for row in events if row["kind"] == "begin"]
    if len(beginnings) != 1 or len(endings) != 1:
        raise ValueError("Network log is missing its unique begin/end boundary")
    begin = beginnings[0]
    if endings[0] <= begin["monotonic_ms"]:
        raise ValueError("Network log end precedes start")
    return {"rawSHA256": hashlib.sha256(raw).hexdigest(), "rawBytes": len(raw),
            "beginMonotonicMs": begin["monotonic_ms"], "endMonotonicMs": endings[0],
            "durationSeconds": (endings[0] - begin["monotonic_ms"]) / 1000,
            "bweSampling": "First sample of each batch only; additional_events are not decoded.",
            "events": sorted(events, key=lambda row: row.get("monotonic_ms", -1))}


def collect(directory):
    manifest = json.loads((directory / "diagnostic-inputs.json").read_text())
    performance = Path(manifest["performanceLog"])
    rows = [json.loads(line) for line in performance.read_text().splitlines() if line.strip()]
    starts = [row for row in rows if row.get("event") == "network-trace"]
    for role in ("host", "viewer"):
        if not any(row.get("role") == role and row.get("started") is True for row in starts):
            raise ValueError(f"{role} network log did not start")
    timing = decoder_rows(rows)
    networks = {role: network_summary(Path(manifest[role + "NetworkTrace"])) for role in ("host", "viewer")}
    run = json.loads((directory / "diagnostic.json").read_text())
    if not run.get("diagnosticOnly"):
        raise ValueError("Expected the isolated diagnostic session")
    anchor = run["clockAnchor"]
    duration = run["durationSeconds"]
    for role, network in networks.items():
        begin = next(row for row in network["events"] if row["kind"] == "begin")
        offset = begin["utc_ms"] - begin["monotonic_ms"]
        start_utc = anchor["utcSeconds"] * 1000
        if begin["utc_ms"] > start_utc + 20 or network["endMonotonicMs"] + offset < start_utc + duration * 1000 - 20:
            raise ValueError(f"{role} network log does not cover the measured interval")
    output = {"sourceRevision": run["sourceRevision"], "clockAnchor": anchor,
              "decoderTimings": timing, "network": networks,
              "limitations": ["Decoder timing batches can omit the final sub-second tail; this is not zero loss.",
                              "No packets, addresses, candidates, SDP, or raw logs are exported.",
                              "Native drop counters cover whole session lifetime including warm-up."]}
    (directory / "diagnostics.json").write_text(json.dumps(output, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"decoderSamples": len(timing), "networkEvents": {r: len(n["events"]) for r, n in networks.items()}}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    collect(parser.parse_args().directory)
