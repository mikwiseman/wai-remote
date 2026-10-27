# Security

Remote control is available only while the host has explicitly opened access and macOS permissions allow it. New devices require approval. Treat an invitation as private and share it only with the intended person. Check the requesting device before approving it.

To end access, use **Close access** on the host, or **Закрыть доступ и выйти** in its menu. Revoke a saved device if it should no longer reconnect. An open grant persists across application relaunch and login; the bundled login helper only relaunches this app while that grant exists. Locking or sleeping the Mac suspends sharing and input without revoking the owner's grant. Capture resumes only in an active, unlocked login session. The app does not bypass the lock screen or macOS permissions.

A window grant stores the window ID, process ID, process launch time and boot/login session. It cannot turn into full-screen sharing or follow a reused process ID. Independent window input has no global-input fallback. New sessions require a fresh authenticated handshake; held input is released on interruption and stale input is never replayed after recovery.

The gateway sees device public IDs, network addresses and signaling metadata. TURN sees encrypted traffic and connection metadata. Apps connect peer to peer first, so the two connected devices learn each other's public and local network addresses; addresses private to a VPN tunnel and loopback are never offered. The STUN servers that tell a device its public address are public servers in Moscow and see only that request. Neither receives the screen's decrypted content. A compromised host or viewer is outside this protection.

Report vulnerabilities privately using GitHub's **Report a vulnerability** feature. Please omit private keys, invitation secrets, screenshots of private desktops and raw credentials from public issues. Include the version, operating systems, expected result and minimal reproduction.

Do not run a public relay with the private development ICE configuration. Public deployment needs HTTPS, per-device expiring relay credentials, admission limits, allocation quotas, bandwidth limits and peer restrictions. See `deploy/` and `docs/RELEASING.md`.
