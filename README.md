# WAI Remote

**Another Mac, within reach.** A native macOS app for sharing a screen, controlling another Mac, and drawing together over the internet.

[Download for Mac](https://waiwai.is/remote) · [Releases](https://github.com/mikwiseman/wai-remote/releases)

<img src="design/icons/concepts/01-portal.png" width="180" alt="WAI Remote icon">

## Use it

Requires **macOS 15 or later**, on Apple Silicon or Intel. Install WAI Remote on both Macs.

1. On the Mac you want to access, choose **Поделиться экраном** (Share screen). Follow the macOS Screen Recording and Accessibility prompts, then open access.
2. Copy its invitation. On the other Mac, choose **Подключиться** (Connect) and paste the link.
3. Approve viewing or control on the sharing Mac. The connection is saved for next time.

Both computers need internet. They can be on different networks. The sharing Mac must be awake and unlocked; locking it or putting it to sleep closes access. Stop sharing or revoke a saved device from the app at any time.

The Mac viewer supports mouse, keyboard, text paste, drawing and full screen. **⌘⌥Esc** releases the viewer's keyboard focus; **⌘Q** quits locally. File transfer, audio and unattended access before login are not included. The interface is currently in Russian.

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
- The host keeps final authority over viewing, control, drawing, pause and revocation. Input is released when focus or transport is lost; sequence numbers and session epochs reject stale commands.
- The public relay uses short-lived credentials, bounded allocations and bandwidth, and relay-to-relay peers only. It is a small initial service, without an availability SLA.

[Deployment and release procedure](docs/RELEASING.md) · [Security](SECURITY.md) · [Seven icon concepts](design/icons/README.md)

## Source map

| Directory | Purpose |
| --- | --- |
| `Sources/RemoteCore` | Session state, authorization, invitation parsing, drawing and viewer geometry |
| `Sources/WAIRemote` | Native macOS host and viewer, permissions, input, Sparkle and UI |
| `gateway` | Authenticated signaling and short-lived TURN credential issuance |
| `web` | Browser viewer |
| `ios` | Experimental iPhone/iPad viewer; not part of this public Mac release |
| `mac`, `design` | App icon sources and menu bar assets |
| `deploy`, `scripts` | Service templates, packaging and release helpers |

MIT licensed. Bundled dependencies retain their own licenses; see [third-party notices](THIRD_PARTY.md). Made by [WAI](https://waiwai.is).
