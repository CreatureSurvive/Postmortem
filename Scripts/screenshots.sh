#!/bin/sh
# Regenerates the README screenshots in Screenshots/ from the example app's UI tests.
set -eu
cd "$(dirname "$0")/../Example"
xcodegen generate --quiet
result=$(mktemp -d)/screenshots.xcresult
xcodebuild test -project PostmortemDemo.xcodeproj -scheme PostmortemDemo \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" \
  -only-testing:PostmortemDemoUITests/ScreenshotTests -resultBundlePath "$result" -quiet
../Scripts/export-screenshots.sh "$result" ../Screenshots
