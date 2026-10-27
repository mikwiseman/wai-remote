# Responsiveness verification

Work in progress, 15 October 2026. Video comparisons use the user's MacBook and **waiMini**. The update requested for Mark's Mac is a separate installation task.

## Direct routes before the relay, 26 October

Every session went through the Helsinki relay, even with both Macs on one home LAN (5 ms apart). From that LAN a UDP STUN round trip to the relay took a median **230 ms** from the MacBook and **124 ms** from the Mini. Both Macs run the Wai B2B VPN as their default route. It sends Russian addresses directly and everything else through an exit that geolocates to Tel Aviv, so relay traffic travelled Moscow → Tel Aviv → Helsinki and back. Public STUN servers in Moscow answered in 16–23 ms over the same tunnel, and Helsinki reaches the home ISP edge in 20.5 ms. A relay path is two such legs. The production-relay session benchmark on the MacBook measured RTT p50/p90 **458/551 ms** and input round trip p50/p95 **441/624 ms**, with both ends on `relay/udp/vpn`.

Skipping VPN adapters in WebRTC (`ignoreVPNNetworkAdapter`) was tried first and rejected: under a VPN that captures all routes, only the tunnel reaches the internet, so the offer kept no relay candidate and the session failed with no route. Apps that advertise `iceVersion: 3` instead gather on every interface and remove host and reflexive candidates on loopback or VPN tunnels from their one signed SDP. Relay candidates always stay. In one process against the production relay, the filtered offer kept the LAN and relay candidates and ICE selected the direct host pair (RTT 1 ms). A two-Mac LAN session needs both apps updated and has not been measured yet. Sessions across different networks still use Helsinki through the VPN exit. Two levers remain: leave the relay address out of the VPN tunnel (about 30 ms per leg expected), or run a relay inside Russia (about 10–15 ms per leg).

## Published 0.2.1 (50), 15 October

At the owner's request, build 50 is now the latest public [GitHub release](https://github.com/mikwiseman/wai-remote/releases/tag/v0.2.1) and the update offered by the [main Sparkle feed](https://waiwai.is/remote/updates/appcast.xml). The previous main-feed item was 0.2.0 (3); builds through 49 were published only in separate preview feeds. That explains why a 0.2.0 installation using the main feed had no newer version to find.

The signed, notarized universal DMG is 20,099,899 bytes, SHA-256 `5ea833dd405e1582daa0368c25accf02a9c719b96553206814ada4d6d25487da`. Apple accepted notarization `94c88c43-ef7d-43f6-9ba2-6b6c0a1a17d0`; stapling, the mounted application's signature and Gatekeeper checks passed. The published main feed matches the verified signed file byte for byte, retains the original feed URL and public key, and the installed MacBook's Sparkle accepted its signature. GitHub's public assets report the same DMG and ZIP hashes as the local archives.

The MacBook completed the real Sparkle 49→50 download, install and relaunch. The installed executable matches the candidate, saved computers remain present, and the temporary preview-feed override was removed. Two identical app processes appeared after an automation read during relaunch; they were stopped and one process was opened. This is not evidence of an independently verified single-launch update. The installed interface displays 0.2.1 (50) and «Без ограничения по времени». Its synthetic sharing test was closed afterwards. Mark's installation remains deferred at the owner's request; no update on that Mac is claimed.

The public browser viewer was also updated. Its HTML, JavaScript, CSS, icon and manifest match the built artifacts byte for byte. Previous hashed assets were retained, and the gateway was not restarted. Its connection form rendered without console errors; a new remote session was not established for this publication check. Clicking the live landing page's download button saved the exact signed DMG. Evidence: `.runtime/build50-public-viewer.json`, `.runtime/build50-public-viewer.jpg` and `.runtime/build50-browser-download.json`.

This publication does not establish consistently smooth video or superiority to AnyDesk. The failed sustained-video gates and the unverified simultaneous two-person desktop scenario below remain open. Release evidence is in `.runtime/build50-{dmg-artifact,installed,main-channel,github-release}.json` and `.runtime/build50-main-channel-sparkle.log`.

## Invitation duration, candidate 50

The ten-minute limit applied to an unused invitation, not to a connected session or a saved computer. The owner requested invitations without a time limit. Candidate 50 removes the invitation expiry and keeps the link usable while access stays open. Closing access, replacing the invitation and first approval still revoke its pairing secret. A previously approved computer reconnects using its saved public identity, without that secret.

The regression test advances invitation housekeeping by a year and then submits a freshly signed connection request using the original link. It failed before the change because the link disappeared, and passes afterwards with the request waiting for owner approval. Separate tests confirm that closing access and replacing a link invalidate the previous invitation. No wall-clock or system permission changes are needed for these tests.

Validation: 105 Swift tests completed with zero failures and one explicit network-integration skip. Go race tests and the browser production build passed, and npm reported zero vulnerabilities. The update requested for Mark's Mac is prepared separately because the owner asked to defer installation while the computer is in use.

## Installed build 49 and update restoration

On 14 October, Mini completed Sparkle 47 to 48 and then 48 to 49. Before the second update full-screen access was open. After relaunch the Mini task observed **«Доступ открыт» without a manual sharing start or application launch**. The executable hash, Developer ID signature and Gatekeeper checks passed. Peers and TCC permissions were unchanged and the temporary preview-feed override was removed. The handoff key was absent after launch; its transient write and the boot-session value were not independently sampled. Evidence: `.runtime/build49-mini-autorestore.json`.

MacBook completed Sparkle 47 to 49, retained its saved computers, and connected to the Mini's automatically reopened display. Remote WAI menu and Settings actions succeeded. A later broad network failure interrupted further input verification: concurrent requests from MacBook to the WAI health endpoint, GitHub and Apple timed out. The app connection also closed. These failures do not establish that Mini stopped sharing, and the final reconnection after the outage was not verified before interruption. Evidence: `.runtime/build49-installed.json` and local network diagnostics.

Both preview packages were independently downloaded and matched the signed local archives. Build 48 is 18,103,791 bytes, SHA-256 `6ac9038b14884ab31742d0b222f5a99aece11340e4fae984a87468e9e58f4da3`; build 49 is 18,103,771 bytes, SHA-256 `87e1b8b01b78cedb4aaea57eae647d2b62493102a844dea7c2e2f296cea545b4`. Both are universal and require macOS 15 or newer. Stable remains 0.2.0 (3).

## Update handoff, candidate 48

The updater now saves an already-open sharing target at Sparkle's actual relaunch termination. The next higher build consumes that intent once, within five minutes and in the same unlocked login session. A selected window retains its process, launch date and window identity; it cannot turn into whole-screen sharing. Closed access, an unchanged/downgraded build, a reboot or login-session change, and an expired intent do not reopen access. Ordinary app launches remain unchanged. This is an update handoff, not unattended access or login-screen support.

Validation before packaging: **102 Swift tests, 101 passed, one explicit network-integration skip**, zero failures; Go race tests and the web production build passed. Five new tests cover the handoff and Sparkle delegate lifecycle. Actual **48→49** installation is required to verify the old process writes the handoff and the new process restores it; installing 48 from 47 alone cannot prove that behavior. The web build's transitive development dependency `source-map-js` was updated from 1.2.1 to 1.2.2 after npm audit reported GHSA-68fv-2mgg-jv7q; the rebuilt viewer passes and the new audit reports zero vulnerabilities.

## Mini recovery and both-device build 47 verification, 14 October

SSH and the existing Mini Codex task became reachable again. WAI Remote 46 was installed but not running. The reason it had stopped is unconfirmed; Mini had rebooted earlier that day, which alone does not establish the cause. Starting its existing application and opening screen access restored the MacBook connection. The application is in the Mini user's Applications folder, not the system Applications folder.

Mini then completed the actual Sparkle **46→47** download, installation and relaunch. The installed executable matches the notarized candidate, strict code-signature and Gatekeeper checks pass, and its temporary preview-feed override was removed. Identity, trusted devices and macOS permissions were retained. Screen access was reopened manually after installation. This exposed an updater lifecycle gap in build 47: it does not restore that previously open access. Evidence: `.runtime/build47-mini-installed.json`.

With both devices on 47, three remote clicks advanced the owned native counter exactly 0→3. An ordinary local TextEdit copy containing Cyrillic, Latin, emoji and punctuation pasted into the Mini field. After adding ` 47` on Mini, Copy and native Paste into a new MacBook TextEdit document preserved all **169 UTF-8 bytes**, SHA-256 `72f2ae671c1f4b606a34232121549a7c6cce7c79887492ca72dc145a3ea690a8`. Matching WAI send/receive/acknowledgement IDs at both endpoints establish that these transfers traversed WAI. Send-to-ACK took **254 ms forward and 234 ms back**, measured on each sender's own clock. They are not optical latency measurements. Evidence: `.runtime/build47-both-roundtrip.{txt,json}` and `.runtime/mini47-clipboard.jsonl`. The earlier user-confirmed OpenRamble test remains the live microphone evidence; it was not repeated on 47.

Today's devices share an IPv4 subnet, while the actual WAI sessions use the public TURN service through their existing VPN interfaces. This is not a fresh separate-network test. The opt-in same-machine WebRTC clipboard integration test was also retried and still failed to establish ICE; it is not counted as passed or attributed conclusively to the firewall. Log: `.runtime/build47-network-retest.log`.

## Build 47: sustained native 4K UDP observation

The **13:22:34.401–13:27:34.401 UTC** observation used the built-in native clock/moving-bar fixture in macOS full screen. This is a sparse animation, not motion across the whole screen. Both endpoints independently reported **relay/UDP** and native 3840×2160 H.264/VideoToolbox. AnyDesk was disconnected, other workloads were unchanged, and no test GUI actions, builds, installs or uploads ran during the interval.

| Measurement | Result |
| --- | --- |
| Received fps median / decoded frames | 58 / 17,212 |
| Decoder drops | 0 |
| Input ACK p50 / p95 / max | 224.766 / 370.450 / 862.118 ms, 599 heartbeats |
| Network RTT p50 / p95 / max | 222 / 355 / 435 ms |
| Video-buffer p50 / p95 / max | 31.992 / 80.829 / 85.678 ms |
| Completed freezes | 49, 10.571 / 299.003 seconds (**3.54%**) |
| Decode-input / display-enqueue largest gap | 741.896 / 726.072 ms |
| Host capture median / largest gap | 57.595 fps / 34.443 ms |
| Host input queue p95 / max | 1.536 / 2.884 ms |

The unchanged smoothness gates **failed**. AVFoundation separately counted 17,221 displayed frames over 299.614 seconds (57.477 fps), with zero dropped/corrupted frames. Interval RTP counters recorded 18,341 received packets, no net packet loss and no additional NACK, FEC or PLI packets. Capture remained substantially steadier than receiver delivery. These observations locate the large gaps downstream of capture but do not isolate network delivery from WebRTC timing. No packet loss does not imply steady packet arrival. Median video traffic was about 0.194 Mbit/s for this sparse scene. Evidence: `.runtime/build47-native-udp{,-observation}.json`, `.runtime/build47-native-udp.jsonl`, and `.runtime/mini47-native-udp.{jsonl,json}`. Frame-timing batches can include samples just before the exact observation boundary; RTC interval totals and native display deltas are reported separately.

The matching **13:44:32.441–13:49:32.441 UTC** run verified **relay/TCP at both endpoints** and kept the same 4K clock/bar scene. It received median 58 fps and decoded 16,617 frames without drops. There were 24 completed freezes totaling **5.512 / 299.004 seconds (1.84%)**. ACK p50/p95/max was **181.300 / 534.757 / 854.797 ms**, with 600 samples; video-buffer p50/p95/max was **89.589 / 121.456 / 233.987 ms**. Network RTT p95 was 533 ms. Native display deltas counted 16,617 frames over 299.446 seconds (55.492 fps), without drops or corruption. RTP counters showed no additional lost packets, NACKs or PLIs. Host capture median was 57.740 fps, its largest source gap was 148.941 ms, and input-queue p95 was 1.035 ms.

TCP reduced completed-freeze time in this observation but increased buffer residence and the upper input-latency tail. It also **failed** the unchanged gates and does not justify forcing TCP in production. Both diagnostic overrides were removed after measurement. Evidence: `.runtime/build47-native-tcp{,-observation}.json`, `.runtime/build47-native-tcp.jsonl`, and `.runtime/mini47-native-tcp.{jsonl,json}`. No test actions, builds, installs or uploads ran during the interval; local source edits did not change the installed applications.

## Build 46: pasteboard stalls and actual clipboard round trip

A real ordinary-text paste on build 45 froze the MacBook viewer for about nine seconds and did not reach the Mini. A process sample located 5,399 main-thread samples in `MacViewerModel.paste → ClipboardSync.pushCurrent → ClipboardContent.snapshot → NSPasteboardItem.dataForType`, waiting on a lazy pasteboard provider. This stopped video/UI work and heartbeats long enough to invalidate remote control. In an isolated AppKit fixture, reading the same 85-byte plain-text representation took 7,471 ms synchronously and 7.8 ms on the clipboard worker. These are individual diagnostic observations, not throughput benchmarks.

Explicit Paste now materializes representations on the existing serial clipboard worker. It remembers the pasteboard change count and rejects a replacement made before materialization completes; a later copy cannot silently replace the requested insertion. The main thread remains free for video and input. The slow-provider regression failed before the fix (508 ms blocking versus a 100 ms bound) and passes afterwards. A second regression covers owner replacement, and the existing test verifies that already-captured contents survive a subsequent copy.

The signed, notarized universal build 46 was installed on the MacBook through the real Sparkle 45→46 download/install/relaunch flow. The installed bundle passed strict code-signature and Gatekeeper checks. The temporary preview-feed override was removed and the saved Mini connection reopened successfully. The initial clipboard round trip below used Mini build 45 sharing TextEdit. Mini subsequently completed the same Sparkle 45→46 update, passed strict signature/Gatekeeper checks, retained trusted devices, and reopened full-screen sharing. Its preview-feed override was also removed. Direct bundle replacement over SSH was denied by macOS App Management; the standard updater completed the installation without changing that protection.

In that connection, the formerly failing ordinary paste appeared in the Mini document. Paste-request-to-transfer-ACK was **212 ms** (89.5 ms before send, 122.5 ms send-to-ACK); this is not click-to-photon latency. A second mixed Russian/English/emoji paste appeared intact. Selecting and copying the resulting document on Mini delivered the exact 328 UTF-8 bytes back to the MacBook; a real Paste into local TextEdit and a saved-file comparison also matched. A clipboard change from concurrent local activity invalidated an earlier measurement; that measurement is not counted as a clipboard failure or success.

After both Macs updated to 46, actual Paste into the selected Mini TextEdit window and Copy/Paste back into local TextEdit preserved all **156 UTF-8 bytes**, including Cyrillic, Latin, line breaks and emoji. Both saved files matched SHA-256 `5e0c6ff76c9f2305094255efd3264ee78cc02248830d4d2bd77fd4aa2361e13e`. The user also confirmed that live OpenRamble dictation appeared on Mini. That is a user-observed microphone test; no exact dictated transcript or microphone recording was independently captured. Evidence: `.runtime/build46-both-roundtrip.{txt,json}`.

Validation: **94 Swift tests, 93 passed, one explicit network-integration skip, zero failures**; Go race tests and the browser production build passed. The opt-in same-machine WebRTC test still fails to establish its connection and is not claimed as passed. A read-only firewall inspection found incoming access explicitly blocked for the Xcode `xctest` binary; that configuration was not changed, and no successful control test establishes it as the sole cause. Both GitHub CI runs passed; the push run initially timed out on the last frame of the sparse 4K encoder test and passed on retry. Five additional local repetitions of that test passed; this does not explain the initial timeout.

Candidate ZIP: [WAI-Remote-0.2.1-46.zip](https://waiwai.is/remote/downloads/WAI-Remote-0.2.1-46.zip), 18,054,308 bytes, SHA-256 `09ac4ed5b13f58b852aa32e68d2c6dee3b8b38b655b96de7a706bd06b9c8db37`. Signed [preview appcast](https://waiwai.is/remote/updates/appcast-0.2.1-46.xml) and ZIP signatures were verified; public downloads matched the local files byte-for-byte. Notarization: `aa9cd2ea-74b5-46d2-97f2-04a6cc3ce10e`. The stable appcast remains 0.2.0 (3). Local proof is in `.runtime/build46-device-clipboard.json`, `.runtime/build46-roundtrip.txt`, and `.runtime/paste45-main-thread.sample.txt`.

## Build 46: five-minute video run and AnyDesk comparison

On 13 October at 16:06:43.102–16:11:43.102 UTC, both installed build-46 Macs ran the owned native clock/moving-bar fixture over **relay/UDP at both endpoints**, with 3840×2160 H.264/VideoToolbox. AnyDesk was disconnected. Other Mini workloads continued; this scene is not full-screen motion. The 300-second observation contained 299.001 seconds of RTC deltas:

| Measurement | Result |
| --- | --- |
| Received fps median / decoded mean | 56 / 56.157 |
| Decoded frames / decoder drops | 16,791 / 0 |
| Input ACK p50 / p95 / max | 116.350 / 208.570 / 564.405 ms, 610 samples |
| Network RTT p50 / p95 / max | 114 / 192 / 272 ms |
| Video-buffer p50 / p95 / max | 50.874 / 66.933 / 91.444 ms |
| Completed freezes | 17, 3.231 seconds, **1.08%** |
| Render gap p50 / p95 / max | 16.688 / 33.275 / 225.810 ms |
| Host capture median / largest gap | 56.603 fps / 70.202 ms |
| Host input queue p95 / max | 0.096 / 7.074 ms |

The unchanged freeze and video-buffer gates **failed**. No multi-second input backlog was observed. Capture was steadier than receiver delivery, but this does not isolate every transport/decoder cause. RTP counters increased by 23 net lost packets, 15 NACKs and 3,205 received FEC packets; most freeze intervals had no simultaneous increase in lost packets. These interval counters do not establish the cause of individual freezes. Evidence: `.runtime/build46-motion-udp.{jsonl,json}`, `.runtime/mini46-motion-udp.{jsonl,json}`, and the exact observation bounds in `.runtime/build46-motion-udp-observation.json`.

AnyDesk 9.8.1 was inspected with Best quality, the same 3840×2160 Mini and the same displayed window dimensions. Five actual clicks reached the native counter. Its connection details displayed `direct_443`; WAI used TURN. The AnyDesk session closed after roughly 3–4 minutes with `anynet_unknown`, so there is no completed equivalent five-minute comparison and no confirmed cause for that closure. After disconnecting WAI, a ten-second check found zero new capture reports while its host process remained alive.

Short clock-image samples used 60 CUA screenshots per client and an independent SSH clock calibration (minimum round trip 4.656 ms; Mini clock about 94.928 ms behind MacBook). Corrected apparent lower-age p50/p95 was 29/45 ms for AnyDesk and 75/109 ms for WAI. However, screenshots themselves took median 73 ms versus 211 ms, respectively; the samples lasted 4.407 versus 13.659 seconds. They cannot establish comparative sustained frame rate or physical click-to-photon latency. Evidence: `.runtime/{anydesk,wai}46-frame-age-summary.json`, `.runtime/clock-offset46.json`. Stable promotion remains blocked on consistent smoothness and a sustained equivalent comparison.

The later TCP/TCP attempt started at 16:46:18.737 UTC, with both relay allocations independently verified. Only 16.619 seconds of viewer logs were captured before the MacBook entered **Clamshell Sleep at 16:46:34 UTC**, as confirmed by its power-management log. The next diagnostic entry arrived about 594 seconds later during a maintenance wake. This is an interrupted observation, not a completed 300-second TCP result and not evidence that Mini went offline. The 17 available RTC samples already contained five completed freezes, but they are too short for the sustained comparison. Evidence: `.runtime/build46-motion-tcp.{jsonl,json}`, `.runtime/build46-tcp-interruption.json`.

After waking, MacBook was on a different local network and could no longer resolve `waiMini.local`; WAI nevertheless reconnected through the public internet service. The viewer's fresh statistics confirmed relay/UDP, and real remote Terminal actions worked. The TCP-only diagnostic preference was removed on Mini through that session at 17:21:54 UTC; it had already been removed on MacBook. The owned Motion QA fixture was closed. Other applications and system dialogs were left alone.

## Viewer recovery after MacBook sleep

The interruption exposed a separate lifecycle issue: the viewer did not retain an intention to resume an established session across MacBook sleep. The next candidate observes Apple's [workspace sleep](https://developer.apple.com/documentation/appkit/nsworkspace/willsleepnotification) and [wake](https://developer.apple.com/documentation/appkit/nsworkspace/didwakenotification) notifications. Before sleep it releases the old session and stale frame; after wake it starts the existing authenticated connection flow for that same pinned computer. It retains neither pending input nor the original pairing secret. An unfinished pairing request is cancelled. Explicit Disconnect or closing the viewer cancels resumption, and duplicate wake notifications do not create duplicate attempts.

Three notification-driven regressions cover established/idle/pending sessions, cancellation and target identity even if another invitation was edited meanwhile. They reproduced the failure before the correction; all 25 focused viewer, window and timer tests pass. A full repeat passed **96 tests with one explicit network-integration skip**. The first full run failed an existing test that compares the actual desktop pointer before and after event addressing: it moved about 17 pixels during the test. Event addressing does not post an event or warp the pointer. The focused repeat and full repeat passed without changing the test; external pointer movement is the likely explanation, not a proven product regression. Both logs are retained in `.runtime/build47-tests{,-recheck}.log`.

Universal candidate 47 passed strict code-signature and Gatekeeper checks and Apple notarization (`79c4c9c8-2bd0-4545-9c7a-a73822397421`). The [stapled ZIP](https://waiwai.is/remote/downloads/WAI-Remote-0.2.1-47.zip) is 18,058,403 bytes, SHA-256 `063531d4d5817b851eb5b321696b3e23c8bb7a395130fa2947e2d45132d65deb`. Its [preview appcast](https://waiwai.is/remote/updates/appcast-0.2.1-47.xml) and archive signatures passed verification; public bytes matched the local files. MacBook completed the actual Sparkle 46→47 installation and relaunch. Its installed executable matches the staged candidate, strict signature/Gatekeeper checks pass, saved computers remain present, and the temporary feed override was removed. Evidence: `.runtime/build47-installed.json`. These are application lifecycle tests, not a second physical lid-close/wake test.

During the subsequent reconnection check, the gateway returned `unavailable` for Mini. The public health route and both `wai-remote-gateway` and `wai-remote-turn` services were healthy. Mini's Codex host RPC was unavailable, its configured SSH name could not resolve from the MacBook's current network, and SSH to its last verified LAN address closed before login. AnyDesk remained at “Please wait for the remote side to accept your session request.” No command or click was delivered on Mini in this recovery attempt. Its last verified version remains 46; the cause of its stopped sharing is unconfirmed. The host intentionally stops sharing on sleep/lock, but those code paths alone do not prove which event occurred on Mini.

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

With viewer 39 and host 38, the 13:37:14.208–13:42:14.208 UTC run completed over TURN/UDP at 3840×2160, H.264/VideoToolbox. All unchanged gates passed: median 55 received fps; heartbeat acknowledgement p50/p95/max **122.8/205.7/338.6 ms**; video-buffer p95 **45.49 ms**; six completed freezes totaling **1.429 seconds over 299.000 seconds (0.48%)**. There were 14,880 decoded frames and zero decoder drops. AVFoundation separately reported **14,861 frames over 298.701 seconds (49.75 fps), zero dropped/corrupted frames**, and the application skipped none. Average decoded delivery was 49.78 fps. The new display path kept pace with those frames; it does not establish continuous 60-fps capture or optical click-to-photon latency. The scene was the native input fixture with its clock and moving bar, not full-screen motion. No test actions, builds, installs or uploads ran in the interval. Evidence: `.runtime/build39-full-udp.{jsonl,json}`, `.runtime/build39-native-display.json`, `.runtime/mini38-during39.{jsonl,json}`.

A five-second profile before that run no longer contained the previous three-plane Metal uploads; 2,035 of 2,334 sampled main-thread stacks were idle in Mach-port waiting. Sampling percentages are not CPU-utilization percentages. The first frame after connection was visibly coarse before sharpening, so first-frame quality is still a separate concern.

Build 40's signed/notarized universal ZIP is `3c78c5fed6a7e3c910af0bc20047d91e58253cf0e465bd82b753e0f8656a15c9`; notarization `8b98ef46-be7f-47e8-962f-1b22f0cf2798` was accepted and stapled. Public preview ZIP/feed bytes were verified. Both Macs installed 40, with Mini permissions, identity and trusted devices retained.

At 13:52:18.392–13:52:20.279 UTC, three background Chrome clicks advanced its counter exactly 0→3, and clicking the field then entering `40` displayed both digits. All 156 surrounding WindowServer samples kept foreground/key PID 23422 and the same physical pointer; maximum sampling gap was 60.01 ms. The first immediate Select All/typing sequence appended instead of replacing; after another pointer focus, Select All visibly selected the full field and typing replaced it with `42`. Native Paste then appended the exact controlled Cyrillic/emoji fixture, and scrolling revealed sections 3/4. This passes these observed background actions but does not yet prove continued keyboard isolation during another person's activity. Evidence: `.runtime/browser40-input-proof.json`, `.runtime/browser40-window-isolation.jsonl`.

The following interleaved check retained the selected remote field while the Mini operator entered `1234567890` into a separate local AppKit window at 13:59:50.661–13:59:50.702 UTC. At 14:02:47.024–14:02:47.079 UTC, remote typing replaced Chrome's selected value with `43` without another pointer focus. The Mini operator then verified that the local field still contained exactly `1234567890`. This establishes the observed separation of those two applications, not sustained concurrent work by two people. Evidence: Mini stage-40 `owner-input40.json` and `ready-motion40.json`.

## Full-screen motion on build 40

The previous clock/bar fixture did not exercise motion across the whole screen. The new owned Chrome fixture scrolls text and rotates a color pattern across the native 3840×2160 capture. Its local animation reported 59 fps and p95 source gaps of 17.3–17.6 ms. The following clean 300-second observations used this same scene without builds, uploads or GUI actions during the measurement:

| Interval (UTC, 12 October) | Actual viewer / host relay | Received fps median / mean | ACK p95 / max | Buffer p95 | Completed freezes |
| --- | --- | --- | --- | --- | --- |
| 14:09:37.844–14:14:37.844 | UDP / UDP | 57 / 57.23 | 205.8 / 664.4 ms | 58.54 ms | 23, 5.866 / 299.000 s (1.96%) |
| 14:17:15.333–14:22:15.333 | TCP / UDP | 44 / 44.29 | 251.7 / 942.6 ms | 108.30 ms | 18, 4.539 / 298.997 s (1.52%) |

Both runs fail the unchanged release gates. The UDP run decoded 17,115 frames with no decoder drops; AVFoundation counted 17,115 frames, zero drops/corruption, and one application-side readiness skip. There were 737 net lost RTP packets out of 230,242 received, with 275 NACK reports. Mini capture gaps stayed below 46.4 ms while the receiver had gaps up to about 679 ms. These observations locate the larger pauses downstream of capture, but do not isolate every network/decoder cause. ACK remains a protocol round trip, not optical input-to-display latency.

The supposed TCP test was not TCP at both ends: the viewer honored `performanceTCPOnly`, but `PeerTransport` on the host ignored it. Candidate 41 applies the existing opt-in diagnostic filter to the host too. A device-route assertion fails on the mixed build-40 run; both ends must report their selected TCP relay allocation before a subsequent run can be labeled TCP/TCP. Default routing is unchanged. Evidence: `.runtime/build40-motion-{udp,tcp}.{jsonl,json}`, `.runtime/build40-motion-udp-display.json`, `.runtime/mini40-motion-{udp,tcp}.{jsonl,json}`, `.runtime/build41-tcp-red.log`.


## Candidate 41: TCP verified at both endpoints

The signed/notarized universal ZIP is `dcfb2be2ca4ecf29687a3808f25d09048bbb48662ef0b6c01e25f1dd1c6810f9`; Apple accepted `e0896669-9d5a-4d5e-b9c7-f95c8e67b43e`, and the public preview ZIP/feed were byte-verified. Mini installed 41; the viewer remained 40 because the correction affects only hosting. The separate route assertions now pass with actual TCP relay allocations on both devices. Three ICE-gathering regressions pass.

The 14:39:25.717–14:44:25.717 UTC full-screen motion run passed all unchanged gates: native 4K/H264/VideoToolbox; median 56 received fps; ACK p50/p95/max **118.7/208.6/661.9 ms**; buffer p95 **46.00 ms**; three completed freezes totaling **0.624 seconds over 298.999 seconds (0.21%)**. It decoded 16,823 frames without decoder drops. AVFoundation counted 16,811 frames over 298.902 seconds (**56.24 fps**) with zero drops/corruption and three application readiness skips. The longest display-enqueue gap was 231.23 ms. Capture median was 56.30 fps, maximum source gap 67.84 ms, and encode wall time p95 49.69 ms. This passing run supports a TCP experiment on this route; it does not establish that forcing TCP is better for every network. Normal route selection is unchanged.

Evidence: `.runtime/build41-motion-tcp.{jsonl,json}`, `.runtime/build41-native-display.json`, `.runtime/mini41-motion-tcp.{jsonl,json}`, `.runtime/build41-tcp-green.log`. No builds, uploads or GUI actions ran in the five-minute interval. Measurements of ACK, display metrics and optical latency remain distinct.

## Build 42: full-screen motion, UDP and clipboard interference

At 16:34:46.805–16:39:46.805 UTC on 12 October, both Macs ran build 42 over the unchanged relay/UDP route. The 4K/H.264/VideoToolbox scene delivered median 57 fps and about 57.25 displayed fps, with no decoder drops. Six completed freezes totaled 1.463 of 299.001 seconds (0.49%). This passes the freeze gate but fails the complete release check: buffer p95 was 72.515 ms, and heartbeat ACK p50/p95/max was 148.353/348.527/10,567.494 ms.

Three 1,446,760-byte clipboard sends began near 16:36:43–46. The Mini's matching trace has no arriving heartbeats from 16:36:46.280 to 16:36:59.004, followed by 26 events in 370 ms, while video continued. Its input dispatch p95/max was 0.43/3.26 ms; capture median was 57 fps, with a maximum source gap of 239 ms. The candidate pair did not change. These observations suggest contention before input dispatch, including SCTP queuing; they do not prove a particular main-thread stall or establish optical latency. FlexFEC was enabled, but useful FEC traffic was not established by the observed counters.

Evidence: `.runtime/build42-motion-fec-udp.{jsonl,json}`, `.runtime/build42-gates.log`, `.runtime/build42-native-display.json`; Mini's matching report is `benchmark-1791822886.805472-1791823186.805472/README.md` in its build-42 temporary stage.

## Candidate 43: bound clipboard data awaiting delivery

An immediately draining SDK buffer can still feed an arbitrarily long SCTP queue. Both SCTP streams share congestion control ([RFC 8831](https://www.rfc-editor.org/rfc/rfc8831.html)); a separate clipboard channel alone therefore does not isolate input latency. Candidate 43 advertises a 20 KiB receive window and requires byte acknowledgements before sending more. Legacy peers remain compatible with the previous protocol. Invalid credit, stale transfer IDs and permission loss cannot extend the window.

The regression test first failed with about 1 MB queued without a receiver acknowledgement, then passed with a 20,480-byte bound. Automatic unsupported copies no longer show persistent status text; an explicit Paste still reports a failure and never pastes stale remote content. The complete native test run passed 77 tests with one explicit loopback skip. This is code-level evidence; real clipboard transfers and concurrent input still require verification on two updated Macs.

Build 43 is an arm64 candidate, signed, notarized (`f8a9f9f9-9dd5-4135-aaa0-808780f9308d`) and stapled. Its public preview ZIP SHA-256 is `9f3d8116dbb5c3eb1a92f7152d15dd6f850e88569d485ef6d23d587e2879ae8b`; the downloaded ZIP and preview feed were byte-verified. The stable appcast and landing remain at 0.2.0 (3).

During the MacBook-43/Mini-42 check, an ordinary 641-byte TextEdit copy at 19:29 UTC was sent but not acknowledged and explicit Paste timed out. Synthetic Latin typing under a Russian local input source omitted letters; physical keys and typing after selecting the Latin source worked. These are separate observations, not a clipboard pass. The Mini update instruction was delivered through the existing WAI session at 19:31 UTC.

## Build 43: full-screen motion after both devices updated

The 19:48:21.128–19:53:21.128 UTC run on 12 October used build 43 on both Macs, native 3840×2160 H.264/VideoToolbox and the viewer's UDP relay. The owned Chrome motion scene reported 59 source fps. An unrelated keychain dialog covered part of the scene and was left untouched; this is not an identical unobstructed AnyDesk comparison. No builds, uploads or GUI actions ran during the timed interval.

Received video had median 57 fps. AVFoundation counted 17,050 frames over 299.374 seconds (56.952 fps), zero dropped/corrupt frames and two application readiness skips. RTP decoded 17,031 frames without drops. Fifteen completed freezes totaled 3.209 of 299.005 seconds (1.07%); buffer p50/p95/max was 40.252/54.580/67.864 ms. Both freeze and buffer gates failed. Heartbeat ACK p50/p95/max was 128.211/241.392/581.136 ms across 600 samples; input gates passed. Network RTT p50/p95/max was 125/232/252 ms. Median video bandwidth was 15.53 Mbit/s. This run does not establish sustained smoothness or AnyDesk superiority.

Evidence: `.runtime/build43-motion-udp.{jsonl,json}`, `.runtime/build43-gates.log`, `.runtime/build43-native-display.json`. The existing Mini chat subsequently reported matching host trace results: median capture 57 fps, maximum capture gap 27.5 ms, unchanged UDP relay, RTT p95 254 ms, 600 heartbeats with maximum arrival gap 632 ms, and dispatch queue p95/max 5.14/12.83 ms. Its report is `/private/tmp/wai-remote-build43.9a7rkxcq/benchmark-20261012T194821Z-195321Z/README.md`; raw host output has not been copied locally. The later trace stop is consistent with the diagnostic file size cap, not proof of an app stall.

## Candidate 44: clipboard, dictation and modifier regressions

The user reported that image paste worked while copied text and locally dictated text displayed “Это содержимое нельзя вставить на другой Mac.” OpenRamble's `HostOnlyPasteboard` marks dictated and explicitly copied text with `ConcealedType`, `TransientType` and `AutoGeneratedType`, then briefly exposes it for Command-V before restoring the previous clipboard. WAI treated that history/privacy marker as a prohibition on explicit insertion. The [NSPasteboard convention](https://nspasteboard.org/) distinguishes confidential/temporary content from ordinary copy history; it does not identify an unsupported text format.

Candidate 44 reads concealed plain text synchronously when Paste is explicitly invoked and sends it through the authenticated text-input channel. It does not export that text into the remote clipboard or file cache. Automatic clipboard synchronization still ignores concealed contents. This also avoids losing dictated text when its source restores the clipboard shortly after Command-V. Ordinary rich text, images and files retain their clipboard transfer path. The marker regression failed before the correction and passes afterwards, including unchanged source clipboard ownership and an ordinary restored clipboard.

Native text input previously discarded an entire dictation over 4,096 UTF-16 units; browser paste truncated it. Both now send bounded ordered packets without splitting surrogate pairs. A long Russian/English/emoji AppKit input regression first delivered zero packets, then delivered the complete text through valid host input messages. The view continues to implement Apple's [NSTextInputClient](https://developer.apple.com/documentation/appkit/nstextinputclient) insertion path. This is text-dictation compatibility, not microphone or audio-device forwarding.

A separate binary clipboard regression used 30,000 bytes of `0xff`: JSON slash escaping made valid base64 chunks exceed the 16 KiB message limit. Disabling unnecessary slash escaping keeps each chunk within the existing limit; the failed transfer now completes exactly. Content-free transfer diagnostics distinguish readiness, receiver invalidation, decoding and timeout without recording clipboard contents or paths.

Actual Control-Up navigation on Mini exposed a stuck Control modifier. Native `flagsChanged` transitions were not sent, and pointer events inherited the previous injected keyboard flags. Candidate 44 sends left/right modifier transitions, includes current flags with native/browser pointer events, stamps them on host mouse/scroll events and releases synthetic shortcut modifiers. Regressions cover Control-Up-release, both Shift keys held, modifier clicks and menu shortcuts.

The native suite passed 85 tests with one explicit loopback-network skip; the browser production build passed. The opt-in local WebRTC clipboard integration was also attempted separately and failed to open its data channels within ten seconds; this is an unresolved integration result, not evidence of a firewall cause. Code-level results do not replace the pending build-44 device clipboard, dictation and sustained-video checks. Evidence: `.runtime/{modifiers44-red,dictation44-red,dictation-markers44-red,clipboard-binary-red,build44-tests,build44-real-webrtc}.log`.

Build 44 is a signed, stapled arm64 candidate. Apple accepted notarization `141b97c7-0076-47f1-9c83-313584f68949`; Gatekeeper assessment and strict code-signature verification passed. The public ZIP SHA-256 is `477afbb14d1d00d9bee88d524bd3c5b61641c8a9196e13e91a711666c5ebf44c`; ZIP and versioned Sparkle feed were downloaded and byte-compared. Stable remains 0.2.0 (3).

On 13 October the MacBook updated 43→44 through the real Sparkle download/install/relaunch flow. The installed bundle reports build 44, the new process is PID 18101, and strict signature/Gatekeeper checks pass. Saved Mini and Mark entries remain visible. The temporary preview-feed preference was removed after the update.

## Candidate 45: clipboard startup and application reopening

Build 44's viewer repeatedly received a clipboard hello while its outgoing transfer stopped after 20,480 bytes and timed out. Its first hello had been accepted by the data channel before the host enabled clipboard permission. The host ignored that early packet, but the viewer treated the successful send as a completed handshake and did not reply to the host's later hello. Candidate 45 confirms the first received hello even if it already sent one. The regression recreates that exact ordering, checks that the exchange terminates, and verifies text transfer in both directions using isolated pasteboards. It failed before the correction.

The native suite ran 92 tests: 91 passed, one network-dependent test was explicitly skipped, and none failed (`.runtime/build45-tests.log`). This does not resolve the earlier opt-in WebRTC integration failure. Candidate 45 also restores the existing session on application reopen, adds native Hide and local window shortcuts, and declares Russian localization for system-provided UI. Window/device evidence is recorded in [INTERFACE-REVIEW.md](INTERFACE-REVIEW.md).

Build 45 is signed, notarized and stapled; notarization `1c3e8481-5801-459b-81db-e572c6a10f32` was accepted. The 17,340,915-byte ZIP has SHA-256 `63a5803b74be3317e66efe6f768c412b7bd6aef1b172ec6e5282882f1ae16a5a`. Its immutable public ZIP and signed versioned appcast were downloaded and byte-compared. The MacBook completed the actual Sparkle 44→45 download/install/relaunch flow; installed build 45, PID 26235, passed strict code-signature and Gatekeeper checks. The temporary feed override was removed. Mini's existing Codex chat reported build 44, PID 26300, with its existing permissions and identity retained. No build-45 Mini installation is claimed.

With the build-45 viewer and build-44 Mini, the hello loop stopped. A controlled 184-byte text transfer was sent at Unix time 1791875051.9165 and acknowledged at 1791875052.04753, about 131 ms. That confirms protocol delivery, not insertion in a selected remote field. Subsequent GUI verification was interrupted by concurrent Mini work and two transport disconnections. Explicit text, OpenRamble insertion, PNG/file transfer, a new sustained video run and an equivalent AnyDesk comparison remain unconfirmed for this candidate pair. The stable feed remains 0.2.0 (3).

### Both Macs on build 45, 13 October

Mini subsequently installed the same verified build 45 candidate and retained its identity, saved peers and permissions. The MacBook viewer (PID 82387) connected to Mini (PID 3276) through the public service. Tests used owned AppKit fixtures, TextEdit and Finder, with real Copy/Paste actions through the viewer.

- Ordinary mixed Cyrillic/Latin text and emoji appeared in Mini TextEdit. The corresponding clipboard acknowledgement took 130 ms; this is not optical input latency.
- Explicit Paste of fixture text carrying OpenRamble's concealed, transient and autogenerated pasteboard markers also appeared exactly in Mini TextEdit. Live microphone recognition and OpenRamble's own insertion command remain a separate, unfinished check.
- Text edited on Mini and copied back matched the complete local AppKit field value, including a newline and the added digits.
- A 640×360 PNG appeared in the remote TextEdit document. Mini independently verified the saved RTFD attachment against the original SHA-256, `cbdd2ba42a79781f7566eaea6b1d0208e1f704fb94a280dbe0a56d8327e633a8`.
- Finder Copy on the MacBook, immediately followed by Paste in Mini Finder, created the 2 MiB test file. After reconnecting following a MacBook lock, the renamed return copy was copied again on Mini and pasted into the final local Finder folder. Finder displayed `mini-return-45.dat`, and the saved file matched byte-for-byte: 2,097,152 bytes, SHA-256 `1e075c8d478ad21844e33e830a695ef03a4d2488b69ee275bd8947618bb1be1e`. The forward transfers took 24.48 and 28.53 seconds; the reverse transfers took 22.69 and 32.77 seconds. This is functional delivery, not fast bulk transfer.

An earlier delayed file-paste attempt coincided with another clipboard change, so it is not counted. During the first 2 MiB transfer, 49 input acknowledgements had p50/p95/max 193/371/575 ms. During other mixed desktop activity a 2.4-second acknowledgement and visible compression blocks were observed. This was not a controlled motion benchmark: unrelated Mini work changed the scene. Sustained video, real OpenRamble dictation and a fair AnyDesk comparison still block promotion. Local evidence is in `.runtime/build45-device-clipboard.json` and the content-free PID 82387 performance log.

### Offline host signaling correction

With relay credentials enabled, an authenticated viewer for an absent host was rejected with the same policy close used for a duplicate identity or server capacity. The native app consequently displayed a generic connection error. The gateway now sends the existing `unavailable` message before a normal close, without issuing relay credentials or reserving a viewer slot. A regression failed against the previous behavior and the gateway race suite passed after the fix. An authenticated probe using a fresh test identity reproduced the old close code 1008 on production before deployment. This does not change host authorization or remote-control permissions.

The gateway from `dfab476` was deployed with the previous executable retained for rollback. Its SHA-256 is `28ac5db850c7092aa2e2cb4c9e755ffba0680690ad054d14a90a032276a63b45`. The same public WSS probe then received exactly `unavailable` with no relay credentials, and public health remained healthy. GitHub's push and PR workflows both passed Swift, Go race tests and the browser build. The native stable appcast remains unchanged.

## Independent pointer latency, 18 October 2026

The installed build 61 host was observed during the owner's MacBook session, without reconnecting it. The 15:25–15:39 UTC interval retained native 3840×2160 H.264/VideoToolbox, median 57 sender fps, and interval-average encode p50/p95 42.58/48.84 ms. Host input dispatch p50/p95/max was 0.59/408.59/499.26 ms. Native delivery p95 was 180.01 ms, with one 675.72-ms down event; the existing background-window activation sequence alone deliberately waits about 166 ms. Selected TURN/UDP RTT p50/p95/max was 148/318/1026 ms. These are separate stages, not an optical input-to-display measurement.

The next Mac build moves the owner's independent pointer as a vector layer inside a stationary transparent panel. Display hover no longer moves/redraws a backed AppKit window or synchronously checks its WindowServer visibility on each packet. The panel stays nonactivating and ignores local input; a native test verifies that geometric input lookup continues below it to the intended window.

New Mac viewers also advertise `localPointer` inside their signed offer. For this capability only, the host leaves its blue independent pointer visible to the owner but excludes that overlay from the video. The viewer's immediate local OS cursor therefore has no delayed blue duplicate returning through capture, encoding and network delivery. Existing Mac, browser and touch clients retain their captured-pointer behavior until they opt in. Capture resolution, codec, frame-rate target and bandwidth limit remain unchanged.

A 480-update isolated panel comparison measured dispatch p95 0.170 ms with the old panel and 0.074 ms with the initial vector panel; maximums were 14.02 and 5.93 ms. It did **not** reproduce the live half-second stalls. Separate live samples caught only idle/heartbeat periods; the wakeup hypothesis was not reproduced and run-loop dispatch was not changed. Further active-session measurement is required before attributing all live stalls to the pointer or claiming AnyDesk parity. Private evidence is in `.runtime/latency61-before-summary.json` and `.runtime/pointerbench/`.

## Input defaults and diagnostic evidence, 19 October 2026

The previous primary Open Screen Access action selected the owner's system mouse; independent input was a separate secondary action. The next build uses one action and defaults to independent input. A persistent Settings switch explicitly enables a shared pointer when needed; a change applies to the next viewer. Older full-display grants use that preference on restoration. No peer's control permission or expiry is extended. Unsupported independent-input SPI produces an explanation instead of silently taking over the system pointer.

The previous new-device approval picker defaulted to one hour, which could end a longer lesson. It now initially selects Until Revoked, with one hour and 24 hours still explicit options. Existing time-limited approvals continue to expire. This possible explanation is not a confirmed cause of the reported lesson interruption: the lesson host/viewer logs were unavailable locally.

The Mini's local build-61 journal spans 18 October 10:19 UTC through 19 October 04:13 UTC: 330 signaling-loss records, 97 ready records, and one `signaling-invalid` host stop while no viewer was connected. All but one close code were zero (no received WebSocket close code); one was 1008. These counts include retries and do not count 330 video-session drops. The gateway's only recorded restart on 18 October was the documented deployment at 09:31 UTC; TURN remained running from 11 October. The old records lack URL-loading error codes and cannot identify the network failure's cause or attribute it to the reported lesson.

The next build adds mode, approval-expiry, session-end and numeric network-error records, and enforces the [diagnostic privacy schema](DIAGNOSTICS.md) at the write boundary. The full native suite passed 144 tests with one explicit integration skip. Nineteen focused privacy, preference, authorization, consent and signaling tests passed after the last code edit. An initial isolated authorization run exposed missing NSApplication initialization in its test fixture; it is now initialized explicitly.


## 25 October 2026: constrained Retina video and foreground clicks (build 66)

The supplied lesson screenshots show compression blocks and damaged text. The
Mini journal is a different session and cannot identify that lesson. Its latest
host session nevertheless recorded H264 interval QP as high as 51, confirming
that severe quantization is possible with the old fixed-cadence policy.

The host now samples outbound H264 counters once a second independently of
optional disk logging. Two intervals at mean QP >= 34, or one at >= 42, lower the
frame-rate ceiling through 60/45/30/20/15/10 fps, taking measured input cadence
into account. Eight clear intervals at QP <= 28 restore one step. Sparse frames,
missing codec data and reset counters do not count as quality recovery. Native
resolution and the 32 Mbps maximum remain unchanged; no minimum bitrate is
forced onto a congested network. Hardware encoding's asynchronous wall time is
still not treated as a CPU overload signal. See WebRTC's
[quality-scaler configuration](https://webrtc.googlesource.com/src/+/refs/heads/main/video/adaptation/video_stream_encoder_resource_manager.cc):
the built-in QP scaler depends on resolution scaling being enabled, which is
unsuitable for preserving desktop text pixels here.

`WAI_QUALITY_BENCH=1 swift test --filter ScreenQualityBenchmarkTests` generates a
3200x2000 monochrome scrolling text page and uses the real VideoToolbox encoder
and WebRTC decoder, with ScreenCaptureKit's NV12 video-range input. At a 1 Mbps
configured bitrate for four seconds, 30 fps encoded/decoded 120 frames,
488,624 bytes, median QP 46; 10 fps encoded/decoded 40 frames, 486,887 bytes,
median QP 37. Sampled luma PSNR increased from 21.603 to 22.238 dB. These are
codec measurements from a synthetic scene, not a subjective AnyDesk comparison,
physical latency measurement or a network-session acceptance test.

A separate experimental keyframe refresh sent more data without improving this
fixture's recovered static text. It was removed before release. The production
encoder remains the standard WebRTC VideoToolbox implementation.

Foreground-app pointer-down no longer performs the background activation
sequence (50+15+1+100 ms and an off-window down/up). Such an activation click can
dismiss existing menus/popovers before the intended click. Background delivery
retains the compatibility sequence; its actual event is addressed using freshly
read geometry after the waits. Tests cover exact foreground event count, retained
background ordering, changed window origin during activation, and revocation.
They do not establish compatibility with every native or Electron control.

Local validation: 151 Swift tests, one pre-existing optional integration skip,
zero failures, including the opt-in hardware benchmark; web production build
passed. Private evidence is in `.runtime/release66-tests.log`. A two-device
lesson on the affected network remains necessary to confirm the reported
symptoms end to end. Install the host update on the Mac being viewed.
