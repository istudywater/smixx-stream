# Shared-audio extraction seed

Source: Smixx Desktop, https://github.com/istudywater/smixx-desktop, local clean commit `9ebfd444f2cc48c49003aa9d265e4c4b3443a9d2`, inspected November 5, 2026. This folder contains a pinned local package so Stream builds without a sibling checkout or network dependency. This is a transitional extraction, not a promise of automatic synchronization with Desktop.

Copied: `Sources/MixerDSP`, `Sources/SmixxCore`, corresponding state/native-audio tests and `Driver` including libASPL. The application-level `AudioHardware.swift` was adapted separately under Stream's Sources. Preserve the root MIT license, libASPL MIT license and Apple license files/author/revision notices.

Local changes:

- Swift package library products exposing existing DSP/model targets, macOS 14.2.
- Add atomic per-source host capture time metadata and capture wrapper. Existing DSP algorithms remain unchanged.
- Driver admits `org.smixx.stream`; atomically records writer client/PID, exposes `smow` owner property; retains Desktop and test-probe producers.
- Model compatibility marker v2 and bundle version 0.4.0; existing device UIDs retained.
- Driver contract tests cover Stream admission and competing writer behavior.

Do not silently vendor new upstream revisions. Record upstream revision, local delta and both apps' test evidence. Prefer replacing this folder with a tagged shared package once Desktop adopts the same interfaces. Do not use the inherited Desktop packaging/uninstall script for Stream.
