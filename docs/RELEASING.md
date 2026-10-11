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

## Public service

The current deployment uses HTTPS at `waiwai.is/remote/connect/` with a loopback-only Go process behind nginx. The web assets must be built with that base path. The nginx include also routes `/remote/downloads/` and `/remote/updates/`; `/remote` itself belongs to the `wai-web` landing page.

The files under `deploy/` are the actual service templates. Their domain, IP and paths are deployment-specific: replace them for another installation. Run the gateway and coturn as a dedicated unprivileged user. Generate the shared REST secret once using `deploy/configure-relay.py`; restrict the resulting files to root and the service group. Never put the secret into source, a browser bundle, command output or a release.

The public relay uses coturn 4.18.0, TCP 3478 and a bounded UDP relay range. Peer addresses are restricted to the relay itself, because both endpoints use relay-only ICE. Allow the relay range only between the relay's own public address and itself. Keep allocation, bandwidth and gateway admission limits enabled. A deployment test must connect two devices on different networks and verify fresh video and input, not just a successful WebSocket or TURN allocation. Networks that block this TURN transport need separate validation.

After changing nginx, validate its configuration and reload it. If an edge proxy mirrors the origin configuration, wait for or trigger that sync before checking the public URL. Confirm `/remote/connect/healthz`, real device authentication, the remote session, download responses and update feed through the public hostname.

The host must remain awake, unlocked and explicitly sharing. This release does not provide login-screen access, audio, file transfer or a service availability guarantee.

## Native input regression

On the receiving Mac, open the app's mouse and keyboard test window. Connect from a second Mac on a different network.

- Click the test button once: the counter must increase by exactly one.
- Paste `WAI Remote 11 — Привет!`: the field must contain the complete string.
- Drag the test window by its title bar horizontally and vertically. It must remain under the pointer, moving by the same distance as the pointer, including on a Retina display.
- Open and dismiss the viewer's local menu, then repeat the click. Losing local focus must release pressed input; returning must allow a fresh interaction.
- Disconnect, reconnect using the saved computer and repeat the click and paste.

The pre-fix drag regression moved the window farther than the pointer. Check the window's final position as well as the cursor: a moving cursor alone does not prove correct drag events.
