#!/usr/bin/env python3
"""Control an existing WAI Remote viewer through its private local socket."""
import argparse
import base64
import json
import os
from pathlib import Path
import socket
import stat
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status", help="Show connection state and saved computer IDs")
    connect = commands.add_parser("connect", help="Connect to a saved computer; never replace an active session")
    connect.add_argument("computerID")
    screenshot = commands.add_parser("screenshot", help="Save the latest decoded remote frame as PNG")
    screenshot.add_argument("--output", required=True, type=Path)
    commands.add_parser("disconnect", help="Disconnect this viewer and cancel retries")
    for command in ["click", "scroll", "key", "text"]:
        action = commands.add_parser(command)
        action.add_argument("--snapshot", dest="snapshotID", required=True)
        if command in ["click", "scroll"]:
            action.add_argument("--x", type=float, required=True, help="Top-left normalized remote coordinate, 0 to 1")
            action.add_argument("--y", type=float, required=True, help="Top-left normalized remote coordinate, 0 to 1")
        if command == "click":
            action.add_argument("--button", type=int, choices=[0, 1, 2], default=0, help="0 left, 1 middle, 2 right")
            action.add_argument("--count", dest="clickCount", type=int, choices=[1, 2], default=1)
        if command in ["click", "key"]:
            action.add_argument("--modifier", dest="modifiers", action="append", choices=["Meta", "Control", "Alt", "Shift"])
        if command == "scroll":
            action.add_argument("--dx", dest="deltaX", type=float, default=0)
            action.add_argument("--dy", dest="deltaY", type=float, default=0, help="Remote logical points; positive scrolls down")
        if command == "key":
            action.add_argument("key", help="Physical DOM code, for example Enter, KeyA, ArrowDown")
        if command == "text":
            action.add_argument("text", nargs="?", help="Exact Unicode; omit to read stdin")
    args = vars(parser.parse_args())
    output = args.pop("output", None)
    if args["command"] == "text" and args.get("text") is None:
        args["text"] = sys.stdin.read(16_385)
    request = {key: value for key, value in args.items() if value is not None}
    payload = json.dumps(request, ensure_ascii=False, allow_nan=False).encode("utf-8")
    if len(payload) > 65_536:
        raise ValueError("request_too_large")
    path = Path.home() / "Library/Caches/is.wai.remote.agent/control.sock"
    directory = path.parent.lstat()
    endpoint = path.lstat()
    if (not stat.S_ISDIR(directory.st_mode) or stat.S_IMODE(directory.st_mode) != 0o700
            or directory.st_uid != os.geteuid() or not stat.S_ISSOCK(endpoint.st_mode)
            or stat.S_IMODE(endpoint.st_mode) != 0o600 or endpoint.st_uid != os.geteuid()):
        raise ValueError("unsafe_socket")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(10)
        connection.connect(str(path))
        connection.sendall(payload + b"\n")
        response = bytearray()
        while True:
            block = connection.recv(65_536)
            if not block:
                break
            response.extend(block)
            if len(response) > 48 * 1024 * 1024:
                raise ValueError("response_too_large")
        result = json.loads(response)
    if output is not None and result.get("ok"):
        image = result.pop("image")
        pixels = base64.b64decode(image.pop("base64"), validate=True)
        if image.get("mimeType") != "image/png" or not pixels.startswith(b"\x89PNG\r\n\x1a\n"):
            raise ValueError("invalid_image")
        output = output.expanduser().absolute()
        # Never follow or overwrite a destination supplied by another process.
        if output.exists() or output.is_symlink():
            raise ValueError("output_exists")
        with tempfile.NamedTemporaryFile(dir=output.parent, prefix=".wai-frame-", delete=False) as staged:
            staged.write(pixels)
            temporary = Path(staged.name)
        try:
            os.link(temporary, output)
        finally:
            temporary.unlink()
        result["image"] = {**image, "path": str(output)}
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError) as error:
        code = "app_unavailable" if isinstance(error, (FileNotFoundError, ConnectionRefusedError)) else str(error)
        print(json.dumps({"ok": False, "error": code}), file=sys.stderr)
        sys.exit(1)
