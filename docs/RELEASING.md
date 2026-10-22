# Deployment and releases

The desktop application, web viewer, signaling gateway and TURN relay are separate artifacts. A green build alone does not verify a remote session or an update installation.

## Desktop release

Use a Mac with Xcode, a Developer ID Application identity, notarization credentials and WAI Remote's own Sparkle Ed25519 key. Keep signing keys and notarization credentials outside the repository. Never reuse another application's Sparkle key.

1. Run `swift test`, `go test -race ./...` in `gateway`, and `npm ci && npm run build -- --base=/remote/connect/` in `web`.
2. Increase `CFBundleVersion` for every distributed build. Keep `CFBundleShortVersionString` as the visible release version. Stage a universal release, rather than replacing an open application:

   ```sh
   WAI_CONFIGURATION=release WAI_UNIVERSAL=1 WAI_BUILD_NUMBER=3 \
     WAI_VERSION=0.2.0 WAI_APP_PATH="$PWD/.release/final/WAI Remote.app" \
     scripts/build-mac.sh
   ```

3. Verify the bundle with `codesign --verify --deep --strict`, and check both architectures and their minimum macOS version. Zip it with `ditto -c -k --keepParent`, submit the zip with `xcrun notarytool submit --wait`, then staple and validate the **app** with `xcrun stapler`. Confirm Gatekeeper accepts it with `spctl --assess --type execute`.
4. Make a read-only compressed DMG containing the stapled app and an `/Applications` symlink. Sign and notarize the DMG, staple it, and validate it. Mount the resulting DMG and check the app inside, not only the staging directory.
5. Run Sparkle's bundled `generate_appcast` on a directory containing the final DMG. Use `--ed-key-file` with the private key and `--download-url-prefix https://waiwai.is/remote/downloads/`. Publish the generated signed feed without editing its signed XML. Publish payloads before the feed, using atomic renames.
6. Install the previous signed build. Choose **WAI Remote → Проверить обновления…**, install the offered update and verify the relaunched process's bundle version, saved devices and permissions. Test a real remote click and text input after the update.
7. Publish the matching source tag, signed DMG, checksums and release notes on GitHub. Verify the live landing page, download and signed feed independently.

The app requires macOS 15+, supports Apple Silicon and Intel, and uses bundle identifier `is.wai.remote.dev` to preserve existing installations' identity and permissions. Do not rename that identifier during packaging. Version 0.1.0 predates Sparkle and needs a manual installation.

## Signing on waiMini

The existing WAI Remote Sparkle key is installed at `~/.config/wai-remote/sparkle-ed25519.key` (directory mode 0700, file mode 0600). Pass it explicitly with `--ed-key-file`; unattended releases do not need the login keychain. Its public key must remain `GndWRikzQviRjfkdO0CHl99wRI1tHaBpzAJ47EeP15U=`.

The exact key is backed up in 1Password, **Development → WAI Remote Sparkle EdDSA private key**, document ID `ykqcyvjmowvaobfaodc2xffcbu`. To restore it on an authorized release Mac:

```sh
umask 077
mkdir -p "$HOME/.config/wai-remote"
op document get ykqcyvjmowvaobfaodc2xffcbu --vault Development \
  --out-file "$HOME/.config/wai-remote/sparkle-ed25519.key"
```

Before a release, run `~/.local/bin/wai-signing check all` to verify the existing macOS and iOS signing identities with disposable binaries. Generate and verify the Sparkle feed on the Mini:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --ed-key-file "$HOME/.config/wai-remote/sparkle-ed25519.key" \
  --download-url-prefix https://waiwai.is/remote/downloads/ RELEASE_DIRECTORY
.build/artifacts/sparkle/Sparkle/bin/sign_update --verify \
  --ed-key-file "$HOME/.config/wai-remote/sparkle-ed25519.key" \
  RELEASE_DIRECTORY/appcast.xml
```

Publish the signed feed atomically at `/opt/wai-remote/releases/updates/appcast.xml` on `wai-web-prod`, after verifying that its payload is already available at the public download URL. Preserve the previous feed for rollback.

## Public service

The current deployment uses HTTPS at `waiwai.is/remote/connect/` with a loopback-only Go process behind nginx. The web assets must be built with that base path. The nginx include also routes `/remote/downloads/` and `/remote/updates/`; `/remote` itself belongs to the `wai-web` landing page.

The files under `deploy/` are the actual service templates. Their domain, IP and paths are deployment-specific: replace them for another installation. Run the gateway and coturn as a dedicated unprivileged user. Generate the shared REST secret once using `deploy/configure-relay.py`; restrict the resulting files to root and the service group. Never put the secret into source, a browser bundle, command output or a release.

The public relay uses coturn 4.18.0, UDP and TCP 3478, and a bounded UDP relay range. Updated native clients advertise `iceVersion: 2` and use UDP relay with TCP fallback. Direct VPN routes are disabled after measured multi-second SCTP stalls; see `PERFORMANCE.md`. Older clients retain their TCP relay configuration until their gathering logic is updated. Relay peer addresses remain restricted to the relay itself. Allow UDP/TCP 3478 publicly, and allow the relay range only between the relay's own public address and itself. Keep allocation, bandwidth and gateway admission limits enabled. Do not set coturn `bps-capacity`: each allocation reserves its full `max-bps` from it, so it caps the number of allocations, not traffic, and one viewer with two network paths can leave the host no relay. A deployment test must connect two devices on different networks and verify fresh video and input, not just a successful WebSocket or TURN allocation. Networks that block this TURN transport need separate validation.

After changing nginx, validate its configuration and reload it. If an edge proxy mirrors the origin configuration, wait for or trigger that sync before checking the public URL. Confirm `/remote/connect/healthz`, real device authentication, the remote session, download responses and update feed through the public hostname.

The host must be logged in, unlocked and have an explicitly opened access grant. Release 0.3.0 preserves that grant across relaunch/login, prevents idle system sleep, and suspends capture/input while locked or deliberately asleep. The bundled `is.wai.remote.recovery` login agent relaunches this exact app after an unexpected exit. The owner can disable it in macOS Login Items or close access in the app. Native clipboard files remain limited to 100 MiB. Login-screen access, audio forwarding and an availability guarantee are not included.

## iOS / TestFlight

Use the existing App Store Connect app `is.wai.remote.ios`. On waiMini, prepare signing with `~/.local/bin/wai-signing prepare ios`; use the existing identity in `~/.appstoreconnect/aigid-appstore.keychain-db`. Install an App Store provisioning profile containing that certificate. Never change the global keychain search order or create a replacement certificate to resolve a profile mismatch.

`python3 scripts/release-ios.py --profile PROFILE_UUID --version 0.3.0 --build 52` archives and exports with manual signing. Add `--upload` to upload after validation. Credentials are read from `~/.appstoreconnect/config.json`. DerivedData stays under `~/Library/Caches/WAIRemoteBuilds/ios-release`; archives and exports stay under `.release/`. Verify the uploaded build reaches VALID processing state and add it to the existing internal TestFlight group. Upload success alone does not prove tester availability.

## Availability regression

- Leave an approved session active beyond ten minutes. Check a moving timestamp and real input at the end, not just connection labels.
- Interrupt the transport, then verify recovery to the same pinned host without another invitation. Cancel waiting and confirm it stays cancelled.
- Background and foreground the iOS viewer; old touch gestures must be cancelled and control must wait for a fresh frame.
- Verify `launchctl print gui/$(id -u)/is.wai.remote.recovery`, then terminate only the exact host process during an isolated test. Verify the helper relaunches the installed bundle and restores an open display grant.
- Close access and confirm neither automatic retry nor application relaunch reopens it.
- Lock and unlock a test Mac: capture/input must stop while locked and resume only after unlock. A display turning off alone must not revoke access.
- Close a shared application window; access must close rather than switch to another window or display.

## Native input regression

On the receiving Mac, open the app's mouse and keyboard test window. Connect from a second Mac on a different network.

- Click the test button once: the counter must increase by exactly one.
- Paste `WAI Remote 11 — Привет!`: the field must contain the complete string.
- Drag the test window by its title bar horizontally and vertically. It must remain under the pointer, moving by the same distance as the pointer, including on a Retina display.
- Open and dismiss the viewer's local menu, then repeat the click. Losing local focus must release pressed input; returning must allow a fresh interaction.
- Disconnect, reconnect using the saved computer and repeat the click and paste.

The pre-fix drag regression moved the window farther than the pointer. Check the window's final position as well as the cursor: a moving cursor alone does not prove correct drag events.
