# Independent desktop input

The independent mouse shares the main display and selects the application window under each remote click. The owner no longer has to choose one window before connecting. Ordinary screen access continues to use the system mouse.

## Basis

- [OpenAI describes Codex background computer use](https://openai.com/index/codex-for-almost-everything/) as a separate cursor working alongside the user in other applications. The installed macOS client also passes an explicit application to its click command; this does not expose its private native implementation.
- Apple's [CGEvent.postToPid](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid(_:)) addresses an event to a process. The existing WAI Remote window-input implementation combines this with the background pointer delivery and target-only focus recipe described by [cua-driver](https://github.com/trycua/cua/blob/main/libs/cua-driver/rust/crates/platform-macos/src/input/mouse.rs). Attribution remains in `THIRD_PARTY.md`.
- This is application-directed input, not a second macOS login session or a second hardware mouse. Applications, windows and the clipboard are shared. Two people editing the same application's focused field are not isolated from one another. System menus, security prompts and application-specific activation behavior need separate compatibility checks.

## Routing

WindowServer hit-testing selects the actual input window. Bounding-box scans are insufficient: on both test machines the Dock exposes a transparent rectangle covering the whole display. `SLSFindWindowByGeometry` respects these input regions; the result is checked against the current window's process ID and bounds. Missing SPI disables the independent-mode entry point.

A button-down pins its window until all held buttons are released. Hover and scroll do not redirect keyboard input. Each held key retains its original destination for key-up, even after another window is clicked. Empty or closed targets never fall through to the global HID queue. Disconnect, pause and permission loss cancel pending work, release held input and hide the remote pointer.

The existing single-window grants remain scoped to their original window. Independent display grants have their own persisted case, so restarting or updating cannot silently turn them into control of the owner's system mouse.

## Verification

Routing regressions cover window identity, excluded overlays, drag capture across applications, multiple held buttons, empty-space presses, hover versus typing, cancellation and restoration of the selected mode. On 16 October 2026, `swift test` ran 120 tests with no failures and one optional test skipped. The routing test first failed against the unimplemented selector. A separate regression reproduced a resumed video track remaining hidden behind the connection overlay; rearming the first-frame notification fixes it without rebuilding the track.

Native UI inspection on macOS 27.0.1 confirmed that the two top tabs retain their positions when switching content; the nested glass capsule and window-selection sheet are gone. Signed development build 0.3.1 (55) was installed on the MacBook and macOS 26.4 Mini. It is not a notarized Sparkle release.

Native acceptance additionally exercises actual clicks, text, scrolling and dragging while sampling the owner's physical pointer and foreground/key-focus process. Private diagnostic files remain under `.runtime/independent55/` and are not included in source control.
