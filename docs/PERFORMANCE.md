# Responsiveness verification

Work in progress, 12 October 2026. Target: the user's MacBook and **waiMini**, not Mark's Mac.

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

## Mini recovery and build 25 on both devices

The earlier conclusion that Mini was unreachable was incorrect. The dedicated WAI Codex chat had a stale submission, while the existing `openstrudel mini` chat executed fresh commands on waiMini. Its WAI process was alive on build 21 and showed "Сервер подключения недоступен". Reopening sharing through the host UI restored the saved MacBook connection without changing permissions. The available logs do not establish the original outage's cause.

Mini then installed the notarized build 25 DMG through Sparkle 21→25. The installed bundle and one live process were verified, two trusted devices remained, and the temporary feed override was removed. MacBook was already on build 25. With the viewer disconnected, a 10.208-second Mini observation at 21:34 Moscow found zero new capture events and an unchanged diagnostic log while the host process stayed alive. Capture therefore did stop for the isolated AnyDesk comparison.

The continuous animated UDP run lasted 429.5 seconds: native 3840×2160 H.264/VideoToolbox, median 56 fps, 23,819 decoded frames and zero decoder drops. Application acknowledgement p50/p95/max was **124/202/366 ms** over 883 samples; video-buffer p50/p95 was **42.15/47.14 ms**. Sixteen freezes totaled **5.172 seconds over 429.0 measured seconds (1.21%)**, failing the original 1% gate. The largest observed renderer gap was 474 ms. Five native clicks, mixed-language replacement, drawing/undo and saved-device reconnect worked. Later reconnect/setup samples are excluded. Evidence: `.runtime/mini-build25-udp-final.{jsonl,json}`.

AnyDesk was normally restarted on Mini after its UI stopped opening. The incoming request from the known MacBook was accepted through WAI's live screen using the existing session permissions; no unattended password or additional permission was created. WAI's viewer was then disconnected. Five AnyDesk clicks advanced the same counter from 5 to 10, and a 60×40-pixel diagonal drag moved the test window as requested. Best quality, Stretch and automatic speed detection were selected; Preserve details was off. WAI's viewer was subsequently enlarged to the same 2910-pixel displayed desktop width for visual inspection. Text was readable in both clients. These observations do not establish comparative latency, sustained smoothness or superiority.

The following build 25 TCP run lasted 307.6 seconds without a disconnect: native 4K H.264, median 55 fps, 15,442 decoded frames and zero decoder drops. Acknowledgement p50/p95/max was **141/256/836 ms** over 627 samples; video-buffer p95 **48.86 ms**. Eighteen freezes totaled **5.272 seconds over 304.999 measured seconds (1.73%)**; the maximum renderer gap was 504 ms. All numerical gates except freeze fraction passed. Five clicks and exact mixed-language replacement worked. Some horizontal drags near other window edges did not match their requested displacement; this remains under investigation and is not counted as a clean drag pass. Evidence: `.runtime/mini-build25-tcp-final.{jsonl,json}`.

A simultaneous Mini sample at 18:53:38–18:54:38 UTC confirmed capture p50 **56.70 fps**, maximum capture gap **26.83 ms**, and encode p50/p95/max **17.90/18.65/19.07 ms**. Sender FPS fell to p50 **39.5**, with quality limitation reported as `none` in all 60 samples. Maximum interval-average packet send delay was **24.61 ms**. This separates healthy capture/encoding from the transmission/presentation investigation; it does not identify every freeze's cause. The host report is preserved in `.runtime/mini-build25-tcp-host-report.json`.

## Initial viewer size

A native window regression test reproduced the viewer opening at 720×480 despite its requested 1200×780 content size: assigning the SwiftUI hosting controller applied the view's minimum size. Build 26 restores the intended content size after attaching the controller. The regression and the complete 51 Swift tests pass. The change does not alter codecs, transport or the failed smoothness gates above.

MacBook installed the signed/notarized build 26 ZIP through Sparkle 25→26 with one new process and both saved computers retained. The actual viewer opened at 1200×780 points and reconnected to Mini 25. After closing the adjacent AnyDesk window, −240/+40 and +240/−40 pixel title drags returned the test window to its original position. Five clicks advanced its native counter from 15 to 20 and `WAI Remote — связь работает` arrived exactly. Earlier edge-adjacent drag anomalies are not attributed to the input implementation without a reproducible isolated case.

The subsequent 399.4-second UDP observation delivered native 4K at median 56 fps, 21,916 decoded frames without drops, acknowledgement p50/p95/max **119/199/585 ms**, and video-buffer p50/p95 **33.20/44.13 ms**. Ten freezes totaled **3.594 seconds over 395.003 measured seconds (0.91%)**; the largest renderer gap was 486 ms. This observation passes the original numeric gates, while the preceding build 25 runs do not. It included desktop interaction and attempted release uploads; neither this passing sample nor the viewer-size fix proves consistently superior video. Evidence: `.runtime/mini-build26-udp-observed.{jsonl,json}`.

The ZIP and its signed preview feed were publicly downloaded and byte-verified before Sparkle installation. SHA-256: `81d35d31f414a32e196b714b380e5a0676466c199ef0f3a3d13e40d20551a90c`. The app notarization was accepted as `eb6d9bc7-4d36-48d7-bea9-330c8d64aefe`. The separate DMG notarization was accepted as `018d5b58-5812-4e5e-8f07-f17b38b3b208`; the mounted app passed signature and Gatekeeper checks. DMG SHA-256: `7c07f1a409f3676d1dd68386607aa8ecb0d4cecedd3cea842265073630ebbf87`. Publishing that DMG and checking CI encountered independent new HTTPS/SSH connection failures, including GitHub and Apple; the already-established WAI UDP session stayed usable. A completed local installer is not yet a verified public DMG release.

Mini's Sparkle check found build 26, but both its application download and a separate HTTPS download failed. The existing build 25 was normally relaunched (one PID, 22466); the preview-feed override and diagnostic/TCP-only flags were removed. The original two trusted devices and system permissions remained. MacBook build 26 was likewise returned to its normal stable feed with diagnostics off. At 22:32–22:33 Moscow the saved Mini connection reopened without a new invitation or permission prompt. Three real remote clicks advanced the fresh test counter from 0 to 3, and `Mac Mini — доступ восстановлен` arrived exactly. The connected viewer and Mini sharing were left open.

GitHub's initial build 26 check failed only the new window-size assertions: AppKit constrained the window to 1024×642 on the runner's small screen. The test now compares against a plain AppKit window requested at the same 1200×780 size, preserving the hosting-controller regression check while allowing the operating system's screen constraint. The targeted local test passes; the application binary is unchanged by this test-only correction.

Both GitHub checks for `eceb7f7` passed, including Swift, the gateway race tests and the browser viewer build ([PR run](https://github.com/mikwiseman/wai-remote/actions/runs/38168548958), [push run](https://github.com/mikwiseman/wai-remote/actions/runs/38168546481)). Once new network connections recovered, the public [build 26 DMG](https://waiwai.is/remote/downloads/WAI-Remote-0.2.1-26.dmg) downloaded completely with the expected SHA-256 above. Its separate signed [DMG preview feed](https://waiwai.is/remote/updates/appcast-dmg-0.2.1-26.xml) was also downloaded and byte-compared. The landing draft was updated to that installer and rendered in the in-app browser with the correct anchor and no console warnings/errors. These are candidate artifacts; stable promotion still requires consistent video smoothness.

Mini's bounded repeat succeeded through Sparkle 25→26 at approximately 22:41 Moscow. The installed bundle and single PID 24228 were verified before inspecting the UI; both trusted devices and permissions survived. Its preview feed was removed and diagnostics/TCP-only remained off. MacBook was independently verified on 26 with one PID 2252. The saved Mini connection reopened without a new invitation or approval. Three real clicks advanced the reset native counter from 0 to 3, and `WAI Remote 26 — Mac Mini подключён` arrived exactly.

The horizontal-drag anomaly also occurred with local computer-use input directly on Mini: a single title drag from [1040,28] to [784,28] left the window at the same desktop x-coordinate, as independently observed in WAI's live full-desktop view. After closing the adjacent WAI settings and home windows, a remote −240/0 pixel drag moved the test window from x819 to x579; the following +240/−80 drag restored x819 and moved its top from y443 to y363. This is consistent with native window alignment behavior, but it does not establish its exact cause. No input-code change was made based on this observation. The normal connection was left open on build 26 at both ends.

## Display cadence and sparse-desktop stall, build 27

On 12 October, a native regression against the pinned WebRTC framework found that the viewer's `MTKView` requested **30 Hz**, despite a 60-fps capture/received stream. The test failed at 30 versus 60 before the fix. Each new video surface now requests 60 Hz. Earlier received-frame statistics did not prove 60-fps display. WebRTC's [Metal renderer initialization](https://webrtc.googlesource.com/src/+/main/sdk/objc/components/renderer/metal/RTCMTLRenderer.mm) confirms the default; the test checks the actual installed dependency.

The same morning, Mini build 26 froze after 76 encoded/sent frames while its capture reports and approximately 130–210 ms input/heartbeat acknowledgements continued. Clicks and window movement became visible only after reconnection. The host log separates this from capture-pool starvation: sparse capture continued, but encoded frames and video bytes did not advance for about two minutes. Preserved evidence: `.runtime/mini-build26-oct12-full.jsonl`.

A native hardware regression reproduced the custom low-latency encoder dropping seven subsequent 4K updates at a 4-Mbps starting rate, including updates spaced two seconds apart. VideoToolbox reported successful callbacks with the frame-dropped flag. The standard WebRTC H.264 encoder passed the same sequence, so build 27 uses it and removes the custom implementation. The regression now decodes all eight alternating dark/light updates and checks fresh pixels, including the return from sparse to 60-fps timing. This proves recovery at that test rate, not sustained Mini throughput. A proposed `MaxFrameDelayCount=1` setting was unsupported and is **not** part of the fix.

Opt-in, bounded local diagnostics now include batched decode-input, decode-output, renderer-delivery and unique-frame draw-submission timestamps. These contain no pixels or input contents. Draw submission is not physical presentation or click-to-photon latency. The standard encoder's latency and sustained UDP/TCP smoothness still require a fresh two-device run; the stable feed remains 0.2.0 (3).

Build 27 is a signed, notarized and stapled universal candidate. Its isolated Sparkle feed and public ZIP checksum were verified before installation. ZIP SHA-256: `2c10ad37e8aeb19b209f85771b1906849574d5103462f506622848e3a73380b8`. Both Macs installed it; Mini's Sparkle 26→27 update retained permissions and trusted devices.

The 300-second UDP desktop observation at 09:26:42–09:31:42 Moscow delivered native 4K, median 57 received fps and zero decoder drops. Acknowledgement p50/p95/max was 125/201/516 ms. Eleven freezes totaled 3.219 seconds (1.08%); video-buffer p95 was 97.82 ms. Both gates failed. Unique-frame draw submissions averaged 47.74 fps. Host capture and transmission stayed around 57 fps, while available bitrate swung between approximately 0.3 and 32 Mbps. No causal claim about probing follows from this correlation. The visible desktop included settings, and this is not an isolated animation benchmark.

A 120-second TCP observation at 09:21:36–09:23:36 delivered median 57 received fps, two freezes totaling 0.636 seconds (0.53%), and acknowledgement p95/max 207/410 ms. Its video-buffer p95 of 73 ms failed the original 50-ms gate. Stable promotion remains withheld.

Build 28 adds a separate `performanceNetworkTrace` opt-in, effective only with diagnostics enabled. It writes a private, bounded WebRTC event log containing network metadata. Do not publish raw traces. `scripts/summarize-network-trace.py` extracts only congestion/probe numbers, excludes addresses and packet data, and explicitly labels first-in-batch observations without pretending to decode their compressed deltas.

## Clipboard and window control candidates, 28–29

Candidate 28 was installed on both Macs (Mini via Sparkle 27→28). The public ZIP checksum is `ac078eb2f7e0f19aaa88888453e88027b7ac1b44dcf1e262bf392cd1eee70f0b`; notarization was accepted as `7a9c5ead-d3f0-4ecb-8b00-2530f3a1a812`. The stable feed is unchanged. On 12 October at 10:35–10:36 Moscow, native paste delivered mixed Latin/Cyrillic text and an emoji from MacBook to Mini. Appending ` 42` through remote input, selecting and copying on Mini returned the exact 43 UTF-8 bytes to the MacBook clipboard. Image/file device checks are still in progress.

The clipboard uses a separate reliable ordered WebRTC channel, 10-KiB chunks and bounded buffering. Native representations, including formatting and image bytes, are preserved. Copied files/folders carry bytes and are materialized locally; remote file paths are not treated as local files. The limit is 100 MiB/2,048 entries; symlinks and special files are rejected. Received file backing is bounded to three transfers. Concealed pasteboard contents are not exported. A connection does not automatically send a clipboard that predates it. Control permission, an active connection and an unpaused session are required. Permission loss/disconnect cancels pending transfers. Explicit Paste snapshots the clipboard before asynchronous file work and waits for a receiver acknowledgement before sending Command-V. Tests cover late/local-copy races and echo prevention.

The loopback WebRTC clipboard integration test is opt-in with `WAI_NETWORK_TESTS=1`: this Mac's firewall blocks inbound traffic to xctest. It was attempted and failed to establish ICE, so it is not counted as an integration pass. Native two-device verification is required regardless of unit-test results. Build 28 passed 62 local tests, with that one network test skipped.

Candidate 29 adds an owner-selected window capture and process/window-targeted input. This is a shared macOS login session, with a shared clipboard, not two independent desktops. It uses private window-location SPI at runtime, following the attributed MIT references; unavailable SPI disables the option. It never falls back to global HID input for a selected window. Owner PID/window checks stop stale routing, and geometry changes invalidate queued coordinates. Real foreground/background behavior across native and browser apps is still a release gate; some apps/dialogs may require activation.

## Native clipboard and background-window observations, 12 October

On build 28, copying a 640×360 PNG on Mini and creating a document from the MacBook clipboard preserved all 12,401 bytes (SHA-256 `feb088951b0eee028f36aedadfc89b3e734c3209dae2ce7a531ae758a169c066`). Rotating the unsaved test document on MacBook and copying it back produced the expected image in Mini Preview; the 8,084-byte PNG matched `15fbc10b432085f2877b997024e11f7f2b69de63c269a39b1cf75a58ea9ecee4`.

Real Finder paste also preserved a 1-MiB file from Mini to MacBook (`77b502b9f17f1608d72ac55f06c5a57c1a89c6bcdb905b9bba9592930a36fae0`) and a 2-MiB file from MacBook to Mini on build 29 (`1e075c8d478ad21844e33e830a695ef03a4d2488b69ee275bd8947618bb1be1e`). The second receiver pasteboard contained both WAI and Apple Universal Clipboard markers. These are native paste/integrity results; the transport must be distinguished before attributing every delivery solely to WAI. Build 31 adds opt-in transfer UUID/byte-count send, receive and acknowledgement records, without clipboard contents or paths.

Copying our test file from the repository under Documents triggered macOS's Documents-folder permission prompt. File transfer can require that permission; screen viewing/control and inline text/image representations do not require it. File snapshots now retain AppKit's native file URLs and balance security-scoped access, following Apple's [pasteboard reading guidance](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/PasteboardGuide106/Articles/pbReading.html). Folder-purpose strings explain copied-file transfer. This does not bypass denied permission or establish that macOS will never show a prompt.

The build-28 300-second UDP observation delivered 3840×2160 H.264/VideoToolbox, median 56 received fps and zero decoder drops. Four freezes totaled 0.800 seconds over 298.999 measured seconds (0.27%); acknowledgement p50/p95/max was 117/201/356 ms. Video-buffer p95 was 62.63 ms, still failing the original 50-ms gate. Unique-frame draw submissions averaged 49.60 fps. This included clipboard/desktop activity and was not an isolated animation benchmark. The host trace showed repeated bitrate probes and a low-bandwidth estimate near one freeze; that correlation does not establish a cause. Candidate 31 trials skipping probes when the estimate is already above 80% of the configured maximum. Device evidence is required before retaining this trial.

On build 29, Mini's 680×608-point native test window was captured at only 680×608 pixels despite its Retina display. Build 31 requests a 2×, best-resolution window capture, including after resize, following Apple's [window-capture sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos). The configuration regression failed before the change and passes afterwards. Build 31 subsequently delivered 1360×1216 pixels for that 680×608-point window, confirmed by viewer RTC statistics and the rendered image.

Between 11:18:50 and 11:19:40 Moscow, a 5-Hz Mini sampler recorded TextEdit as the actual foreground process in all 250 samples and an unchanged physical pointer while remote text arrived exactly in the background WAI test window. Six button clicks nevertheless left its counter at zero. Sampling cannot exclude shorter-than-200-ms foreground changes, and this is not a complete background-control pass. Candidate 31 uses the standard accessibility Press action for a button in the selected window; other controls retain process/window-targeted input. It does not add a global-input fallback. Native and external-application device tests remain required.

The signed, notarized universal build 31 ZIP has SHA-256 `4aad363ebe81a99f8c2822a71358e3d459c37b740efbb17c8869bd10aa0b3913`; notarization was accepted as `e86c2b53-87fd-4687-99cf-eac273575f7d`. Its isolated preview feed and ZIP were byte-verified over public HTTPS. Stable remains 0.2.0 (3). The latest focused regression run passed 16 tests with one explicitly skipped network test.


## Build 31 results and build 32 candidate

On build 31, five background native button clicks still left the counter at zero. An immediate text entry lost the initial `Mini ` prefix. A 5-Hz sampler observed TextEdit remaining foreground and a stationary physical cursor during those inputs; this is not a background-control pass. Build 32 moves ordered native input off the AppKit main loop and searches only the selected window's bounded accessibility tree for standard button Press actions. Session release invalidates pending and in-flight lookups. The new cancellation regression passes. Device verification remains required; polling cannot exclude brief focus/cursor changes between samples.

A build-31 Finder copy showed why file-paste success alone was insufficient: the MacBook's outgoing transfer had no corresponding receive/acknowledgement on Mini. Instead, Apple Universal Clipboard delivered the file and Mini relayed it back under a new WAI transfer UUID. The final native paste hash was correct, but that direction was not proven to traverse WAI. Build 32 ignores Handoff-origin copies and marks received WAI contents with AppKit's `currentHostOnly` preparation option, preventing another automatic Handoff broadcast. A failing asynchronous echo regression now passes. System Handoff preferences are unchanged. Device tests use owned temporary fixtures with `currentHostOnly` for a single controlled copy, then native Paste, and correlate WAI transfer UUIDs at both endpoints.

The 12:50:48–12:55:48 Moscow build-31 observation used native 3840×2160 H.264/VideoToolbox over UDP, with the animated Input Test foreground on Mini. Median receive FPS was 57; 16,851 frames decoded, zero decoder drops. Input acknowledgement p50/p95/max was 134/200/590 ms; video-buffer p95 was 49.85 ms. Five freezes totaled 3.903 seconds over 298.999 measured seconds (**1.31%**, failing the original 1% gate). A roughly 2.9-second gap appeared at decoder input, output, renderer and draw submission. Mini capture stayed near 57 fps while outbound FPS fell to 3–8 and packet-send delay accumulated. Evidence: `.runtime/build31-full-udp.{jsonl,json}`; this is not physical click-to-photon latency.

The probe-skipping experiment did not establish a benefit and was removed. WebRTC's [screen-share ALR defaults](https://webrtc.googlesource.com/src/+/main/rtc_base/experiments/alr_experiment.cc) use a 2875-ms pacer queue; the default string and experiment key are also present in the pinned M153 binary. Its [video send stream](https://webrtc.googlesource.com/src/+/main/video/video_send_stream_impl.cc) applies that queue limit to screen content. Build 32 retains the default congestion/probing settings but trials a 100-ms queue (`WebRTC-ProbingScreenshareBwe=1.0,100,80,40,-60,3`). This is a queue-draining target, not a guaranteed network latency ceiling. Resolution, capture cadence and bitrate ceiling are unchanged; repeated live runs must establish the result.

Build 32 passed 68 local Swift tests with one explicitly skipped firewall-dependent loopback test. Its signed/notarized universal ZIP has SHA-256 `e74fc098ef1035e738f0e7ddf6241f85172cdd65b8ecdfc9c103e33f67480205`; notarization `0298919d-ee48-4bdf-97c3-de25392a9544` was accepted. The immutable preview feed and ZIP were byte-verified over public HTTPS. Stable remains 0.2.0 (3).


Build 32's first background button Press crashed on Mini. The crash report identifies SwiftUI's main-actor assertion in `AccessibilityNode.accessibilityPerformPress`, called from `is.wai.remote.input`: same-process AX calls execute synchronously on the caller's thread. Build 33 inspects and invokes our own accessibility elements on the main thread, retains off-main AX for foreign applications, and rechecks session cancellation where the action executes. A regression reproduced the wrong-thread action before the fix; all 69 local tests now pass, with one network test skipped. This failure is not a video transport failure.

In full-desktop mode, build 32 delivered five real clicks (counter 0→5). Computer-use `typeText` omitted Cyrillic and emoji in both WAI and a plain local AppKit text field; the source diagnostics show only 12 UTF-16 units submitted, matching the received 12. This does not demonstrate Unicode loss in transport. Unicode device testing uses native Copy/Paste of controlled fixtures and keeps this automation limitation explicit.

Build 33's immutable signed/notarized ZIP has SHA-256 `ca89423481b9796d21a49872947aa89cd3a488e511708d8002957651adc6e101`; notarization `a01fddad-8edd-486d-a013-9ad8659998db` was accepted. Public preview ZIP/feed were byte-verified over HTTPS. No stable promotion.

## Build 32 full-desktop failure and build 33 native input

The planned 13:24:37–13:29:37 Moscow build-32 UDP run terminated early. Its 286 measured receiver seconds delivered native 4K H.264/VideoToolbox, median 57 fps and zero decoder drops, but 36 recorded freezes totaled 10.830 seconds (**3.79%**). The terminal interval with no new frames may not be included in WebRTC's completed-freeze counter. Input acknowledgement p50/p95/max was 169/289/1082 ms; video-buffer p95 was 45.72 ms. This fails both the original freeze and maximum-input gates. Unique-frame draw submissions averaged 43.06 fps. Neither Mac performed test GUI actions, installs or compilation during the interval.

Mini capture remained near 57 fps, with a worst reported capture gap of 30.30 ms; its WAI process remained alive after the viewer closed. In the private network trace, bidirectional ICE checks ended around 13:29:07, followed by outgoing checks without responses until the session ended. No explicit owner stop was found. This supports investigating the network path, but does not establish which link failed. The public TURN service was running; its 40-Mbps per-session limit exceeded the configured 32-Mbps sender ceiling. The 100-ms screen pacer trial has **not** established a sustained smoothness benefit. Evidence: `.runtime/build32-full-udp.{jsonl,json}` and `.runtime/mini32-final-summary.json`.

Both Macs installed build 33. At 13:39:49–13:39:51 Moscow, five remote clicks in the selected native test window advanced its counter exactly 0→5. Immediately clicking its field and entering `Mini33 background input 123` preserved the entire string; the host did not crash. Across 65 samples spanning the action and a surrounding margin, TextEdit stayed the actual foreground process and the physical pointer stayed at one position. The sampling interval was 200 ms, so shorter changes are not excluded. The selected 680×608-point window arrived at 1360×1216 pixels. This passes the observed native-window scenario; external-application controls, resize/close boundaries and simultaneous human work still need their own verification. Evidence: `.runtime/native33-input-proof.json` and `.runtime/native33-foreground-cursor.jsonl`.

## Build 33 clipboard verification without Handoff

All six controlled transfers passed actual native paste on 12 October: text with Cyrillic/emoji, a PNG, and a 2-MiB file, in both directions. The owned QA app copied each source with `currentHostOnly`; the OS Handoff setting was unchanged. Each transfer has matching WAI send/receive/acknowledgement UUIDs in `.runtime/clipboard33-bidirectional-proof.json`. Text appeared exactly in ordinary AppKit fields. Preview opened the expected 640×360 image in both directions; its 12,328 PNG bytes matched SHA-256 `cbdd2ba42a79781f7566eaea6b1d0208e1f704fb94a280dbe0a56d8327e633a8`. This QA image differs from the earlier build-28 fixture. Finder pasted the full 2,097,152 bytes in both directions, matching `1e075c8d478ad21844e33e830a695ef03a4d2488b69ee275bd8947618bb1be1e`.

MacBook→Mini text acknowledgement took about 198 ms and PNG about 613 ms. The file took 14.56 seconds; Mini→MacBook file took 14.17 seconds. These prove data integrity and delivery, not satisfactory bulk-transfer speed. Fixtures were in owned temporary directories, so these tests do not prove a Documents-permission-denial flow. The earlier Documents prompt remains relevant only for copied files from that protected location.

Background keyboard shortcuts remain a distinct failure: in the selected native WAI test window, Command-A did not select existing text and Command-V did not paste, while ordinary ASCII input arrived. The same native keyboard tool successfully selected/pasted in a local AppKit field. An uninstalled build-34 modifier-transition experiment was deferred after the next test found a concrete addressing defect; the working implementation retains the previous keyboard event sequence.

## Selected-window coordinate regression, candidate 35

The build-33 external Chrome fixture failed five clicks and text entry: its counter stayed zero, its input stayed empty, and spaces scrolled the page. Wheel scrolling worked. During 50 samples around the attempted input, TextEdit stayed foreground and the physical cursor stayed fixed. Thus isolation alone did not establish usable control.

A metadata regression exposed a vertical reflection: screen point (250,420) in window (100,200,800,600) was stamped as (150,380). Candidate 35 changed this to the top-left local point (150,220), based on [KWWK coordinate conversions](https://github.com/EYHN/kwwk-computer-use-core/blob/main/Sources/KWWKComputerUseCore/CoordinateSpaces.swift). That test verified the stamped value, not WindowServer routing; the subsequent Chrome field test still failed. Native button AX Press bypasses this coordinate path. Keyboard events also received inappropriate mouse-location stamps; a separate assertion verifies they remain unchanged after PID/window addressing.

Candidate 35 trials top-left local pointer coordinates and applies mouse fields only to pointer/scroll events. All 12 focused native input/view tests pass. The deferred modifier experiment is absent. On-device browser clicks, native shortcuts and resize/close checks are still required.

Both Macs installed 35, with Mini upgrading 33→35 through Sparkle and retaining its trusted devices and permissions. ZIP SHA-256: `8b5ff407a67f216852eb887c89995c08280d40cc821d937c23248952f62dbc7d`; notarization `36e91ee6-937a-429a-a0bb-b1c511b820be` was accepted. At 15:16:32–15:16:33 Moscow, three background Chrome button clicks advanced 5→8 and wheel scrolling revealed sections 3/4. In all 55 surrounding 5-Hz samples, ChatGPT remained foreground and the physical pointer stayed fixed. This confirms those actions, not complete simultaneous control. Clicking Chrome's input still failed to focus it; Tab focused it and ordinary text arrived. Native menu Paste remained ineffective in that background field. Evidence: `.runtime/browser35-input-proof.json`.

The automation also dropped Latin letters in an ordinary local AppKit field (`Reset35` became `35`), matching the viewer's submitted-text counts. This particular loss occurs before network transport and must not be counted as remote text corruption. Text verification continues through controlled native Copy/Paste. The viewer's Edit > Select All was independently disabled because its responder action was missing; a failing regression covers that menu action.

Candidate 36 trials one SkyLight PID delivery for pointer events, following [cua-driver's background mouse path](https://github.com/trycua/cua/blob/main/libs/cua-driver/rust/crates/platform-macos/src/input/mouse.rs), with no global input or application-activation fallback. It also restores the standard Select All responder action. Device tests must confirm focus and isolation; keyboard event sequencing is unchanged.

The clipboard's two-chunk pump could stall on its 250-ms poll when a channel accepted messages immediately and emitted no buffer-decrease callback. A 2-MiB regression reproduced that delay. The pump now yields to the main queue and continues only after a successful bounded batch; transport backpressure still stops it. Separate assertions cover backpressure and permission loss before a queued continuation. All 73 local tests completed with zero failures and one explicitly skipped loopback test. Real file-transfer timing remains to be measured on 36.


## Build 36 file timing and candidate 37 background focus

The standard Edit > Select All menu is enabled in the installed build 36. Background Chrome field clicks and menu Paste still failed; the SkyLight post alone did not establish correct focus. Candidate 37 follows the current [cua-driver screen-point routing](https://github.com/trycua/cua/blob/main/libs/cua-driver/rust/crates/platform-macos/src/input/skylight.rs): `CGEventSetWindowLocation` receives the screen point and WindowServer performs the local conversion. It also sends the target-only window focus record before a pointer-down, without a defocus record to the owner's app or a global front-process/cursor operation. Cancellation and window ownership are checked again after the focus settling interval. The coordinate assertion failed before this correction; all 73 local tests completed with zero failures and one explicit loopback skip. Native focus, owner's keyboard focus, pointer isolation and external-app shortcuts remain device gates.

The immutable build-37 preview ZIP/feed were publicly downloaded and byte-verified. ZIP SHA-256: `31a66c1583f326e45d1b7fd648f9f67ed2455c7e464059911057a0680c6ba1f8`; notarization `b69c735c-c113-469e-9ace-2a94793998b1` was accepted and stapled. This is a candidate, not a stable release.

Build 36 repeated the owned 2-MiB fixture in both directions, with native Finder Paste and the expected SHA-256 on both receivers. MacBook→Mini transfer `F39BDB01-AED4-4712-971A-61F6534AF7EC` took **5.957 seconds** from send to acknowledgement (12:30:19.977–12:30:25.934 UTC). Mini→MacBook `78FEF7FC-6F52-4C5C-A3FE-9ACC236DFD12` took **14.666 seconds** (12:33:47.767–12:34:02.433 UTC). The reverse direction has not improved versus 33; the pump regression fix must not be described as a consistent two-direction speedup. Each file contains 2,097,152 bytes, hash `1e075c8d478ad21844e33e830a695ef03a4d2488b69ee275bd8947618bb1be1e`. Local events are in `.runtime/clipboard36-local-events.json`; Mini proof is in its owned `wai-remote-build36.90mqfa8n` stage.


The build-36 full-desktop observation ran 12:37:48.511–12:42:48.511 UTC on 12 October. It completed without disconnect: native 3840×2160 H.264/VideoToolbox, median 56 received fps, 16,437 decoded frames and zero decoder drops. Heartbeat acknowledgement p50/p95/max was **117.7/194.7/268.5 ms** (600 samples); these are not click-to-photon measurements. Two completed freezes totaled **0.462 seconds over 299.003 seconds (0.15%)**. Video-buffer p95 was **57.54 ms**, failing the unchanged 50-ms gate. Unique-frame draw submissions averaged **46.45 fps**, so received FPS alone still overstates display cadence. The viewer used a TURN/TCP allocation; the host retained its ordinary UDP/TCP candidate configuration. Calling this a forced TCP path on both endpoints would be incorrect. No test GUI actions, installs, builds or uploads ran during the measurement interval. Evidence: `.runtime/build36-full-tcp.{jsonl,json}` and `.runtime/mini36-full.jsonl`.

## Build 37 UDP result and candidate 38 background gesture

The 13:05:11.652–13:10:11.652 UTC build-37 run completed over TURN/UDP with native 3840×2160 H.264/VideoToolbox. All unchanged automated gates passed: median 56 received fps, acknowledgement p50/p95/max **118.5/200.5/271.6 ms** (599 heartbeats), video-buffer p95 **47.93 ms**, and four completed freezes totaling **0.876 seconds over 299.003 seconds (0.29%)**. The 15,694 decoded frames had zero decoder drops. This is one passing observation, not proof of sustained superiority to another product. Average decode/render delivery was 52.50 fps and unique draw submissions only **45.11 fps**. No test GUI actions, builds or uploads ran during the interval. Evidence: `.runtime/build37-full-udp.{jsonl,json}`, `.runtime/mini37-full.jsonl`.

Immediately afterwards, two full-desktop remote clicks advanced the native test counter 0→2 and clicking its field then entering `37` displayed both characters. Selected-window Chromium input had failed earlier on 37: three clicks left its counter 8→8, and pointer focus plus `37` left its field unchanged. All 254 surrounding WindowServer samples kept foreground/key-focus PID 23422 and the same physical pointer; the largest sampling gap was 49.96 ms. This confirms observed isolation, not working background input. Evidence: `.runtime/browser37-input-proof.json` and `.runtime/browser37-window-isolation.jsonl`.

Candidate 38 adds cua-driver's complete Chromium activation gesture before the actual pointer-down: target-only focus, a target move, and an offscreen down/up primer with shared gesture group and explicit phases. There is still no global cursor/front-process fallback. Regressions cover phase metadata and preservation of the gesture group; they do not prove application behavior. Its signed/notarized ZIP is `0fd91988b89fa014cd7d02827307d9d0132fcc5fe5e9e280e903abf08a711d90`, notarization `9a91844a-12b2-4cfb-b2dd-4288c1512d80`; public preview ZIP/feed were byte-verified. On-device validation remains required.

A five-second build-37 MacBook profile before the benchmark found substantial main-thread work in WebRTC's I420 renderer uploading and compressing three Metal textures. The pinned macOS [RTCMTLNSVideoView](https://webrtc.googlesource.com/src/+/refs/heads/main/sdk/objc/components/renderer/metal/RTCMTLNSVideoView.m) converts every incoming native buffer to I420 and redraws its retained frame at every timer tick. Candidate 39 trials Apple's [AVSampleBufferDisplayLayer](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer) with the existing decoder pixel buffer and immediate presentation, without an application-side frame queue. Software-decoded I420 remains supported. A failing display-path regression and zero-copy/color-plane tests pass; live visual, performance and lifecycle validation are still required. New `display-enqueue` records measure submissions, not physical presentation; `display-metrics` records retain AVFoundation's own dropped/corrupted-frame counts separately.

## Build 38 DOM coordinates and candidate 40

Mini installed 38 after its computer-use helper recovered from a confirmed `ENOSPC` error. Only our reproducible old app bundles/archives were removed; backup 28, preferences and proof files were retained. MacBook installed 39. Reconnecting to the restarted Mini succeeded, and the selected 2400×2012 Chrome window rendered with the new native display path.

At 13:29:43.160–13:29:44.913 UTC, three clicks left Chrome's counter 0→0 and field entry stayed empty. The diagnostic page now received actual DOM mouse events: clicking the displayed input produced `click HEADER 937,201` instead of approximately `475,171`. The error is exactly the selected window's desktop origin `(462,30)`. Thus the complete primer made the event observable, but build 37's screen-space window stamp added the origin twice on these devices. Candidate 40 retains the screen-space `CGEvent.location` and separately stamps top-left window-local coordinates. This supersedes the earlier inference from cua-driver's implementation; the DOM measurement is the actual device evidence. The coordinate regression failed before the correction and passes after it.

Across 149 WindowServer samples around that action, foreground and key-focus PID stayed 23422 and the physical pointer stayed fixed; maximum sampling gap was 53.41 ms. This is still not a complete independent-control pass. Evidence: `.runtime/browser38-input-proof.json`, `.runtime/browser38-window-isolation.jsonl`. Candidate 40's focused input/clipboard/view run executed 25 tests, with one explicit loopback skip and zero failures. Native video-policy/view tests separately passed all 17 cases on 39.

Build 39's signed/notarized universal ZIP is `04b12ef0d5f953133776d10ef58651a05ec5844ca41236aa44876ba6ce2c0062`; notarization `48b94940-504e-4836-a0a1-c65446818cc9` was accepted. Its public preview ZIP/feed were byte-verified. Stable remains 0.2.0 (3).

## Build 39 native presentation and build 40 window input

With viewer 39 and host 38, the 13:37:14.208–13:42:14.208 UTC run completed over TURN/UDP at 3840×2160, H.264/VideoToolbox. All unchanged gates passed: median 55 received fps; heartbeat acknowledgement p50/p95/max **122.8/205.7/338.6 ms**; video-buffer p95 **45.49 ms**; six completed freezes totaling **1.429 seconds over 299.000 seconds (0.48%)**. There were 14,880 decoded frames and zero decoder drops. AVFoundation separately reported **14,861 presented frames over 298.701 seconds (49.75 fps), zero dropped/corrupted frames**, and the application skipped none. Average decoded delivery was 49.78 fps. The new display path kept pace with those frames; it does not establish continuous 60-fps capture or optical click-to-photon latency. The scene was the native input fixture with its clock and moving bar, not full-screen motion. No test actions, builds, installs or uploads ran in the interval. Evidence: `.runtime/build39-full-udp.{jsonl,json}`, `.runtime/build39-native-display.json`, `.runtime/mini38-during39.{jsonl,json}`.

A five-second profile before that run no longer contained the previous three-plane Metal uploads; 2,035 of 2,334 sampled main-thread stacks were idle in Mach-port waiting. Sampling percentages are not CPU-utilization percentages. The first frame after connection was visibly coarse before sharpening, so first-frame quality is still a separate concern.

Build 40's signed/notarized universal ZIP is `3c78c5fed6a7e3c910af0bc20047d91e58253cf0e465bd82b753e0f8656a15c9`; notarization `8b98ef46-be7f-47e8-962f-1b22f0cf2798` was accepted and stapled. Public preview ZIP/feed bytes were verified. Both Macs installed 40, with Mini permissions, identity and trusted devices retained.

At 13:52:18.392–13:52:20.279 UTC, three background Chrome clicks advanced its counter exactly 0→3, and clicking the field then entering `40` displayed both digits. All 156 surrounding WindowServer samples kept foreground/key PID 23422 and the same physical pointer; maximum sampling gap was 60.01 ms. The first immediate Select All/typing sequence appended instead of replacing; after another pointer focus, Select All visibly selected the full field and typing replaced it with `42`. Native Paste then appended the exact controlled Cyrillic/emoji fixture, and scrolling revealed sections 3/4. This passes these observed background actions but does not yet prove continued keyboard isolation during another person's activity. Evidence: `.runtime/browser40-input-proof.json`, `.runtime/browser40-window-isolation.jsonl`.
