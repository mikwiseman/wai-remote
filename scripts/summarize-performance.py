#!/usr/bin/env python3
"""Summarize opt-in WAI Remote JSONL measurements; never treat RTT as click-to-photon."""
import argparse
import json
import math
from collections import defaultdict
from pathlib import Path


def summarize(path):
    rows = [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]
    samples, previous = defaultdict(list), {}
    frame_times = defaultdict(list)
    video = defaultdict(float)
    formats, routes, codecs = set(), set(), set()
    for row in rows:
        event = row["event"]
        if event == "input-roundtrip":
            samples["input_roundtrip_ms"].append(row["ms"])
            samples[f'{row["kind"]}_roundtrip_ms'].append(row["ms"])
        elif event == "input-applied":
            samples["host_input_handler_ms"].append(row["handlingMs"])
        elif event == "input-dispatch":
            samples["host_input_queue_ms"].append(row["queueMs"])
        elif event == "capture":
            for field, name in [("fps", "capture_fps"), ("sampleOffsetMs", "capture_sample_offset_ms"), ("gapMaxMs", "capture_gap_max_ms")]:
                if field in row:
                    samples[name].append(row[field])
        elif event == "renderer":
            for field, name in [("fps", "renderer_fps"), ("gapP95Ms", "renderer_gap_p95_ms"),
                                ("gapMaxMs", "renderer_gap_max_ms"), ("gapsOver100Ms", "renderer_gaps_over_100ms")]:
                samples[name].append(row[field])
        elif event == "frame-timing":
            # These are delivery/draw-submission times, not physical presentation.
            frame_times[row["stage"]].extend(sample[0] for sample in row["samples"])
        elif event == "rtc":
            samples["buffered_bytes"].append(row["bufferedBytes"])
            stats = {s["id"]: s for s in row["stats"]}
            selected = {s["values"].get("selectedCandidatePairId") for s in stats.values() if s["type"] == "transport"}
            for stat in stats.values():
                value, kind, key = stat["values"], stat["type"], stat["id"]
                if kind == "candidate-pair" and key in selected:
                    if "currentRoundTripTime" in value:
                        samples["network_rtt_ms"].append(value["currentRoundTripTime"] * 1000)
                    local = stats.get(value.get("localCandidateId"), {}).get("values", {})
                    remote = stats.get(value.get("remoteCandidateId"), {}).get("values", {})
                    routes.add(f'{local.get("candidateType")}/{local.get("relayProtocol", local.get("protocol"))} -> {remote.get("candidateType")}')
                if kind not in ("inbound-rtp", "outbound-rtp") or value.get("kind") != "video":
                    continue
                if "frameWidth" in value:
                    formats.add(f'{value["frameWidth"]}x{value["frameHeight"]}')
                codec = stats.get(value.get("codecId"), {}).get("values", {}).get("mimeType")
                if codec:
                    codecs.add(f'{codec} / {value.get("encoderImplementation", value.get("decoderImplementation", "unknown"))}')
                if "framesPerSecond" in value:
                    samples["fps"].append(value["framesPerSecond"])
                before = previous.get(key)
                previous[key] = (row["time"], value)
                if not before:
                    continue
                elapsed, prior = row["time"] - before[0], before[1]
                if elapsed <= 0:
                    continue
                def delta(field):
                    if field not in value or field not in prior:
                        return None
                    difference = value[field] - prior[field]
                    return difference if difference >= 0 else None
                if kind == "inbound-rtp":
                    video["measured_s"] += elapsed
                    for field, name in [("framesDecoded", "decoded_frames"), ("framesDropped", "dropped_frames"),
                                        ("freezeCount", "freezes"), ("totalFreezesDuration", "freeze_duration_s")]:
                        change = delta(field)
                        if change is not None:
                            video[name] += change
                for time_key, count_key, name in [
                    ("totalEncodeTime", "framesEncoded", "encode_ms"),
                    ("totalDecodeTime", "framesDecoded", "decode_ms"),
                    ("jitterBufferDelay", "jitterBufferEmittedCount", "video_buffer_ms"),
                    ("totalPacketSendDelay", "packetsSent", "packet_send_delay_ms"),
                ]:
                    duration, count = delta(time_key), delta(count_key)
                    if duration is not None and count:
                        samples[name].append(duration / count * 1000)
                byte_delta = delta("bytesReceived" if kind == "inbound-rtp" else "bytesSent")
                if byte_delta is not None:
                    samples["video_mbps"].append(byte_delta * 8 / elapsed / 1e6)
                for field, name in [("framesDropped", "dropped_frames_per_s"), ("freezeCount", "freezes_per_s")]:
                    change = delta(field)
                    if change is not None:
                        samples[name].append(change / elapsed)
    frame_cadence = {}
    for stage, timestamps in frame_times.items():
        timestamps.sort()
        if len(timestamps) < 2 or timestamps[-1] <= timestamps[0]:
            continue
        duration = (timestamps[-1] - timestamps[0]) / 1e6
        frame_cadence[stage] = {"frames": len(timestamps), "duration_s": round(duration, 3),
                                "fps": round((len(timestamps) - 1) / duration, 3)}
        samples[f"{stage}_gap_ms"].extend((b - a) / 1000 for a, b in zip(timestamps, timestamps[1:]))
    def distribution(values):
        values = sorted(x for x in values if math.isfinite(x))
        if not values:
            return None
        return {"n": len(values), "p50": round(values[math.ceil(len(values) * .5) - 1], 3),
                "p95": round(values[math.ceil(len(values) * .95) - 1], 3), "max": round(values[-1], 3)}
    if video.get("measured_s"):
        video["freeze_fraction"] = video["freeze_duration_s"] / video["measured_s"]
    return {"file": str(path), "duration_s": round(rows[-1]["time"] - rows[0]["time"], 1) if rows else 0,
            "formats": sorted(formats), "codecs": sorted(codecs), "routes": sorted(routes),
            "frame_cadence": frame_cadence,
            "video_totals": {key: round(value, 4) for key, value in sorted(video.items())},
            "measurements": {key: distribution(value) for key, value in sorted(samples.items())}}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", nargs="+")
    args = parser.parse_args()
    print(json.dumps([summarize(path) for path in args.files], indent=2))
