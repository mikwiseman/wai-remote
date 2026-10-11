#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
server_app="$PWD/build/WAI Remote Server.app"
if pgrep -f "^${server_app}/Contents/MacOS/WAI Remote Server" >/dev/null; then
  print -u2 'Stop WAI Remote Server before replacing its signed bundle.'
  exit 1
fi
signing_identity="${WAI_SIGN_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
  signing_identity=$(security find-identity -v -p codesigning | python3 -c 'import re,sys; names=re.findall(r"\"(Developer ID Application: [^\"]+)\"",sys.stdin.read()); print(names[0] if len(names)==1 else "")')
fi
[[ -n "$signing_identity" ]] || { print -u2 'Set WAI_SIGN_IDENTITY to a stable Apple signing identity.'; exit 1; }
mkdir -p "$server_app/Contents/MacOS" "$server_app/Contents/Resources"
(cd gateway && go build -trimpath -o "$server_app/Contents/MacOS/WAI Remote Server" .)
cp mac/Server-Info.plist "$server_app/Contents/Info.plist"
cp ios/Assets.xcassets/AppIcon.appiconset/AppIcon.png "$server_app/Contents/Resources/Icon.png"
codesign --force --sign "$signing_identity" --timestamp=none --options runtime "$server_app"
codesign --verify --deep --strict "$server_app"
printf '%s\n' "$server_app"
