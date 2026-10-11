# Responsiveness verification

Work in progress, 11 October 2026. Target: the user's MacBook and **waiMini**, not Mark's Mac.

## Build 20 baseline

Both Macs installed the same signed/notarized universal build through Sparkle (MacBook 19→20, Mini 17→20). Trusted devices and existing WAI Remote permissions remained usable. The public immutable DMG was downloaded and its SHA-256 matched the locally mounted and verified installer. The stable appcast and landing still advertise 0.2.0 while comparison continues.

The 611-second relay/TCP run on 11 October delivered **3840×2160 H.264 / VideoToolbox**, median **55 fps**, and 33,468 decoded frames with zero decoder drops. Application input acknowledgement p50/p95/max was **126/259/429 ms** over 1,251 samples. Video-buffer p50/p95 was **32.33/40.28 ms**; one interval reached 698 ms. Eighteen freezes totaled **5.901 seconds over 609 measured seconds (0.97%)**. All original numerical gates passed for this run, but it was close to the freeze threshold and does not prove consistently smooth playback. Per-second renderer maximum gaps had p50/p95 **125/148 ms**, with a worst gap of 496 ms.

Five real native clicks incremented the counter from zero to five; mixed-language paste and a 60×40-pixel diagonal title drag landed correctly. The TCP-only preference was then removed. The 287-second preferred UDP run delivered median 55 fps, acknowledgement p50/p95/max **127/269/562 ms**, and video-buffer p95 **36.54 ms**. Twelve freezes totaled **3.605 seconds over 283 measured seconds (1.27%)**, so this run **failed** the original 1% freeze gate. Reconnection showed a fresh frame in 4.2 seconds; another five clicks, mixed-language replacement and diagonal dragging passed. Raw measurements: `.runtime/mini-candidate20-{tcp,udp}.jsonl`; screenshot: `.runtime/mini-build20-tcp-live.png`.

## AnyDesk comparison and idle-capture regression

After the owner granted permissions and AnyDesk restarted, the MacBook connected to Mini at about 15:25 Moscow. AnyDesk reported 3840×2160, Best quality and its relay connection. Five real clicks incremented the same counter from 5 to 10. Automated paste conflicted with clipboard synchronization; plain text entry arrived without the requested uppercase letters, and the automated drag did not move the window. These automation results are not evidence that a human would experience the same limitations.

Exploratory OCR samples read the host's rendered timestamp from 60 screenshots per client (about 3.4 seconds each). They are not click-to-photon measurements: host/client clock offset was not independently calibrated and the capture call itself spans about 50 ms. They must not support a superiority claim.

The attempted isolated comparison revealed a product regression: **WAI capture continued after its viewer disconnected**. At 15:28:43, Mini's WAI process still captured 56.10 fps and used 22.8% CPU / 96.34 MiB RSS. AnyDesk's four processes used 57.3% CPU / 466.66 MiB summed RSS in that snapshot; shared pages may be counted twice. Since WAI's capture was competing for resources, these are not fair comparative CPU or video results. `scripts/check-idle-capture.py` checks new capture reports after all viewers disconnect; keep diagnostics enabled and verify the host process separately before interpreting it. Fix and retest this lifecycle before repeating the comparison.

## Measurements before changing behavior

Build 4 is an instrumented 0.2.0 baseline plus the separately verified stale-frame fix. `defaults write is.wai.remote.dev performanceDiagnostics -bool true` before launch enables bounded local JSONL files in the user's temporary directory (`wai-remote-performance-PID.jsonl`). This records no screen pixels, text, keys, SDP, IP addresses, or device names. Disable the preference after the comparison.

- RTC candidate pair/transport, round-trip time, bytes, frame dimensions/rate, encode/decode time, jitter-buffer delay, lost/dropped frames and freezes.
- Application data-channel round trip for accepted heartbeat/click messages; host input-handler duration. This is **not** click-to-photon latency.
- Capture sample timestamp offset from the host monotonic clock. ScreenCaptureKit can supply a future display timestamp; negative offsets are valid and this is not capture latency.
- Native input test: counter, text field, timestamp and moving bar. Inspect the same scene through WAI Remote and AnyDesk, at the same size and network conditions.
- Record host/receiver CPU and existing workloads. Do not terminate unrelated work to improve a result.
- With diagnostics enabled, `performanceTCPOnly=true` limits the viewer to TURN/TCP for an isolated fallback test without changing the user's network or other clients. Remove both preferences afterwards.

## Known baseline constraints

Source inspection, not benchmark conclusions: capture is capped at 1920 px / 30 fps / BGRA; the public gateway forces relay-only ICE with TURN over TCP; sender parameters use defaults; all interaction shares one ordered reliable channel; heartbeat and host housekeeping use default-mode timers; every display notification closes sharing.

## Acceptance

1. Fresh live video, text clarity, reliable click/paste/drag, menu/focus recovery, reconnect.
2. No multi-second growth in input/video queues during continuous movement or screen updates.
3. Use the measured reliable relay route; verify UDP and TCP fallback independently. Direct VPN routes must not ship until their SCTP stalls are resolved.
4. Measure p50/p95 and sample duration. State topology, resolution, codec and network conditions. Do not claim broad superiority from one comparison.
5. Permissions are reflected on return from System Settings, with a clear actionable path if macOS requires relaunch; no silent loss of the pending action.
6. Signed/notarized update installed on both Macs through Sparkle and retested.

## Primary references

- [Apple ScreenCaptureKit performance and surface lifetimes](https://developer.apple.com/videos/play/wwdc2022/10155/): NV12 for encoding, native pixels, capture-queue latency tradeoffs, live configuration updates.
- [Apple capture sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos): output size and frame-interval configuration.
- [Apple capture surface pool](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/queuedepth): a small pool can stall capture while asynchronous processing retains surfaces; the supported maximum is eight.
- [WebRTC native H.264 implementation](https://webrtc.googlesource.com/src/+/main/sdk/objc/components/video_codec/RTCVideoEncoderH264.mm): VideoToolbox real-time mode and no frame reordering.
- The pinned WebRTC 153 framework's Objective-C headers define the actual supported sender, codec and statistics APIs used by this app.

## First measured baseline (build 4, public relay/TCP)

11 October, approximately 11:40–11:43 Moscow, 182 seconds. MacBook M4 Pro / 24 GB, native Mini M4 / 16 GB, different Wi-Fi networks (both routed through existing VPNs). The Mini's 3840×2160 display uses a 1920×1080 logical desktop. Background workloads temporarily reached 100% CPU; they were not altered.

- Video: **1920×1080 VP8/libvpx**, median **29 fps**.
- Accepted input acknowledgement RTT: median **119 ms**, p95 **196 ms** (390 samples including heartbeat).
- Click-down RTT: median **120 ms**, p95 **236 ms** (14 samples).
- Video jitter-buffer residence: median **127 ms**, p95 **173 ms**, excluding network transit and display presentation.
- Ten consecutive clicks increased the native counter from 1 to 11. No input channel backlog observed.
- A 10-second delay was **not reproduced** in this baseline. Later relay testing confirmed the requested horizontal and vertical drag displacement; a direct-route drag arrived 13.7 seconds late.

Raw diagnostic logs and screenshots remain in the ignored `.runtime` directory. These measurements are not a general comparison against AnyDesk or a physical click-to-photon measurement.

## Findings from the first 4K candidate

The 129-second run on builds 5/6 negotiated a direct UDP route and delivered **3840×2160 at median 57 fps**. Median video-buffer residence fell to **59 ms**. However, the actual encoder was still VP8, and application acknowledgements reached **7.16 seconds**, despite network RTT staying around 108 ms. This candidate is not the release result.

Two regressions were reproduced in native tests:

- WebRTC's default H.264 capabilities advertise level 3.1 (`640c1f` / `42e01f`). The native 4K encode returned an error and no frame. The screen encoder/decoder factories now advertise level 5.2; the same 3840×2160 NV12 encode succeeds. Mini build 7 verified H.264 / VideoToolbox, with `powerEfficientEncoder=true`.
- A nested AppKit tracking loop entered from a main-queue callback cannot drain another main-queue callback. Input delivery now uses the common run-loop modes, so a release can arrive before tracking ends. A regression test fails with main-queue delivery and passes with common-mode delivery. This fixed a real dispatch defect, but did not resolve the subsequent network-channel stalls.

ICE discovery also timed out despite usable relay candidates on another VPN interface. A native test with an unanswered STUN endpoint now returns the available candidates. Updated clients advertise `iceVersion: 2`; older clients retain TCP relay settings, including in refreshed credentials.

## Direct route versus UDP relay

The same Mini build 7, native 4K H.264 scene and background workloads were used. The direct-route run lasted 478 seconds: input acknowledgement p95 was **26.3 seconds**, maximum **30.3 seconds**, and a real title-bar drag arrived after **13.7 seconds**. Video kept flowing with zero RTP packet losses during that drag. The Mini's two-minute host-side sample showed dispatch p95 **6.21 ms** and handling p95 **0.101 ms**. The remaining delay was not in the native input handler.

Forcing UDP relay at the viewer (build 8) reduced acknowledgement p50/p95/max to **124/198/263 ms** over **436 seconds / 881 samples**. All sampled outgoing buffers were empty. Five clicks advanced the counter from 0 to 5; paste preserved a mixed Latin/Cyrillic string; a diagonal title drag moved exactly the requested 30×55 screen pixels. The public gateway now selects relay for native clients too, with UDP before TCP. Older clients continue to receive TCP only.

This run still had a median **45 fps**, and video-buffer p95 grew to **345 ms**. Builds 9/10 preserve the hardware frame cadence and render complete frames without the adaptive conference playout delay.

The receiver setting follows WebRTC's [remote-access playout guidance](https://webrtc.googlesource.com/src/+/refs/heads/main/docs/native-code/rtp-hdrext/playout-delay/README.md). The pinned Objective-C framework exposes `WebRTC-ForcePlayoutDelay` through `RTCInitFieldTrialDictionary`; this must run before creating any RTC object. Reverify this integration when upgrading WebRTC.

## Hardware cadence and immediate playout

Mini build 9 → MacBook build 10, UDP relay, **297 seconds / 610 acknowledgements**:

- **3840×2160 H.264 / VideoToolbox**, median **57 fps**, p95 60 fps.
- Input acknowledgement p50/p95/max **125/202/523 ms**; no sampled outgoing queue.
- Video-buffer residence p50/p95 **1.05/1.50 ms**, maximum 20.5 ms, versus 56/67 ms in the preceding build 9 receiver run.
- 16,554 decoded frames, zero decoder-dropped frames; five short freezes totaling 1.486 seconds. This is not a claim of completely stutter-free playback.
- Ten clicks advanced the counter 16→26, mixed-language paste was preserved, and a diagonal title drag moved exactly 50×40 screen pixels. Earlier tests also covered return from the local app menu.

A simultaneous Mini sample (12:42:48.968–12:44:48.968 Moscow) reported mean **56.33 fps**, hardware encoding, no CPU/quality limitation, dispatch p95 **2.04 ms**, and native handling p95 **0.107 ms**. WAIRemote consumed 21.9% CPU in one process snapshot. Other applications continued working; an iOS Simulator started during this run. These are device-specific measurements under the user's existing workloads, not a controlled comparison with AnyDesk.

## TCP fallback on the release binary

Mini build 9 → MacBook universal release build 12, forced relay/TCP, **280 seconds / 558 acknowledgements**:

- Native **3840×2160 H.264**, median **54 fps**, p95 58 fps under the existing background workload.
- Input acknowledgement p50/p95/max **129/205/652 ms**; all sampled outgoing buffers were empty.
- Video-buffer residence p50/p95/max **1.10/18.66/80.97 ms**. TCP has more jitter than the preferred UDP route.
- Five clicks advanced the counter 26→31, mixed-language text arrived intact, and a diagonal title drag moved exactly 70×35 screen pixels.
- Disconnect removed the old frame; a saved-device reconnect produced fresh video in 2.6 seconds.

The TCP-only diagnostic override was removed after this test. It is not a user-facing connection preference.

## Signed update and capture under load

Both devices installed universal build 12 using the real Sparkle download/install/relaunch UI: MacBook from public 0.2.0 (3), Mini from build 9. The installed bundles passed code-signature, notarization and version checks. Saved computers and Mini Screen Recording/Accessibility permissions survived; temporary preview-feed overrides were removed. Ten real clicks advanced the Mini counter 0→10, mixed-language paste arrived intact, and diagonal window drags worked after reconnecting.

This update test exposed a performance gap before publication. During 13:06:35–13:07:35 Moscow, Mini's sender reported median **41 fps**, mean **37.2 fps**, native 4K hardware H.264, no quality-limitation flag, and **70.17 ms/frame** asynchronous encode time. Input and video-buffer latency stayed low. Other applications, including Simulator, remained running. This result does **not** meet the 55-fps median acceptance check.

Three capture surfaces allow only about 33 ms for consumers to release them at 60 Hz. Build 13 uses the supported maximum of eight surfaces and records capture FPS to distinguish capture starvation from later stages. This is a capture surface pool, not an extra receiver playout queue.

The next 206-second UDP run on build 13 restored median **57 fps** in native 4K. Input acknowledgement p50/p95 was **129/206 ms**; one heartbeat reached **1.041 seconds** with a network RTT spike to 670 ms, so this run does not pass the stricter single-sample one-second diagnostic threshold. Click-down p95 was **204 ms**, sampled outgoing buffers stayed empty, and video-buffer p95 was **1.31 ms**. Ten clicks, mixed-language paste and dragging both axes passed. One short video freeze occurred after the first 89 seconds.

A simultaneous Mini sample, 13:26:32–13:27:32 Moscow, confirmed capture median **56.70 fps**, sender median **57 fps**, mean encode time **32.31 ms/frame**, hardware H.264, and no quality limitation. WAIRemote used 21.8% CPU in one snapshot; other workloads remained active.

## Unavailable routes and unfinished connections

A build 13 reconnect also exposed a separate startup failure: Mini returned a signed answer with no ICE candidates, the viewer waited 110 seconds, and a later attempt was rejected as busy. Two native tests using an unavailable localhost TURN endpoint reproduce successful-but-unusable offers and answers on the old code. Both pass after rejecting empty candidate sets.

Build 14 reports the failed route to the viewer, bounds unfinished host connections to 20 seconds, and lets an authenticated retry from the same device replace its unfinished attempt. Established sessions and other devices remain protected. A network timeout no longer incorrectly instructs a saved device to create a new invitation. All **42 Swift tests** pass.

## Final-candidate regression under load

Both Macs installed build 14 through Sparkle. Three disconnect/reconnect cycles recovered the saved Mini session in approximately four seconds; every post-reconnect click incremented the real native counter. Keyboard selection/paste and diagonal dragging passed. Disconnect cleared the old frame.

The complete 490-second sample nevertheless failed the 55-fps median gate: native 4K H.264 delivered median **38 fps** (p95 59), with input acknowledgement **141/228/312 ms** p50/p95/max and video-buffer p95 **3.16 ms**. No sampled input backlog or decoder drops occurred. The Mini sample at 13:42–13:43 Moscow showed capture median **45.88 fps**, sender median **38 fps**, and asynchronous encode time p50/p95 **178/313 ms**. This candidate is not promoted to the stable feed.

A candidate using Apple’s low-latency H.264 rate control is being compared on the actual Mini. Native 4K keyframes, delta frames and forced recovery keyframes decode with the standard WebRTC decoder. Unsupported hardware keeps the existing codec. In a separate synthetic Mini benchmark while the existing remote stream remained active, ordinary VideoToolbox encoding measured p50/p95 **223/239 ms**, versus **31/45 ms** with low-latency rate control. Throughput was 31/29 fps respectively under concurrent encoding; this proves a latency difference, not a 60-fps application result. Thermal state was nominal. The complete remote session must still pass before publication. The final factory also keeps WebRTC’s original encoder for a peer negotiating a lower H.264 level, because Apple’s low-latency mode chooses its own level.

## Low-latency encoder and frame pacing investigation

Builds 15–17 use Apple's hardware H.264 low-latency rate control when the peer negotiates High profile level 5.2. The ordinary WebRTC encoder remains for unsupported hardware and lower negotiated levels. The native regression test encodes and decodes 4K key, delta and forced keyframes with the standard WebRTC decoder, including RTP timestamp wraparound. See [Apple's low-latency VideoToolbox session](https://developer.apple.com/videos/play/wwdc2021/10158/).

Mini build 15, 14:20:52–14:21:52 Moscow: capture p50/p95 **56.11/56.83 fps**, sender **56/57 fps**, encode interval means **17.63/17.80 ms**, low-latency hardware flag true, no quality limitation. Real click, text and drag tests passed. Both Macs subsequently installed build 16 through Sparkle with permissions and saved devices intact.

These builds still fail the smoothness gate. A 56-second receiver sample on build 16 recorded **80 freezes / 14.93 seconds**, despite median 55 fps, no decoder drops and video-buffer p95 4.17 ms. Active `ProcessInfo.userInteractive` assertions did not resolve this. Average FPS alone would have hidden the failure.

Two native UI regressions were reproduced before fixing build 17: `@Published ViewerSession` published every mutating heartbeat/packet call, and an unchanged video surface requested layout again. Sequence bookkeeping no longer publishes; actual host state and mode changes still refresh the UI. Geometry and ink updates now avoid unchanged assignments. Both regression tests pass, but this does **not** by itself remove the network frame gaps.

Build 17 adds opt-in capture and renderer interval diagnostics. MacBook 17 → Mini 16, first 73 measured seconds: median 55 fps, input RTT p50/p95/max **130/265/347 ms**; 63 freezes totaling 11.45 seconds. Renderer measurements confirm actual gaps around 176 ms, not merely a statistics-label problem.

An independent 150-request UDP STUN probe from the MacBook to the public TURN endpoint returned all 150 responses, RTT p50/p95/max **93/174/211 ms**, with 19 responses over 150 ms. Meanwhile Mini's 60-second sample showed encode p95 18.04 ms and packet-send delay p95 0.002 ms. ICMP ping was under 1 ms on both Macs through their existing VPNs; it is not credible evidence of real latency to the remote server. No VPN or network settings were changed. Capture-gap and AnyDesk comparisons remain necessary before choosing the final release.

## Bounded smoothing versus immediate playout

Mini 17, 14:49:40–14:50:40 Moscow: capture median **56.98 fps**, per-second maximum capture gap p50/p95/max **26.27/27.42/42.01 ms**, sender median **55 fps**, encode interval mean p50/p95 **17.81/17.97 ms**. This separates the large receiver gaps from capture starvation.

An 80-ms bounded adaptive playout experiment (viewer 18) delivered native 4K H.264 at median **55 fps**, with input acknowledgement p50/p95/max **126/265/601 ms** during the 357-second snapshot. Video-buffer residence was **35.74/42.56/70.26 ms** p50/p95/max. All ten real clicks, mixed-language paste and a 30×20-pixel title drag passed. There were **15 freezes totaling 3.802 seconds over 353 measured seconds (1.08%)**, zero decoder drops and zero sampled input backlog. This is substantially improved over immediate playout, but narrowly fails the original 1% freeze gate; do not describe it as completely smooth.

The 140-ms experiment (viewer 19) did not demonstrate a useful improvement: its first 160 measured seconds had six freezes totaling 1.763 seconds (1.10%), median 55 fps and video-buffer p95 61.40 ms. Build 20 retains the 80-ms limit. This is a receiver-only change; the control data channel has no added playout delay. A nonzero minimum enables WebRTC pacing; `min=0,max<=500` uses immediate rendering in the pinned implementation. See [WebRTC timing](https://webrtc.googlesource.com/src/+/main/modules/video_coding/timing/timing.cc).

Both devices' independent UDP STUN probes had p95 around **174 ms**. Mini's maximum was **1.203 seconds**, with 150/150 replies. A paired MacBook probe with default versus AF41 DSCP marking gave essentially identical results (p50 ~89.6 ms, p95 ~164.7 ms); no QoS setting was added. Existing VPNs, network settings and unrelated applications were left unchanged.

AnyDesk 9.8.1 is installed on Mini. After the owner entered the system password, both Screen Recording and Accessibility showed **Granted**; Full Disk Access stayed denied. The initial unaccepted request was cancelled; an ordinary session connected after restarting AnyDesk. No unattended password was created. The comparison and its resource-isolation limitation are recorded above; there is no basis for a market-superiority claim.

## Current implementation

Native Retina pixels, 60 fps NV12 capture, H.264 codec preference, a bounded 32 Mbps sender, authenticated UDP relay/TCP fallback, common-mode connection timers, effective system permissions separated from owner approval, and explicit permission return/relaunch guidance. Harmless display notifications no longer close access when the shared display geometry is unchanged.

## Capture lifetime regression

With no viewer connected, Mini build 20 still produced 10 new capture reports over 10.005 seconds (15:38:44–15:38:54 Moscow), at 56.11–56.84 fps. Diagnostics were enabled and PID 76332 was independently confirmed alive; WAI used 22.8% CPU. The device check exited 1 before the change. `scripts/check-idle-capture.py` checks new records only; verify a live diagnostic-enabled host separately before relying on its result.

Build 21 validates Screen Recording while the owner opens sharing, stops that initial probe, and starts a fresh ScreenCaptureKit stream only when a viewer's data channel opens. Disconnect cancels any in-progress start and then stops that specific capture, so a late start cannot survive a disconnect or stop the next session. Native laboratory preview keeps its existing lifetime. The complete 45 Swift tests pass; on-device idle/reconnect verification is required before promotion.

The notarized universal build 21 installed on the MacBook through Sparkle 20→21. Saved computers remained present and the temporary preview override was removed. An immediate automation observation during Sparkle's relaunch opened a second process; it was normally quit and one process remained. Do not count an automation-triggered duplicate launch as a successful single-instance relaunch test.

A clean AnyDesk sample followed closing WAI sharing through the Mini UI. Sixty screenshots over 3.344 seconds all yielded the native test window's timestamp after OCR whitespace normalization. Apparent frame age lower/upper bounds were p50 284/339 ms, p95 414/465 ms, and maximum 420/473 ms. These are short, uncalibrated-clock screenshot observations, not physical click-to-photon latency or a market ranking. AnyDesk used Best quality, Stretch, automatic speed detection and no Preserve details. Its Local keyboard mode preserved uppercase input through computer-use automation; the earlier Auto-mode lowercase result was not a fair test of ordinary human typing.


## Build 21 device verification and 60 ms comparison

Mini installed 20→21 through Sparkle. The live bundle reported build 21, one PID (83431), and diagnostics enabled. Its preview-feed override was removed. With the viewer disconnected, an 8-second grace followed by a 10-second observation found zero new capture reports while the process stayed alive. Two saved-device reconnects produced fresh frames in 4.50 and 4.68 seconds. Ten native clicks, mixed-language text, a 60×40-pixel diagonal drag, and existing permissions/trust passed. Evidence is in `.runtime/mini-build21-{idle,input}-proof.png` and the corresponding device-result JSON.

A 230-second animated UDP run on build 21 delivered median 56 fps, input acknowledgement p50/p95/max 127/262/517 ms, and 0.58% freeze time. Video-buffer p95 was 66.22 ms, failing the original 50-ms gate. This is a continuous animated scene; static desktop intervals and later compilation work were excluded. Sixty screenshot observations over 2.775 seconds yielded apparent frame-age lower/upper bounds of p50 376/419 ms and p95 409/459 ms. The clock and screenshot limitations above still apply, and the AnyDesk and WAI window sizes differed.

Viewer build 22 tested a 60-ms cap against the unchanged Mini 21. The 221-second animated run delivered median 56 fps and acknowledgement p50/p95/max 124/257/558 ms. Video-buffer p95 fell to 22.36 ms, but freeze time increased to 1.10%, failing the original 1% gate. A separate 60-frame screenshot series yielded apparent age p50 325/370 ms and p95 434/484 ms. Lower median age alone does not establish a better experience. Local menu/focus recovery, five native clicks and mixed-language replacement passed. Both MacBook updates completed through Sparkle with one relaunched process, preserved saved computers and removed preview-feed overrides.

The 222-second build 23 run with a 70-ms cap still had a low video-buffer p95 (17.26 ms) and failed the freeze gate (1.19%). It delivered median 56 fps, input acknowledgement p50/p95/max 127/256/290 ms, and zero decoder drops. Sixty screenshots yielded apparent age p50 272/318 ms and p95 372/416 ms. Five further clicks, mixed-language text, drawing/undo and return to control passed. This does not demonstrate consistent smoothness: changing only the upper bound leaves the estimated buffer very small in some sessions.

Build 24 uses a 60–70 ms playout range to retain pacing when the jitter estimator chooses a short delay. Its complete 379.5-second UDP run delivered native 4K H.264, median 56 fps, acknowledgement p50/p95/max 129/260/427 ms (776 samples), and video-buffer p50/p95 27.88/33.22 ms. Ten freezes totaled 3.286 seconds over 378.998 measured seconds (0.87%); all original numerical gates passed for this run. The intermediate 243-second snapshot had 1.07% freeze time: the full result is not a guarantee of uniformly smooth playback. Per-second renderer maximum gap p50/p95/max was 123/141/464 ms, with zero decoder drops. The host remained on build 21 because the change is receiver timing only. Five additional clicks, mixed-language replacement and both directions of a 60×40-pixel drag passed.

A 60-frame/2.922-second screenshot sample on build 24 had apparent age p50 278/327 ms, p95 537/585 ms and maximum 670/720 ms (lower/upper capture bounds). It included a longer stall than the clean AnyDesk snapshot, so neither median improvement nor the passing aggregate gate establishes superiority. TCP and the final Mini update remain required before promotion. The stable feed remains 0.2.0 during these experiments.

The following TCP run ended unexpectedly at 16:38:04 Moscow, after 179.2 seconds. It delivered native 4K H.264 at median 56 fps, decoded 9,979 frames without drops, and accumulated seven freezes totaling 2.182 seconds (1.22% of 178.998 measured seconds), failing the original freeze gate. Five native clicks and mixed-language text worked before the disconnect. The initial portion included a public installer upload/download. Later failed reconnection attempts are excluded from the statistics. Mini was no longer registered for saved-device connections; sleep, lock, network loss and host failure have not yet been distinguished. This is an interrupted, failed run, not a stability pass. Evidence: `.runtime/candidate24-tcp-final.json`, `.runtime/mini-build24-tcp-result.json`, and `.runtime/mini-build24-tcp-disconnected.png`.

## Signaling recovery regression

Separately from the unexplained Mini disconnect, a real loopback WebSocket test reproduced a host failure: closing the signaling socket after authenticated registration invoked permanent access shutdown and never registered again. Build 25 retries transient signaling loss with a 1–8-second backoff while leaving an established WebRTC session intact. Explicit access closure, sleep and lock still cancel recovery. Invalid authentication or relay configuration remain terminal. Existing invitation expiry and trusted-device permissions do not change on reconnection. The sharing view shows when the server connection is recovering.

Five real-socket tests cover re-registration, cancellation, a stale gateway registration, authentication rejection, and invalid relay parameters. Local opt-in diagnostics now distinguish host shutdown causes such as display sleep, screen lock and capture failure without logging screen content, invitations or device identifiers. The complete 50 Swift tests and GitHub CI passed.

MacBook installed build 25 through Sparkle 24→25 with one relaunched process and the saved computers preserved. In the actual signed application, an isolated loopback gateway was stopped during laboratory sharing. The visible UI changed to recovery, and restarting that gateway restored registration automatically. A second outage followed by the owner's Close Access action stayed closed for the following 76 seconds after the server returned. Screenshots and lifecycle evidence are in `.runtime/build25-{recovering,recovered}.png` and `.runtime/build25-native-recovery-result.json`. The loopback server was stopped; the normal public gateway, stable update feed and diagnostics-off state were restored. The Mini remained unreachable, so build 25 installation there and a sustained two-device run remain release gates.
