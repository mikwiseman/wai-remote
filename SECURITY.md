# Security

Remote control is available only while the host has explicitly opened access and macOS permissions allow it. New devices require approval. Treat an invitation as private and share it only with the intended person. Check the requesting device before approving it.

To end access, use **Close access** on the host. Revoke a saved device if it should no longer reconnect. Locking or sleeping the Mac also stops sharing. The app does not bypass the lock screen or macOS permissions.

The gateway sees device public IDs, network addresses and signaling metadata. TURN sees encrypted traffic and connection metadata. Neither receives the screen's decrypted content. A compromised host or viewer is outside this protection.

Report vulnerabilities privately using GitHub's **Report a vulnerability** feature. Please omit private keys, invitation secrets, screenshots of private desktops and raw credentials from public issues. Include the version, operating systems, expected result and minimal reproduction.

Do not run a public relay with the private development ICE configuration. Public deployment needs HTTPS, per-device expiring relay credentials, admission limits, allocation quotas, bandwidth limits and peer restrictions. See `deploy/` and `docs/RELEASING.md`.
