#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" .build/swift-cache
command="${1:-build}"
shift || true
swift "$command" --disable-sandbox --cache-path "$PWD/.build/swift-cache" "$@"
