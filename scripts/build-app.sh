#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/swift.sh build -c release
app="dist/Smixx Stream.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/SmixxStream "$app/Contents/MacOS/SmixxStream"
cp scripts/Info.plist "$app/Contents/Info.plist"
cp Resources/SmixxStream.icns "$app/Contents/Resources/SmixxStream.icns"
cp LICENSE "$app/Contents/Resources/LICENSE"
cp Vendor/SmixxAudio/LICENSE "$app/Contents/Resources/SmixxAudio-LICENSE"
codesign --force --sign "${SMIXX_SIGN_ID:--}" "$app"
codesign --verify --strict "$app"
printf 'Built: %s/%s\n' "$PWD" "$app"
