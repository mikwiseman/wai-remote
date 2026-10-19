# Local diagnostics and privacy

The Mac's Settings → Diagnostics contains an opt-in local diagnostic journal. A change takes effect after relaunch. There is no automatic report upload. The ordinary journal records timestamps, numeric error codes, connection states, frame and transfer counters, and input queue/handling times. It does not record typed text, physical keys, pointer coordinates, screenshots, clipboard contents, file paths, device names, invitation secrets, SDP, IP addresses or ports.

`DiagnosticPrivacy` enforces an event-specific schema before `PerformanceLog` writes a row. Unknown events, fields, free-form strings and incorrect value types are discarded. WebRTC identifiers are replaced with process-salted hashes while preserving references within that process. Error domains and other labels must belong to fixed lists; localized error descriptions are never recorded. Regression tests attempt to inject private values through input, clipboard, error and nested RTC fields.

Logs use mode 0600 in the user's temporary directory. Each process rotates its ordinary journal at 20 MB and retains one previous file. Logs from earlier processes can remain in the temporary directory; this is not a promise of automatic deletion on exit. A user can disable logging in Settings and restart the app.

The separate developer preference `performanceNetworkTrace` enables a bounded WebRTC event trace only when ordinary diagnostics are enabled too. That trace contains network metadata and is **not** covered by the ordinary journal's schema. It is off by default, is not part of a support report, and must not be published. Existing private traces are not silently deleted by an update.

## Distinguishing disconnections

- `host-session-close` records a fixed cause: owner action, transport failure, replacement by a signed retry, negotiation failure, send backpressure, revocation, approval expiry, host stop or connection timeout. Session duration is monotonic elapsed time.
- `host-stop` records the separately classified application/capture/permission/suspend cause. It distinguishes loss of the current connection from the owner's explicit Close Access action.
- `host-signaling-lost` and `viewer-signaling-lost` retain numeric WebSocket and URL-loading error codes without the URL, close reason text or payload.
- `input-mode` records whether independent input, a selected window and control permission were active. It contains no peer or window identity.
- `peer-approval` and `host-session-open` record whether approval is indefinite or how many seconds remain. Existing approval deadlines are enforced unchanged.

Signaling loss alone does not prove that an established video/input channel failed. An input acknowledgement is not an optical input-to-display measurement. A log on the Mini cannot identify an unrelated lesson hosted on another computer.
