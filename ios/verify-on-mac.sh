#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift test --package-path TransitCore
xcodebuild -resolvePackageDependencies -project TaipeiBus.xcodeproj -scheme TaipeiBus
xcodebuild -project TaipeiBus.xcodeproj -scheme TaipeiBus -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ../work/ios-build CODE_SIGNING_ALLOWED=NO build
echo 'Native core tests and iOS Simulator compilation passed.'
