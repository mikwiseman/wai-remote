# Codex control through WAI Remote

Open WAI Remote on the MacBook. Its Python 3 CLI is included in the installed app at `/Applications/WAI Remote.app/Contents/Resources/wai-remote-agent.py`. The source checkout also provides `scripts/wai-remote-agent.py`. Codex can use either without moving the MacBook's pointer or using its clipboard:

```sh
agent='/Applications/WAI Remote.app/Contents/Resources/wai-remote-agent.py'
python3 "$agent" status
python3 "$agent" connect SAVED_COMPUTER_ID
python3 "$agent" screenshot --output /tmp/mini-before.png
python3 "$agent" click --snapshot SNAPSHOT_ID --x 0.5 --y 0.5
python3 "$agent" text --snapshot SNAPSHOT_ID 'Exact text — Привет!'
python3 "$agent" key --snapshot SNAPSHOT_ID Enter
python3 "$agent" scroll --snapshot SNAPSHOT_ID --x 0.5 --y 0.5 --dy 160
python3 "$agent" screenshot --output /tmp/mini-after.png
python3 "$agent" disconnect
```

Every command returns JSON. `status` lists saved computer IDs without invitations or credentials. Connecting opens the usual viewer window using an existing saved computer and the ordinary WAI connection; it cannot approve a device, reopen access, or replace an active session. Wait for `connected: true` and `canControl: true` before input. Subsequent agent commands do not need that window to have keyboard focus.

Inspect the PNG before acting. Coordinates run from 0 to 1 across the remote image, with the origin at its top left; MacBook window size, zoom and letterboxing do not affect them. `click --count 2` double-clicks. `key` takes physical DOM codes such as `Enter`, `KeyA` and `ArrowDown`; use `--modifier Meta` for Command. Use `text` for exact Unicode, independent of keyboard layout. Omit its text argument to read stdin. Scroll deltas are remote logical points, with positive Y scrolling down; each axis is limited to 2000 points.

Click the intended text area before typing, especially after opening a new window. The host keeps keyboard input tied to the remote window you selected; a new window appearing does not itself select that window for remote typing.

Input requires the last returned `snapshotID`. A newer video frame does not invalidate it. Reconnecting, changing surface/geometry or control context, losing permission, or replacing the video track does. On `stale_snapshot`, take and inspect another screenshot. On `congested`, wait and inspect again rather than queuing more actions. `frame_pending` means no decoded frame is available for the current context yet. `app_busy` cancels a request that never started; `execution_pending` means it already started but its result is unknown. Inspect a fresh screenshot before deciding what to do next; do not repeat that action blindly.

`submitted` confirms submission to the WAI input path, not execution by the remote app. After an action, obtain a screenshot with a greater `frameNumber` and inspect the effect. The response includes `decodedAtUptimeSeconds` and `frameAgeMs`. A moving frame alone does not prove that an action succeeded. Use a new output filename for each screenshot. Finish by disconnecting so the Mini is available to other devices.

The running app binds only `~/Library/Caches/is.wai.remote.agent/control.sock`: a mode-0600 Unix socket inside a mode-0700 directory. The server verifies the peer UID, rejects redirected paths and bounded invalid requests, and serializes commands through the existing viewer. It exposes no TCP port, shell execution, file transfer, credentials, new permission or background service. PNGs are encoded only on request; only the latest decoded frame is retained.
