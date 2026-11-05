#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cmake -S Vendor/SmixxAudio/Driver -B .build/driver -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_SYSROOT="$(xcrun --show-sdk-path)"
cmake --build .build/driver -j 4
ctest --test-dir .build/driver --output-on-failure
bundle=".build/driver/SmixxAudio.driver"
mkdir -p "$bundle/Contents/Resources/libASPL" dist
cp Vendor/SmixxAudio/Driver/ThirdParty/libASPL/LICENSE* Vendor/SmixxAudio/Driver/ThirdParty/libASPL/AUTHORS.md Vendor/SmixxAudio/Driver/ThirdParty/libASPL/REVISION "$bundle/Contents/Resources/libASPL/"
codesign --force --sign "${SMIXX_SIGN_ID:--}" "$bundle"
codesign --verify --strict "$bundle"
ditto "$bundle" dist/SmixxAudio.driver
printf 'Built driver only; nothing was installed or restarted.\n'
