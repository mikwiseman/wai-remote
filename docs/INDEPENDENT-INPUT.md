# Independent desktop input

The independent mouse shares the main display and selects the application window under each remote click. The owner no longer has to choose one window before connecting. From build 65, this is the default for ordinary screen access. Settings → Independent Mouse can explicitly enable the shared system pointer instead.

## Basis

- [OpenAI describes Codex background computer use](https://openai.com/index/codex-for-almost-everything/) as a separate cursor working alongside the user in other applications. The installed macOS client also passes an explicit application to its click command; this does not expose its private native implementation.
- Apple's [CGEvent.postToPid](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid(_:)) addresses an event to a process. The existing WAI Remote window-input implementation combines this with the background pointer delivery and target-only focus recipe described by [cua-driver](https://github.com/trycua/cua/blob/main/libs/cua-driver/rust/crates/platform-macos/src/input/mouse.rs). Attribution remains in `THIRD_PARTY.md`.
- This is application-directed input, not a second macOS login session or a second hardware mouse. Applications, windows and the clipboard are shared. Two people editing the same application's focused field are not isolated from one another. System menus, security prompts and application-specific activation behavior need separate compatibility checks.

## Routing

WindowServer hit-testing selects the actual input window. Bounding-box scans are insufficient: on both test machines the Dock exposes a transparent rectangle covering the whole display. `SLSFindWindowAndOwner` follows the window regions and can continue below an explicitly excluded window. The pointer and ink panels must be skipped this way: `ignoresMouseEvents` alone does not remove them from geometric hit-testing. The lookup never skips an unrelated or unaddressable window, and validates the result's current process ID and bounds. Missing SPI prevents independent sharing with an explanation; the owner can explicitly select the shared system pointer in Settings.

A button-down pins its window until all held buttons are released. Hover and scroll do not redirect keyboard input. Each held key retains its original destination for key-up, even after another window is clicked. Empty or closed targets never fall through to the global HID queue. Disconnect and a change of input mode or target cancel pending work. Pause, stalls and permission loss release held input and hide the remote pointer after the input already queued, so keys and text behind a slow background click still arrive in order. Typing keeps following the last clicked window until a disconnect or a change of input mode or target.

The existing single-window grants remain scoped to their original window. Full-display restoration uses the persistent pointer preference, whose default is independent. Switching to the owner's system mouse requires an explicit Settings opt-out; that choice applies to the next connection and survives relaunch.

## Verification

Routing regressions cover window identity, excluded overlays, drag capture across applications, multiple held buttons, empty-space presses, hover versus typing, cancellation and restoration of the selected mode. On 16 October 2026, `swift test` ran 120 tests with no failures and one optional test skipped. The routing test first failed against the unimplemented selector. A separate regression reproduced a resumed video track remaining hidden behind the connection overlay; rearming the first-frame notification fixes it without rebuilding the track.

Native UI inspection on macOS 27.0.1 confirmed that the two top tabs retain their positions when switching content; the nested glass capsule and window-selection sheet are gone. The initial signed development build 0.3.1 (55) was installed on the MacBook and macOS 26.4 Mini. On 17 October the universal app and DMG were notarized, PR #3 was merged, and both Macs completed the real Sparkle 54→55 update with their saved devices and independent-display grants retained.

Native acceptance used two separate AppKit fixture processes on Mini. Both received button clicks, text, scrolling and drag events without selecting a window in WAI Remote. The first field contained `Альфа 55`; the second received the complete ASCII suffix `Beta OK`. The automation omitted some Cyrillic before submission, matching the previously recorded computer-use limitation; this run is not a new all-Unicode acceptance result. Command-A and Command-V still did not perform their editing actions in the background AppKit fixture. These application-specific shortcut limitations remain; ordinary text and pointer delivery passed.

The final check used the normal public gateway after removing the temporary loopback gateway and SSH forwarding. On the exact committed application, A's click counter advanced 1→2 and its drag counter 2→3; B's scroll and drag counters both advanced 0→1. During these two action intervals, 48 and 41 WindowServer samples respectively retained the owner's foreground/key-focus process and one physical cursor position. Maximum sample gaps were 42.3 and 46.7 ms, so this is observed isolation, not proof against changes shorter than the sampling interval. Earlier clicks and typing across A/B also retained the owner's process and cursor.

Native computer-use coordinates on the Retina viewer included the window origin twice; correcting only the test coordinates made clicks land at the displayed point. A proposed mouse-subtype change was discarded when the original application's drag counter confirmed delivery. No input workaround from that experiment is in the committed code.

The original public gateway, saved Mini invitation and last-device entry were verified restored. Both fixture apps and the read-only sampler were stopped. Private diagnostics and screenshots remain under `.runtime/independent55/` and are not included in source control.

## Repeated-click regression, 17 October

The earlier few-click acceptance did not expose a repeatable failure reported on Mini. Ten clicks reached the host on build 55 but did not advance the fixture counter. A read-only WindowServer probe showed that the visible remote-pointer panel intercepted geometric lookup at its own hotspot. The corrected lookup walks below only WAI Remote's pointer and ink panels. Regression tests also reject repeated hits and preserve an unrelated window as a barrier.

A second reproduction found a held `KeyA` after the viewer handled Command-A without receiving AppKit's key-up. This disabled the existing fast accessibility button path: all ten following clicks took the slower background-focus recipe, with median native delivery around 200 ms and queue delay up to 836 ms. The viewer now sends a complete down/up pair for a handled command equivalent. Its regression failed before the fix and passes afterwards. This fixes the retained key; it does not establish that every background application performs the requested editing shortcut.

With viewer 58 and host 57, Command-A followed by 50 native clicks advanced the counter 120→170. All 50 lookups saw zero held keys; 49 found the accessibility button. Native down-event delivery had p50/p95 18.8/50.1 ms, and delivery-queue p95 was 52.2 ms. The one cold miss used the existing slower path. Across 193 WindowServer samples the owner's foreground/key-focus process and physical cursor position stayed unchanged. These are sampled isolation and host processing measurements, not optical click-to-photon latency. A separate Chrome fixture received all 50 clicks, text, a drag and scrolling; Command-A still did not replace its field contents.

Consecutive pending pointer moves now keep only the newest position. Clicks, releases, keys and scrolling remain ordering barriers. The regression floods the queue with 2,000 moves and verifies both gesture boundaries and the final positions. Pointer-panel updates no longer reorder an already visible panel for every move.

Two reconnect failures on earlier candidates stopped host ICE gathering until an application restart. Build 59 gives each hosted desktop connection a fresh WebRTC factory, matching the viewer's existing lifetime. Three manual disconnect/reconnect cycles restored video and real input without a requested host restart; native counts advanced 170→174 including the initial control click. The lower-level networking cause is not established by the saved thread samples. A subsequent MacBook application update also reconnected successfully. The current CI checks pass, including 124 Swift tests with one optional integration skip, the Go race suite and the web build.

Content-free diagnostic evidence is retained under `.runtime/`; raw desktop screenshots and device identifiers are not committed. Sustained video quality and physical input-to-display latency require separate measurements and must not be inferred from the button counters.

The later build-59 run on both Macs delivered all 50 native clicks (174→224), but had a substantial network/session delay: down-ACK p50/p95/max 2,245/3,999/4,274 ms and network RTT p95 2,306 ms. A viewer-only TCP diagnostic also delivered 50/50, with down-ACK p50/p95/max 300/1,920/2,376 ms. This short, mixed desktop observation is neither a controlled video benchmark nor evidence for forcing TCP in production; the original diagnostic preference was restored. No sustained smoothness or product-superiority claim follows from the input fixes. Evidence: `.runtime/responsive59-native50-viewer{,-tcp}.{jsonl,json}`.

## Click reliability, 26 October

A diagnosis of the 25 October session found clicks dying in four places. This change addresses each one and records where a click ends. Nothing below has been run in a live session or on a device yet.

**Stalls.** The host's 2-second dead-man and transport interruptions used to start a new input epoch. Input that an uplink stall delivered late, but in order, was then rejected without trace. The journal had 16 such windows in 30 minutes. A stall now lifts held buttons and keys and cancels ink, but keeps the epoch and sequence. Replaying the journal's 15:32:52 stall through RemoteCore: the old code rejected the click sent at 54.0 (down and up); the new code delivers it. A viewer interrupted by its own transport pauses until the host's next state instead of waiting for a new epoch. Viewers built before this change still wait for a new epoch, so after their own transport interruption they reconnect after about 8 seconds instead of resuming.

**Focus loss.** The Mac viewer (window or first-responder loss, local ⌘H/M/,/0), iOS (inactive scene) and the web viewer (blur, hidden page, pointer cancel) now send up events for what they hold and keep the session valid. The next click needs no host round trip. The explicit release remains for disconnect and ⌘⌥Esc.

**Delivery.** The event is addressed once, from the window geometry the user aimed at; build 66's recomputation after activation is reverted. The foreground shortcut stays. A click into a background app's window above the normal layer, or under an `AXMenu` or `AXPopover` element, keeps the target-only focus record but skips the off-window primer that closed it. The accessibility fast path starts from the app's own topmost element at the point and climbs at most three parents to an enabled, pressable button of the hit window; anything else gets ordinary events. In a real AppKit fixture the old tree-order lookup returned a button covered by a label overlay. App-level hit-testing needs a visible, opaque window, so the in-process tests start from a known element instead of flashing windows on screen. A press with no preceding move at that point first moves the pointer over the target, so hover-armed controls respond to taps.

**Click counts.** Viewers report the click count: `NSEvent.clickCount` on the Mac, a tap counter with 0.5 s and 22-point limits on iOS, and a local counter on the web because Chromium 156 reports `PointerEvent.detail` as 0 on `pointerdown`. The host clamps it to 1–3 and keeps its own grouping for older viewers.

**Backpressure.** The host answers a burst of stale messages with one state and ink resync. Viewers skip pointer moves while the data channel holds more than 16 KB; clicks, keys and text are never dropped.

**Diagnostics.** With diagnostics on, `input-delivery` names the outcome (`system`, `window`, `ax-press`, `primer`, `no-target`, `frame-gone`, `cancelled`), `input-rejected` counts rejections per check, `input-unacknowledged` marks input without an acknowledgement after 5 s, and `viewer-recover` names the reconnect cause. All rows are content-free.

`swift test` ran 166 tests (131 + 35) with no failures and the two existing opt-in skips. The iOS app builds for the simulator and the web viewer builds. Still unverified on a device: menus, pop-ups and popovers of background apps, the hover move in Chrome and native apps, and touch double-taps.

## Shortcuts and paste, 27 October

**Background shortcuts.** AppKit and Chromium perform menu key equivalents only for the active app, so a Command shortcut posted to a background window did nothing. For a Command key-down aimed at a window whose app is not frontmost, the host now reads that app's menu bar through accessibility and presses the enabled item whose `AXMenuItemCmdChar` and `AXMenuItemCmdModifiers` match the key and its exact modifiers. Without a match, or if the press fails, the key is posted as before. The lookup runs on the input queue, reads the menus afresh every time, stops after 250 ms and skips the system's Apple menu, which holds Lock Screen and Log Out. A non-Latin layout matches the US Latin key, as AppKit does. Diagnostics label the outcome `menu`. An in-process AppKit menu test covers matching, exact modifiers, submenus, disabled items and the Apple menu. Read-only lookups in the running Finder and Telegram found their enabled Undo, Copy and Paste items in 7–280 ms on a heavily loaded machine; nothing was pressed. Whether a pressed item reaches the right field of a background app after a remote click has not been tested on a device.

**Viewer shortcuts.** The Mac viewer keeps only exact Command-Q, Command-Option-Escape, Command-H/M/,/0, Option-Command-H and Command-V. Command-Q with another modifier no longer quits the viewer, and Option-Command-V or Control-Command-V reach the remote Mac instead of pasting.

**Paste.** A paste of files or images that a pause, a stall, lost control or a closed channel interrupts now shows the viewer's paste failure instead of never arriving. A deliberate disconnect stays quiet.

`swift test` ran 176 tests (140 + 36) with no failures and the two existing opt-in skips.
