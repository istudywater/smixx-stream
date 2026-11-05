# Architecture — implemented alpha

`StreamCore` validates four visual slots, six audio channels, scaling, shared-audio identity and persistence. `SmixxStream` owns native UI and platform lifecycles. `Vendor/SmixxAudio` is a pinned local Swift package derived from Desktop; it exports `SmixxCore` and `MixerDSP`. The hardware adapter is currently app-local and still needs a clean shared-library facade.

Video adapters deliver timestamped CGImages from ScreenCaptureKit/AVFoundation or PDFKit. Per-slot generation tokens reject stale completion/frames; a bounded queue applies manual video delay. A SwiftUI Program canvas is used for studio preview and the clean output window. This is a window/display renderer, not yet an encoded network or virtual-camera Program pipeline. CGImage conversion at capture resolution is a correctness-first implementation; CPU/memory/performance at four simultaneous 1080p sources remains to be profiled. The queues are bounded at 18 frames per source.

Local AVPlayer audio is copied once through an audio processing tap into the mixer, then the player's normal output is silenced. The tap owns its context through Core Media's initialize/finalize lifecycle. Audio taps, hardware/process capture and each independent HAL output use the inherited single-producer/single-consumer ring boundaries. A source slot never deliberately attaches multiple audio producers. Program uses output index 0; Monitor index 3. Other inherited buses are unused by Stream.

Host-time metadata was added to capture for freshness/diagnostics, without replacing the inherited resampler. It is **not** a complete timestamp-addressed A/V pipeline. Manual frame delay is the initial compensation; encoded outputs and automatic synchronization are future work. Local Monitor does not depend on a receiver callback.

Audio input assignments are distinct from visual sources. A duplicated application/overlapping hardware assignment is rejected on later channels. Known native meeting apps are excluded. Browser-hosted meeting return cannot be detected by the application-level capture model; the supported initial workflow uses separate apps.

Program/Monitor route changes close prior endpoints before opening replacements. Missing devices never select system defaults. Presentation, monitoring and source activation are transient; presets never restore external transmission. Stream uses its own Application Support directory and schema. Invalid files are preserved and reset requires a backup.

Remaining extraction work: generic audio facade, timestamped Program export, robust media-seek buffer flushing, driver lifecycle manager, exhaustive source/device fault observation, automated UI/integration coverage and performance tuning. See verification for current evidence; do not infer production readiness from the architecture names.
