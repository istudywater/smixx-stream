#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache Resources
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" swiftc scripts/Icon.swift -o .build/make-icon
.build/make-icon .build/SmixxStream.iconset
iconutil -c icns .build/SmixxStream.iconset -o Resources/SmixxStream.icns
