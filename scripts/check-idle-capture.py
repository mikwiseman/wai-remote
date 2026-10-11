#!/usr/bin/env python3
"""With diagnostics enabled, disconnect viewers and verify the host stops capturing."""
import argparse
import json
import time
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("log", type=Path)
parser.add_argument("--seconds", type=float, default=10)
args = parser.parse_args()
if not 1 <= args.seconds <= 60:
    parser.error("--seconds must be between 1 and 60")
with args.log.open() as stream:
    stream.seek(0, 2)
    time.sleep(args.seconds)
    rows = []
    for line in stream:
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            pass
active = [row for row in rows if row.get("event") == "capture" and row.get("fps", 0) > 0]
print(json.dumps({"seconds": args.seconds, "captureReports": len(active),
                  "idleCaptureStopped": not active}))
raise SystemExit(1 if active else 0)
