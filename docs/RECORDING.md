# Local Program recording — 0.3.0

Choose **Record lesson**, select a new `.mp4` filename, and enable the audio channels students should hear. Choose **Stop & Save** and wait for finalization. **Show saved video** reveals the completed file in Finder for manual upload to your learning platform.

Recordings contain the selected Program picture, including PDF page changes, zoom, source changes and local video playback, plus the Program audio mix. The format is 1920 × 1080 H.264 (target 30 fps) with stereo 48 kHz AAC audio. Recording works without a connected TV, physical audio output or virtual audio driver. Monitor gain does not change the recording; channel mute/gain and Program master gain do. Muted channels record silence. Preview mode disables recording.

**Pause presentation** records a neutral slate and silence while time continues. It is not a recording-pause/edit operation. Closing or stopping the external presentation leaves recording active. Quitting during recording requests finalization before exit; while a save is already in progress, wait and quit again.

The app writes a hidden sibling partial file and moves it to the chosen filename only after successful finalization. Existing files are never overwritten. Encoding, disk or sustained audio-backlog failures stop recording and show an error. An unfinished partial MP4 is not guaranteed playable; a completed file that could not be moved can be recovered at the path in the error. This release does not provide crash recovery, segmented recording or automatic upload.

## Implementation

`StreamMedia.ProgramComposition` supplies the common picture renderer for preview, clean display and recording. `ProgramRecorder` uses a serial encoder queue, a single-snapshot mailbox, host-clock video timestamps and a 48 kHz audio sample timeline. The shared DSP's independent consumer 1 supplies Program audio; physical Program remains consumer 0 and Monitor consumer 3. No encoding or file I/O runs on capture callbacks.

The annotation interface and PNG export are implemented; see [ANNOTATION-SPEC.md](ANNOTATION-SPEC.md). Live strokes enter the common composition and appear in recordings. The required filename/page/timestamp footer is for PNG exports; this release does not burn that footer into videos.

## Validation and limitations

Automated tests encode and decode a real MP4, check both tracks, source-picture changes, non-silent decoded audio, track duration agreement and existing-file protection. A separate test exercises the actual shared DSP recording consumer without physical outputs and verifies mute behavior. These are short synthetic tests, not evidence of physical microphone/camera synchronization or hour-long stability. Run a representative lesson with the intended hardware before relying on this alpha for class. Automatic source synchronization and long-session performance remain to be validated.
