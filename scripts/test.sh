#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
developer_dir="$(xcode-select -p)"
if [[ "$developer_dir" == *CommandLineTools* ]]; then
  frameworks="$developer_dir/Library/Developer/Frameworks"
  scripts/swift.sh test --disable-xctest --enable-swift-testing -Xswiftc "-F$frameworks" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker "-F$frameworks" -Xlinker -rpath -Xlinker "$frameworks" "$@"
else
  scripts/swift.sh test --disable-xctest --enable-swift-testing "$@"
fi
