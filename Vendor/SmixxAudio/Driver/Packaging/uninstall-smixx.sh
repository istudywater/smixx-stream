#!/bin/bash
set -euo pipefail
if [[ $EUID -ne 0 ]]; then
  echo 'Run with sudo. This removes the Smixx app and audio driver, but preserves user settings.' >&2
  exit 1
fi
if [[ "${1:-}" != "--confirm" ]]; then
  echo 'Close Smixx and all audio apps, then run this script with --confirm.' >&2
  exit 2
fi
# Fixed product paths only. Never remove other HAL plug-ins or user settings.
rm -rf '/Library/Audio/Plug-Ins/HAL/SmixxAudio.driver' '/Applications/Smixx Desktop.app'
pkgutil --forget org.smixx.desktop.prototype >/dev/null 2>&1 || true
echo 'Smixx was removed. Restart your Mac to unload the driver safely.'
echo 'Alternatively, after closing all audio apps, restart Core Audio explicitly.'
