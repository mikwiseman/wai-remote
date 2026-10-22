"""Run once as root on the documented origin. Never print relay credentials."""
from pathlib import Path
import grp
import os
import secrets

root = Path('/etc/wai-remote')
root.mkdir(mode=0o750, exist_ok=True)
group = grp.getgrnam('wai-remote').gr_gid
os.chown(root, 0, group)
key = root / 'relay-secret'
if not key.exists():
    key.write_text(secrets.token_hex(32) + '\n')
os.chmod(key, 0o640)
os.chown(key, 0, group)
config = root / 'turnserver.conf'
config.write_text('''listening-ip=65.108.215.2
relay-ip=65.108.215.2
listening-port=3478
min-port=49180
max-port=49243
realm=waiwai.is
server-name=WAI-Remote
fingerprint
use-auth-secret
static-auth-secret=''' + key.read_text().strip() + '''
no-tls
no-dtls
no-tcp-relay
no-multicast-peers
no-cli
no-software-attribute
denied-peer-ip=0.0.0.0-255.255.255.255
denied-peer-ip=::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff
allowed-peer-ip=65.108.215.2
user-quota=4
total-quota=64
max-bps=5000000
max-allocate-lifetime=3600
stale-nonce=600
relay-threads=2
pidfile=/run/wai-remote-turn/turnserver.pid
log-file=stdout
simple-log
''')
os.chmod(config, 0o640)
os.chown(config, 0, group)
