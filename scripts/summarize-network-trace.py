#!/usr/bin/env python3
"""Extract congestion/probe metadata from an opt-in WebRTC v2 event log.

Never prints packet payloads, ICE details, addresses or SDP. A live log may end
mid-message; only complete protobuf messages are read. Batched BWE deltas are
not decoded: first_in_batch explicitly labels those sparse observations.
Schema: webrtc/logging/rtc_event_log/rtc_event_log2.proto.
"""
import argparse
import json
from pathlib import Path


def fields(data):
    position = 0

    def varint():
        nonlocal position
        value = 0
        for shift in range(0, 70, 7):
            if position >= len(data):
                raise EOFError
            byte = data[position]
            position += 1
            value |= (byte & 127) << shift
            if byte < 128:
                return value
        raise ValueError("Invalid protobuf varint")

    while position < len(data):
        try:
            tag = varint()
            wire = tag & 7
            if wire == 0:
                value = varint()
            elif wire in (1, 2, 5):
                size = varint() if wire == 2 else 8 if wire == 1 else 4
                if size > len(data) - position:
                    return
                value = data[position:position + size]
                position += size
            else:
                raise ValueError("Expected a WebRTC v2 protobuf log")
            yield tag >> 3, value
        except EOFError:
            return


def summarize(path):
    keys = {16: ("begin", {1: "monotonic_ms", 2: "version", 3: "utc_ms"}),
            18: ("loss_first_in_batch", {1: "monotonic_ms", 2: "bitrate_bps", 3: "fraction_loss_256", 5: "additional_events"}),
            19: ("delay_first_in_batch", {1: "monotonic_ms", 2: "bitrate_bps", 3: "detector_state", 4: "additional_events"}),
            21: ("probe", {1: "monotonic_ms", 2: "id", 3: "bitrate_bps", 4: "min_packets", 5: "min_bytes"}),
            22: ("probe_success", {1: "monotonic_ms", 2: "id", 3: "bitrate_bps"}),
            23: ("probe_failure", {1: "monotonic_ms", 2: "id", 3: "failure"}),
            24: ("alr", {1: "monotonic_ms", 2: "in_alr"})}
    events, offset = [], None
    for tag, data in fields(Path(path).read_bytes()):
        if tag not in keys or not isinstance(data, bytes):
            continue
        kind, allowed = keys[tag]
        row = {allowed[key]: value for key, value in fields(data) if key in allowed and isinstance(value, int)}
        if kind == "begin":
            if row.get("version") != 2:
                raise ValueError("Unsupported WebRTC log version")
            offset = row["utc_ms"] - row["monotonic_ms"]
        if offset is not None and "monotonic_ms" in row:
            row["utc_ms"] = row["monotonic_ms"] + offset
        events.append({"kind": kind, **row})
    return events


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("file", type=Path)
    print(json.dumps(summarize(parser.parse_args().file), indent=2))
