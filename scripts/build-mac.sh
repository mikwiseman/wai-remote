#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
configuration="${WAI_CONFIGURATION:-debug}"
build_root="${WAI_SWIFT_SCRATCH_PATH:-$PWD/.build}"
build_args=(-c "$configuration" --scratch-path "$build_root" --jobs "${WAI_BUILD_JOBS:-2}")
if [[ "${WAI_UNIVERSAL:-0}" == 1 ]]; then build_args+=(--arch arm64 --arch x86_64); fi
swift build "${build_args[@]}"
bin_dir=$(swift build "${build_args[@]}" --show-bin-path)
app_path="${WAI_APP_PATH:-$PWD/build/WAI Remote.app}"
if pgrep -f "^${app_path}/Contents/MacOS/WAIRemote$" >/dev/null; then
  print -u2 'Quit this WAI Remote bundle before replacing it, or set WAI_APP_PATH to a staging directory.'
  exit 1
fi
signing_identity="${WAI_SIGN_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
  signing_identity=$(security find-identity -v -p codesigning | python3 -c 'import re,sys; names=re.findall(r"\"(Developer ID Application: [^\"]+)\"",sys.stdin.read()); print(names[0] if len(names)==1 else "")')
fi
if [[ -z "$signing_identity" ]]; then
  print -u2 'Set WAI_SIGN_IDENTITY to the stable Developer ID identity.'
  exit 1
fi
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Frameworks" "$app_path/Contents/Resources"
cp "$bin_dir/WAIRemote" "$app_path/Contents/MacOS/WAIRemote"
cp "$bin_dir/WAIRemoteWatchdog" "$app_path/Contents/MacOS/WAIRemoteWatchdog"
mkdir -p "$app_path/Contents/Library/LaunchAgents"
cp mac/is.wai.remote.recovery.plist "$app_path/Contents/Library/LaunchAgents/"
ditto "$build_root/artifacts/webrtc/WebRTC/WebRTC.xcframework/macos-x86_64_arm64/WebRTC.framework" "$app_path/Contents/Frameworks/WebRTC.framework"
ditto "$build_root/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$app_path/Contents/Frameworks/Sparkle.framework"
cp mac/Info.plist "$app_path/Contents/Info.plist"
mkdir -p "$app_path/Contents/Resources/Licenses"
cp LICENSE THIRD_PARTY.md "$app_path/Contents/Resources/Licenses/"
cp -f licenses/*.txt "$app_path/Contents/Resources/Licenses/"
swift scripts/export-menu-icon.swift
cp mac/Resources/MenuTemplate*.png "$app_path/Contents/Resources/"
xcrun actool mac/AppIcon.icon --compile "$app_path/Contents/Resources" --platform macosx --minimum-deployment-target 15.0 --app-icon AppIcon --output-partial-info-plist "$app_path/Contents/Resources/icon-info.plist" > /dev/null
python3 - "$app_path/Contents/Info.plist" <<'PY'
import os,plistlib,sys
from pathlib import Path
p=Path(sys.argv[1]); d=plistlib.loads(p.read_bytes())
for env,key in [('WAI_BUILD_NUMBER','CFBundleVersion'),('WAI_VERSION','CFBundleShortVersionString'),('WAI_FEED_URL','SUFeedURL')]:
    if os.environ.get(env): d[key]=os.environ[env]
p.write_bytes(plistlib.dumps(d))
PY
if ! otool -l "$app_path/Contents/MacOS/WAIRemote" | rg -q '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath @executable_path/../Frameworks "$app_path/Contents/MacOS/WAIRemote"
fi
sign_args=(--force --sign "$signing_identity" --options runtime)
if [[ "$signing_identity" == - ]]; then sign_args+=(--timestamp=none); else sign_args+=(--timestamp); fi
if [[ -n "${WAI_SIGN_KEYCHAIN:-}" ]]; then sign_args+=(--keychain "$WAI_SIGN_KEYCHAIN"); fi
sparkle="$app_path/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign "${sign_args[@]}" "$sparkle/XPCServices/Installer.xpc"
codesign "${sign_args[@]}" --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
codesign "${sign_args[@]}" "$sparkle/Autoupdate"
codesign "${sign_args[@]}" "$sparkle/Updater.app"
codesign "${sign_args[@]}" "$app_path/Contents/Frameworks/Sparkle.framework"
codesign "${sign_args[@]}" "$app_path/Contents/Frameworks/WebRTC.framework"
codesign "${sign_args[@]}" "$app_path/Contents/MacOS/WAIRemoteWatchdog"
codesign "${sign_args[@]}" --entitlements mac/WAIRemote.entitlements "$app_path"
codesign --verify --deep --strict "$app_path"
printf '%s\n' "$app_path"
