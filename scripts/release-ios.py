#!/usr/bin/env python3
"""Archive and export WAI Remote with the existing App Store signing identity.

Pass --upload after validation to send the archive to App Store Connect.
Credentials stay in ~/.appstoreconnect; no values are written to the repository.
"""
import argparse
import json
import os
import re
from pathlib import Path
import plistlib
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--upload", action="store_true")
parser.add_argument("--build", default="62")
parser.add_argument("--version", default="0.3.3")
parser.add_argument("--profile", required=True, help="UUID of an installed App Store provisioning profile")
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
os.chdir(root)
config = json.loads((Path.home() / ".appstoreconnect/config.json").read_text())
keychain = Path.home() / ".appstoreconnect/aigid-appstore.keychain-db"
credentials = ["-authenticationKeyPath", str(Path(config["key_filepath"]).expanduser()),
               "-authenticationKeyID", config["key_id"], "-authenticationKeyIssuerID", config["issuer_id"]]
release = root / ".release" / f"ios-{args.version}-{args.build}"
release.mkdir(parents=True, exist_ok=True)
archive = release / "WAI Remote.xcarchive"
def run(command):
    subprocess.run([str(value) for value in command], check=True)
run([Path.home() / ".local/bin/wai-signing", "prepare", "ios"])
identities = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning", str(keychain)], text=True)
matching = re.findall(r'([0-9A-F]{40}) "Apple Distribution:', identities)
if len(matching) != 1:
    raise SystemExit("The release keychain must contain one existing Apple Distribution identity")
identity = matching[0]
run(["xcodegen", "generate", "--spec", "ios/project.yml"])
run(["xcodebuild", "archive", "-project", "ios/WAIRemotePhone.xcodeproj", "-scheme", "WAIRemotePhone",
     "-configuration", "Release", "-destination", "generic/platform=iOS", "-archivePath", archive,
     "-derivedDataPath", Path.home() / "Library/Caches/WAIRemoteBuilds/ios-release",
     f"OTHER_CODE_SIGN_FLAGS=--keychain {keychain}", "CODE_SIGN_STYLE=Manual", f"CODE_SIGN_IDENTITY={identity}",
     f"PROVISIONING_PROFILE_SPECIFIER={args.profile}",
     f"CURRENT_PROJECT_VERSION={args.build}", f"MARKETING_VERSION={args.version}"])
options = {"method": "app-store-connect", "destination": "upload" if args.upload else "export",
           "teamID": "R4A779QVVY", "signingStyle": "manual", "signingCertificate": identity,
           "provisioningProfiles": {"is.wai.remote.ios": args.profile},
           "manageAppVersionAndBuildNumber": False, "uploadSymbols": True}
options_path = release / "ExportOptions.plist"
options_path.write_bytes(plistlib.dumps(options))
run(["xcodebuild", "-exportArchive", "-archivePath", archive, "-exportPath", release / "export",
     "-exportOptionsPlist", options_path, *credentials, f"OTHER_CODE_SIGN_FLAGS=--keychain {keychain}"])
print("Uploaded to App Store Connect" if args.upload else f"Exported to {release / 'export'}")
