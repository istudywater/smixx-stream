# Shared audio implementation and deployment

## Reuse boundary

The local `SmixxAudio` package is a version-pinned extraction seed from Desktop commit `9ebfd444f2cc48c49003aa9d265e4c4b3443a9d2`. It is not yet a separately published ecosystem dependency. Desktop's working checkout and installed driver were not changed. The next shared-library milestone is to publish these boundaries once both applications can consume them without parallel copies.

The driver candidate keeps the three existing endpoint UIDs. Changes: Stream producer admission; atomic writer client/PID ownership; read-only `smow` (0x736d6f77) property reporting owner PID as a CFString; model UID `org.smixx.audio.virtual.v2` so Stream can reject a legacy driver; version 0.4.0. Device UIDs and Desktop admission remain stable. Driver filtering is routing control, not a security boundary.

Tests exercise Stream admission, blocked takeover while Desktop owns a bus, ownership release and subsequent delivery, PID reporting, unrelated-writer rejection and multiple readers. No installed HAL test was performed. Stream checks ownership and conservatively rejects virtual output while Desktop/probe runs. Existing Desktop releases do not read the new ownership property; simultaneous app operation remains outside this alpha's support.

## Build and deployment boundary

Run `scripts/build-driver.sh` to produce an ad-hoc signed bundle. This build never installs it. Installation would replace the machine-wide driver used by Desktop and requires a separate planned acceptance session, administrator privileges, closed audio applications, a recoverable copy of the existing driver, and a restart/reload strategy. Do not run inherited Desktop uninstall scripts: they remove the shared driver along with Desktop.

A production shared component still needs an independent installer receipt, dependency-aware removal/upgrade policy, Developer ID signing/notarization, old/new application compatibility checks and recovery instructions validated on a test machine. The inherited packaging directory is reference source only; no production Stream installer is supplied.

Until that session, test Stream with physical Program audio or video-only clean-window output. Do not claim conference audio through an old Desktop-only driver. A successful endpoint open is not remote-listener confirmation.

## Audio limitations

The inherited transport contributes 2,048 frames at 48 kHz (42.67 ms); DSP padding/limiting and ring/device buffering add delay. The engine's capture-host-time metadata does not by itself synchronize video. Verify actual destination offset and use manual video compensation during prototype tests. Rate conversion is inherited; physical drift, source replacement and 60-minute sessions remain unverified.
