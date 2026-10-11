# Responsiveness verification

Work in progress, 11 October 2026. Target: the user's MacBook and **waiMini**, not Mark's Mac.

## Measurements before changing behavior

Build 4 is an instrumented 0.2.0 baseline plus the separately verified stale-frame fix. `defaults write is.wai.remote.dev performanceDiagnostics -bool true` before launch enables bounded local JSONL files in the user's temporary directory (`wai-remote-performance-PID.jsonl`). This records no screen pixels, text, keys, SDP, IP addresses, or device names. Disable the preference after the comparison.

- RTC candidate pair/transport, round-trip time, bytes, frame dimensions/rate, encode/decode time, jitter-buffer delay, lost/dropped frames and freezes.
- Application data-channel round trip for accepted heartbeat/click messages; host input-handler duration. This is **not** click-to-photon latency.
- Capture sample timestamp offset from the host monotonic clock. ScreenCaptureKit can supply a future display timestamp; negative offsets are valid and this is not capture latency.
- Native input test: counter, text field, timestamp and moving bar. Inspect the same scene through WAI Remote and AnyDesk, at the same size and network conditions.
- Record host/receiver CPU and existing workloads. Do not terminate unrelated work to improve a result.

## Known baseline constraints

Source inspection, not benchmark conclusions: capture is capped at 1920 px / 30 fps / BGRA; the public gateway forces relay-only ICE with TURN over TCP; sender parameters use defaults; all interaction shares one ordered reliable channel; heartbeat and host housekeeping use default-mode timers; every display notification closes sharing.

## Acceptance

1. Fresh live video, text clarity, reliable click/paste/drag, menu/focus recovery, reconnect.
2. No multi-second growth in input/video queues during continuous movement or screen updates.
3. Prefer a direct authenticated peer route when available; verify UDP relay and TCP fallback independently.
4. Measure p50/p95 and sample duration. State topology, resolution, codec and network conditions. Do not claim broad superiority from one comparison.
5. Permissions are reflected on return from System Settings, with a clear actionable path if macOS requires relaunch; no silent loss of the pending action.
6. Signed/notarized update installed on both Macs through Sparkle and retested.

## Primary references

- [Apple ScreenCaptureKit performance and surface lifetimes](https://developer.apple.com/videos/play/wwdc2022/10155/): NV12 for encoding, native pixels, capture-queue latency tradeoffs, live configuration updates.
- [Apple capture sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos): output size and frame-interval configuration.
- [WebRTC native H.264 implementation](https://webrtc.googlesource.com/src/+/main/sdk/objc/components/video_codec/RTCVideoEncoderH264.mm): VideoToolbox real-time mode and no frame reordering.
- The pinned WebRTC 153 framework's Objective-C headers define the actual supported sender, codec and statistics APIs used by this app.

## First measured baseline (build 4, public relay/TCP)

11 October, approximately 11:40–11:43 Moscow, 182 seconds. MacBook M4 Pro / 24 GB, native Mini M4 / 16 GB, different Wi-Fi networks (both routed through existing VPNs). The Mini's 3840×2160 display uses a 1920×1080 logical desktop. Background workloads temporarily reached 100% CPU; they were not altered.

- Video: **1920×1080 VP8/libvpx**, median **29 fps**.
- Accepted input acknowledgement RTT: median **119 ms**, p95 **196 ms** (390 samples including heartbeat).
- Click-down RTT: median **120 ms**, p95 **236 ms** (14 samples).
- Video jitter-buffer residence: median **127 ms**, p95 **173 ms**, excluding network transit and display presentation.
- Ten consecutive clicks increased the native counter from 1 to 11. No input channel backlog observed.
- A 10-second delay was **not reproduced** in this baseline. Vertical window dragging did not follow the requested displacement and remains under investigation.

Raw diagnostic logs and screenshots remain in the ignored `.runtime` directory. These measurements are not a general comparison against AnyDesk or a physical click-to-photon measurement.

## Implemented, awaiting device comparison

Native Retina pixels, 60 fps NV12 capture, H.264 codec preference, a bounded 32 Mbps sender, direct ICE with authenticated UDP relay/TCP fallback, common-mode connection timers, effective system permissions separated from owner approval, and explicit permission return/relaunch guidance. Harmless display notifications no longer close access when the shared display geometry is unchanged.
