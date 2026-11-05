# Smixx Stream

Native macOS teaching-media switcher in The Smixx Project. **Version 0.1.0 is an engineering alpha**, with a runnable local app and shared-audio integration work. It is not a certified classroom/conferencing release.

## Run

Build with Swift 6 / macOS developer tools:

```sh
scripts/build-app.sh
open 'dist/Smixx Stream.app'
```

Deployment target: macOS 14.2. Built and inspected on Apple Silicon; minimum-version and Intel operation are not verified. Local builds are ad-hoc signed, not Developer ID signed/notarized for public distribution. Open `Package.swift` in Xcode if using the IDE.

## Current implementation

- Four camera, window, display, PDF or local-media source slots; one selected Program image.
- ScreenCaptureKit window/display capture and AVFoundation camera capture.
- Native PDF page navigation and zoom; local video/audio play, pause and seek.
- Fit/Fill composition and a controls-free Program window; secondary-display presentation.
- Six input channels plus Monitor and Program masters, using Desktop-derived native audio DSP.
- Hardware-channel/application capture, duplicate-source checks, muted-by-default inputs, independent microphone monitoring and known meeting-app exclusion.
- Separate Stream settings with validation/atomic saves; saved sources reconnect explicitly; outputs start off.
- Two layouts, keyboard source switching, pause slate, source recovery and local diagnostics export.

Implementation is distinct from hardware acceptance. See [verification](docs/VERIFICATION.md) for what was actually tested.

## First lesson

1. Click a source tile or its configuration button. Choose a PDF, local media, camera or window. Grant macOS permissions only for the sources you intend to use.
2. Switch with a click or Command–1…4. Configure sources with the separate ellipsis button. PDF and playback controls appear below Program.
3. Use each audio strip's connector menu to assign audio. Enable the channel with **Muted / On**. Browser audio is application-wide. Two browser windows cannot become independently isolated channels merely by selecting both.
4. In Settings, choose **Program audio** and optionally separate **Monitor headphones**. Enable Monitor only when needed. Microphone monitoring is controlled per input; avoid doubling hardware direct monitoring.
5. Click **Present** for the clean window or an external display. **Pause** blanks video and silences Program audio; local monitoring remains separate. Closing Program stops presentation.

For conferencing, share the clean Program window and select a compatible Smixx Bus as the meeting microphone. Keep meeting speakers on headphones, exclude the meeting application from Stream capture, and disable duplicate meeting share-audio. Do not capture a browser that also hosts the meeting. Conference reception needs a real second-participant test.

## Shared audio driver

Desktop's older driver does not admit Stream. An updated, source-compatible driver candidate is included in `Vendor/SmixxAudio/Driver`. `scripts/build-driver.sh` builds and tests it into `dist/SmixxAudio.driver`; **it does not install a driver or restart audio**.

The candidate preserves device UIDs, admits `org.smixx.stream`, reports writer ownership and retains one writer per bus. Stream conservatively refuses virtual output while Desktop or the transport probe is running. Source code and in-process tests do not prove installed HAL delivery. See [driver guidance](docs/SHARED-AUDIO.md) before attempting system deployment. Physical Program audio and local media do not require this driver.

## Explicit limits

- Integrated Google Cast, direct AirPlay streaming, virtual camera and recording are not implemented.
- System-managed extended AirPlay displays may be selectable as displays, but receiver audio/sync are unverified.
- Manual video-delay adjustment is available. Automatic timestamp-aligned A/V export and long-session sync are not complete.
- Camera/browser capture, physical device reconnect, classroom TVs and real conferencing calls still require live acceptance.
- Protected media is unsupported; black frames are not automatically classified as DRM.
- Output does not silently fall back to another device. A disconnected source needs explicit reconnection.

## Development

```sh
scripts/test.sh                         # Stream state/routing tests
scripts/test.sh --package-path Vendor/SmixxAudio  # inherited state tests
scripts/test-audio.sh                   # native macOS Audio Unit signal tests
scripts/build-driver.sh                 # driver timeline/contract tests + build
scripts/build-app.sh                    # release app + signature verification
```

Audio Unit tests require normal access to macOS audio services; restrictive execution sandboxes can prevent unit initialization. Build scripts use repository-local compiler caches. The `--preview` argument skips device inventory, audio routing and settings persistence and can exercise local PDF/media presentation without camera capture.

The authoritative planning package is in the Obsidian `the-smixx-project/02-Smixx-Stream` folder. [Architecture](docs/ARCHITECTURE.md), [shared-code provenance](Vendor/SmixxAudio/PROVENANCE.md) and [verification](docs/VERIFICATION.md) describe this repository's current state. MIT license; retain vendored notices.
