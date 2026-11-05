#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
clang -std=c11 -O2 -I Vendor/SmixxAudio/Sources/MixerDSP/include Vendor/SmixxAudio/Tests/Audio/EffectsTests.c Vendor/SmixxAudio/Sources/MixerDSP/MixerDSP.c Vendor/SmixxAudio/Sources/MixerDSP/SMEffects.c -framework CoreAudio -framework AudioToolbox -o .build/effects-tests
.build/effects-tests
