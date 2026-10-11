#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
xcodegen generate --spec ios/project.yml
destination="${WAI_IOS_DESTINATION:-generic/platform=iOS}"
xcodebuild -project ios/WAIRemotePhone.xcodeproj -scheme WAIRemotePhone \
  -configuration Debug -destination "$destination" -derivedDataPath build/ios \
  -allowProvisioningUpdates build
