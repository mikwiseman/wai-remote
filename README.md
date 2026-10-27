# WAI Remote

**Your Mac, within reach.** Native macOS and iOS apps for controlling a Mac and drawing together over the internet.

[Download for Mac](https://waiwai.is/remote) · [Releases](https://github.com/mikwiseman/wai-remote/releases)

<img src="design/icons/concepts/01-portal.png" width="180" alt="WAI Remote icon">

## Use it

Requires **macOS 15 or later**, on Apple Silicon or Intel. Install WAI Remote on the sharing Mac, then connect from another Mac, the native iPhone/iPad app, or the browser viewer.

1. On the Mac you want to access, choose **Поделиться экраном** (Share screen). Follow the macOS Screen Recording and Accessibility prompts, then open access.
2. On the other Mac, iPhone/iPad or browser viewer, choose **Сканировать QR-код** and scan the code shown by the sharing Mac. You can also open an image of the code or paste the invitation link.
3. Approve viewing or control on the sharing Mac. The connection is saved for next time.

QR scanning uses the camera only while the scanner is open. Camera frames and selected images stay on your device. The iPhone Camera app can also open the QR's web invitation; choose **Открыть в приложении WAI Remote** to continue in the installed app. Treat the code like its invitation link and share it only with the intended recipient.

Both devices need internet and can be on different networks. Open access stays enabled until you close it. WAI Remote prevents idle system sleep and restores access after app relaunch or login using a bundled background helper. Allow that helper in macOS Login Items if macOS requests it. Turning off the display does not close access. Locking or deliberately sleeping the Mac suspends capture and input; access resumes after wake and unlock. There is no access before login or through the lock screen.

**Открыть доступ к экрану** shares the main display with an independent pointer by default. Settings → **Независимая мышь** can explicitly switch to a shared system pointer; the choice applies to the next connection. Clicks select the application window under that pointer; dragging stays with the original window, and typing follows the last clicked window. The owner's system pointer is not moved. Applications and the clipboard remain shared; system menus, security prompts and some application-specific behavior may require ordinary screen control. Existing single-window grants remain limited to their original window. See [input design and verification](docs/INDEPENDENT-INPUT.md).

The Mac viewer supports mouse, keyboard, copying text, images and files between Macs, drawing and full screen. OpenRamble can insert dictated text into the remote window. **⌘⌥Esc** releases the viewer's keyboard focus; **⌘Q** quits locally. The iOS viewer has saved computers, touch control, text entry, two-finger scrolling and zoom, and reconnects when returning to the foreground. Audio forwarding is not included. The interface is currently in Russian. macOS/iOS 26 use native Liquid Glass; older supported systems use material surfaces.

Updates use **Sparkle**. The app checks automatically; you choose when to install. You can also use **WAI Remote → Проверить обновления…**. Prototype 0.1.0 installations need one manual update because they did not include Sparkle.

## Build

Use Xcode with Swift 6.2+, Go 1.26 and Node 24. Dependency versions are pinned.

```sh
swift test
cd gateway && go test -race ./... && cd ..
cd web && npm ci && npm run build && cd ..
WAI_SIGN_IDENTITY=- scripts/build-mac.sh
open 'build/WAI Remote.app'
```

Ad-hoc builds are for local development and may need fresh macOS permission approval after code changes. For a stable installation, use your own Developer ID identity. The script refuses to overwrite a running bundle. Set `WAI_APP_PATH` to stage elsewhere, `WAI_CONFIGURATION=release` for optimization, and `WAI_UNIVERSAL=1` to build both architectures.

The public service is the default. For local development, run:

```sh
cd gateway
go run . -listen 127.0.0.1:8788 -web ../web/dist
```

Then select that address under **Настройки → Диагностика** in the host. Use a LAN address when connecting from another computer. Plain HTTP is accepted only on local networks. Public deployments require HTTPS.

## How it works

- ScreenCaptureKit captures the display; WebRTC carries encrypted video and input between the devices.
- A Go gateway authenticates device signatures and forwards connection setup messages. It does not receive unencrypted screen pixels or keystrokes.
- Device identities use P-256 keys. The native private key stays in macOS Keychain. The host's public key is pinned in the invitation.
- Invitations have no time limit while access remains open. Closing access or creating a new invitation revokes the old link. A first connection still requires approval on the sharing Mac. Saved computers can reconnect without a new invitation; their saved connections contain public identity information, not the invitation secret.
- New device approvals default to until revoked, with one hour and 24 hours available explicitly. Existing approvals without an expiry stay indefinite. Expiration closes the active session and requires a fresh invitation and owner approval; it never revokes another device. Network and gateway failures preserve the owner's open-access grant.
- Approved connections recover after transient transport loss with bounded retry delays. Explicit disconnect cancels recovery. The host detects silent signaling connections and reconnects independently of an active screen session.
- The host keeps final authority over viewing, control, drawing, pause and revocation. Input is released when focus or transport is lost; sequence numbers and session epochs reject stale commands.
- Apps connect peer to peer: on one LAN, or across the internet through NAT using STUN servers in Moscow, which a VPN used in Russia reaches directly. The relay, over TCP, is used only when the networks cannot connect directly.
- The public relay uses short-lived credentials, bounded allocations and bandwidth, and relay-to-relay peers only. It is a small initial service, without an availability SLA.

[Deployment and release procedure](docs/RELEASING.md) · [Security](SECURITY.md) · [Seven icon concepts](design/icons/README.md)

## Source map

| Directory | Purpose |
| --- | --- |
| `Sources/RemoteCore` | Session state, authorization, invitation parsing, drawing and viewer geometry |
| `Sources/WAIRemote` | Native macOS host and viewer, permissions, input, Sparkle and UI |
| `gateway` | Authenticated signaling and short-lived TURN credential issuance |
| `web` | Browser viewer |
| `ios` | Native iPhone/iPad viewer, distributed through TestFlight |
| `Sources/WAIRemoteWatchdog` | Bundled login helper that restores an explicitly opened host |
| `mac`, `design` | App icon sources and menu bar assets |
| `deploy`, `scripts` | Service templates, packaging and release helpers |

MIT licensed. Bundled dependencies retain their own licenses; see [third-party notices](THIRD_PARTY.md). Made by [WAI](https://waiwai.is).
