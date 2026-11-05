#!/bin/zsh
# Builds build/Snow.app (menu bar app, no Dock icon).
set -e
cd "$(dirname "$0")"
APP=build/Snow.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
  Sources/*.swift -o "$APP/Contents/MacOS/Snow"
# Ad-hoc signature with a designated requirement tied to the bundle id (not the binary hash),
# so the Accessibility permission survives rebuilds.
codesign --force --sign - -r='designated => identifier "com.jeong.snow"' "$APP"
echo "Built $APP"
