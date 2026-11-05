# Verification — November 5, 2026

Engineering alpha 0.1.0, Apple Silicon, Swift 6.2.4 command-line tools. Deployment target is 14.2, not a claim of minimum-OS acceptance. No driver was installed, no audio service restarted and no Desktop source changed.

| Check | Result and boundary |
| --- | --- |
| Debug and release app build | Passed; local app bundle produced and ad-hoc code signature verified |
| Stream state/routing tests | 5 passed: invalid state rejection, PDF Fit/Fill geometry, duplicate application ownership, known meeting return exclusion, atomic roundtrip/corrupt-file preservation |
| Extracted audio package state tests | 14 passed in the local package, matching the baseline |
| Original Desktop baseline | 14 Swift tests reproduced against original checkout using a scratch directory in Stream; checkout unchanged |
| Native audio DSP/AU tests | Passed at 44.1/48/96 kHz with six sources, monitor/send isolation, resampling and limiter/effect checks; sandbox initially prevented AU preparation, rerun with normal macOS service access passed |
| Driver timeline/contract | Passed, including Stream admission, writer conflict/release, owner PID, multiple readers, stale-frame silence and concurrent timeline reads/writes; in-process only |
| Native UI | Opened and visually inspected main window and Settings; corrected Present control styling, scaling-label clipping and accessibility labels |
| PDF workflow | Generated local two-page fixture, loaded through native file picker, changed to page 2, verified actual clean Program rendering |
| Pause/close workflow | Pause showed neutral slate in Program; closing Program returned studio to Not presenting |
| Local media | Generated H.264/AAC fixture, loaded through file picker, verified time progression, video frames and playback controls; no physical audio destination enabled |
| Camera and browser capture | Implemented/compiled, not exercised with permissions/live sources during this pass |
| Installed driver / real conference / wired TV | Not run; requires actual destination and separately managed shared-driver deployment |
| Casting, virtual camera, recording | Not implemented |
| Physical latency / long-session A/V / four-source performance | Not measured; manual video delay available; automatic alignment remains incomplete |
| Public distribution | Not Developer ID signed/notarized; no release uploaded |

The first Swift invocations encountered restricted compiler-cache writes and CLT Swift Testing discovery. Repository-local cache paths and the CLT framework flags in `scripts/test.sh` resolve these without changing global developer settings.

## Next live acceptance session

1. Connect the intended microphone/interface, camera and wired display; record devices and OS versions.
2. Configure PDF, browser video, camera and a local media file. Check permissions and source reconnect; no silent substitution.
3. Select physical outputs, enable channels individually and verify independent Monitor/Program behavior and no doubled original playback.
4. Measure visual/audio pulse alignment at the actual destination; run at least 60 minutes and record drift/dropouts.
5. On a test machine, deploy the reviewed shared driver candidate and verify installed delivery before attempting a two-party meeting. Validate old/new Desktop combinations and restoration.
6. Confirm that the remote participant receives readable content, microphone and media exactly once, with no meeting return feedback.

Do not publish a supported receiver/client claim before this evidence exists. The Obsidian compatibility plan remains the longer-term acceptance reference.
