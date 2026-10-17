# Independent desktop input

The independent mouse shares the main display and selects the application window under each remote click. The owner no longer has to choose one window before connecting. Ordinary screen access continues to use the system mouse.

## Basis

- [OpenAI describes Codex background computer use](https://openai.com/index/codex-for-almost-everything/) as a separate cursor working alongside the user in other applications. The installed macOS client also passes an explicit application to its click command; this does not expose its private native implementation.
- Apple's [CGEvent.postToPid](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid(_:)) addresses an event to a process. The existing WAI Remote window-input implementation combines this with the background pointer delivery and target-only focus recipe described by [cua-driver](https://github.com/trycua/cua/blob/main/libs/cua-driver/rust/crates/platform-macos/src/input/mouse.rs). Attribution remains in `THIRD_PARTY.md`.
- This is application-directed input, not a second macOS login session or a second hardware mouse. Applications, windows and the clipboard are shared. Two people editing the same application's focused field are not isolated from one another. System menus, security prompts and application-specific activation behavior need separate compatibility checks.

## Routing

WindowServer hit-testing selects the actual input window. Bounding-box scans are insufficient: on both test machines the Dock exposes a transparent rectangle covering the whole display. `SLSFindWindowAndOwner` follows the window regions and can continue below an explicitly excluded window. The pointer and ink panels must be skipped this way: `ignoresMouseEvents` alone does not remove them from geometric hit-testing. The lookup never skips an unrelated or unaddressable window, and validates the result's current process ID and bounds. Missing SPI disables the independent-mode entry point.

A button-down pins its window until all held buttons are released. Hover and scroll do not redirect keyboard input. Each held key retains its original destination for key-up, even after another window is clicked. Empty or closed targets never fall through to the global HID queue. Disconnect, pause and permission loss cancel pending work, release held input and hide the remote pointer.

The existing single-window grants remain scoped to their original window. Independent display grants have their own persisted case, so restarting or updating cannot silently turn them into control of the owner's system mouse.

## Verification

Routing regressions cover window identity, excluded overlays, drag capture across applications, multiple held buttons, empty-space presses, hover versus typing, cancellation and restoration of the selected mode. On 16 October 2026, `swift test` ran 120 tests with no failures and one optional test skipped. The routing test first failed against the unimplemented selector. A separate regression reproduced a resumed video track remaining hidden behind the connection overlay; rearming the first-frame notification fixes it without rebuilding the track.

Native UI inspection on macOS 27.0.1 confirmed that the two top tabs retain their positions when switching content; the nested glass capsule and window-selection sheet are gone. Signed development build 0.3.1 (55) was installed on the MacBook and macOS 26.4 Mini. It is not a notarized Sparkle release.

Native acceptance used two separate AppKit fixture processes on Mini. Both received button clicks, text, scrolling and drag events without selecting a window in WAI Remote. The first field contained `Альфа 55`; the second received the complete ASCII suffix `Beta OK`. The automation omitted some Cyrillic before submission, matching the previously recorded computer-use limitation; this run is not a new all-Unicode acceptance result. Command-A and Command-V still did not perform their editing actions in the background AppKit fixture. These application-specific shortcut limitations remain; ordinary text and pointer delivery passed.

The final check used the normal public gateway after removing the temporary loopback gateway and SSH forwarding. On the exact committed application, A's click counter advanced 1→2 and its drag counter 2→3; B's scroll and drag counters both advanced 0→1. During these two action intervals, 48 and 41 WindowServer samples respectively retained the owner's foreground/key-focus process and one physical cursor position. Maximum sample gaps were 42.3 and 46.7 ms, so this is observed isolation, not proof against changes shorter than the sampling interval. Earlier clicks and typing across A/B also retained the owner's process and cursor.

Native computer-use coordinates on the Retina viewer included the window origin twice; correcting only the test coordinates made clicks land at the displayed point. A proposed mouse-subtype change was discarded when the original application's drag counter confirmed delivery. No input workaround from that experiment is in the committed code.

The original public gateway, saved Mini invitation and last-device entry were verified restored. Both fixture apps and the read-only sampler were stopped. Private diagnostics and screenshots remain under `.runtime/independent55/` and are not included in source control. The public Sparkle feed remains on 0.3.0 (54).
