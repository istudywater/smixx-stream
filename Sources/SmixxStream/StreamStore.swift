import AppKit
import SwiftUI
import AVFoundation
import ScreenCaptureKit
import UniformTypeIdentifiers
import StreamCore
import SmixxCore
import StreamMedia
import MixerDSP

@MainActor final class StreamStore: ObservableObject {
    @Published var state = StreamState()
    @Published var recording = false
    @Published var recordingBusy = false
    @Published var recordingSeconds = 0
    @Published var recordingError: String?
    @Published var savedRecording: URL?
    @Published var programImage: CGImage?
    private var recorder: ProgramRecorder?
    private var recordingStart: Date?
    private var finishingTask: Task<Void,Never>?
    var renderSignature = ""
    var recordingInProgress: Bool { recording || recordingBusy }
    @Published var annotationTool: AnnotationTool = .hand
    @Published var inkColor = 0
    @Published var inkWidth = 4.0
    @Published var annotationRevision = 0
    @Published var annotationError: String?
    @Published var savedHandout: URL?
    var histories: [String: InkHistory] = [:]
    var frozen: [String: CapturedFrame] = [:]
    var snapshots: [String: CapturedFrame] = [:]
    var pans: [String: InkPoint] = [:]
    var draft: InkStroke?
    var draftContext: String?
    var annotationSaveTask: Task<Void,Never>?
    var annotationLoadFailed = false
    let annotationArchive = AnnotationArchive()
    var displayedFrame: CapturedFrame? {
        guard let live = frames[state.active] else { return nil }
        return frozen[live.sourceID] ?? live
    }
    var composition: ProgramComposition {
        let source = state.sources[state.active]
        let frame = displayedFrame
        var result = ProgramComposition(image: frame?.image, scaling: source.scaling,
            zoom: source.zoom,
            slate: paused ? "Presentation paused" : frame == nil ? "Ready for the lesson" : nil)
        result.pan = pans[frame?.sourceID ?? ""] ?? InkPoint(0,0)
        result.strokes = histories[frame?.contextID ?? ""]?.strokes ?? []
        if let draft, draftContext == frame?.contextID { result.strokes.append(draft) }
        return result
    }
    @Published var frames: [CapturedFrame?] = Array(repeating: nil, count: 4)
    @Published var sourceStatus = Array(repeating: "Choose a teaching source", count: 4)
    @Published var presenting = false
    @Published var paused = false
    @Published var message = "Prepare your sources, then open Program to present."
    @Published var configuring: Int?
    @Published var setup = false
    @Published var windows: [SCWindow] = []
    @Published var displays: [SCDisplay] = []
    @Published var pickerError = ""
    @Published var loadingPicker = false
    @Published var playhead = 0.0
    @Published var duration = 0.0
    @Published var playing = false
    @Published var pageCount = 0
    let audio: AudioEngine
    let preview: Bool
    let temporarySession: Bool
    var sessions: [Int: VideoSourceSession] = [:]
    private var generations = Array(repeating: UUID(), count: 4)
    private var pending: [Int: [CapturedFrame]] = [:]
    private var timer: Timer?
    private var saveTask: Task<Void, Never>?
    private var outputWindow: NSWindow?
    private var outputClosing: NSObjectProtocol?
    private var sourceTasks: [Int: Task<Void, Never>] = [:]
    private var loadFailed = false
    private let configurationURL: URL
    init() {
        temporarySession = ProcessInfo.processInfo.arguments.contains("--temporary-session")
        preview = ProcessInfo.processInfo.arguments.contains("--preview")
        audio = AudioEngine(preview: preview)
        configurationURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SmixxStream/configuration.json")
        if !preview && !temporarySession && FileManager.default.fileExists(atPath: configurationURL.path) {
            do {
                state = try StateFile.read(configurationURL)
                message = "Preset restored. Reconnect sources before presenting; outputs remain off."
                for i in 0..<4 where state.sources[i].kind != .empty { sourceStatus[i] = "Saved source · click Reconnect" }
            } catch { loadFailed = true; message = "Saved settings could not be read and were preserved. Export diagnostics, then use Reset settings in Setup." }
        }
        if preview {
            let names = ["Instrument camera", "Browser lesson", "Practice score", "Presentation"]
            for i in 0..<4 { state.sources[i].name = names[i]; sourceStatus[i] = "Design preview · no capture" }
        }
        if !preview && !temporarySession { loadAnnotations() }
        let refresh = Timer(timeInterval: 1.0/30, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        RunLoop.main.add(refresh, forMode: .common)
        timer = refresh
    }
    func changed() {
        audio.recordingMuted = paused
        if !preview { audio.reconcile(state, presenting: presenting && !paused) }
        saveTask?.cancel()
        guard !preview && !temporarySession && !loadFailed else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            do { try StateFile.write(state, to: configurationURL) } catch { message = "Settings were not saved: \(error.localizedDescription)" }
        }
    }
    func select(_ index: Int) {
        guard state.sources[index].kind != .empty else { configuring = index; return }
        finishStroke(); state.active = index; playhead = 0; duration = 0; pageCount = 0; changed()
    }
    func loadPicker() async {
        loadingPicker = true; pickerError = ""; defer { loadingPicker = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            windows = content.windows.filter { $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier && $0.frame.width > 80 && $0.frame.height > 60 }.sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
            displays = content.displays
        } catch { pickerError = "Screen access is unavailable: \(error.localizedDescription). Enable Smixx Stream in System Settings → Privacy & Security → Screen & System Audio Recording." }
    }
    func configure(_ index: Int, kind: StreamCore.SourceKind, name: String, identifier: String, url: URL? = nil, appBundle: String? = nil) {
        var source = VisualSource(id: index); source.kind = kind; source.name = name; source.identifier = identifier
        if let url { source.bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) }
        state.sources[index] = source
        state.channels[index].sourceIdentity = ""; state.channels[index].muted = true
        if let appBundle {
            audio.refresh()
            if let app = audio.availableInputs.first(where: { $0.kind == .application && $0.uid == appBundle && $0.routeAppPlayback }) { state.channels[index].sourceIdentity = app.identity }
        }
        configuring = nil; reconnect(index); changed()
    }
    func chooseFile(_ index: Int, pdf: Bool) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = pdf ? [.pdf] : [.movie, .audio]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        configure(index, kind: pdf ? .pdf : .media, name: url.deletingPathExtension().lastPathComponent, identifier: url.path, url: url)
    }
    func reconnect(_ index: Int) {
        guard !preview || [.pdf, .media].contains(state.sources[index].kind) else { return }
        let generation = UUID(); generations[index] = generation
        let previousTask = sourceTasks[index]
        previousTask?.cancel()
        let old = sessions.removeValue(forKey: index)
        frames[index] = nil; pending[index] = []; audio.sourceFailures.insert(index); audio.apply()
        sourceStatus[index] = "Connecting…"
        let source = state.sources[index]
        sourceTasks[index] = Task { [weak self] in
            guard let self else { return }
            await previousTask?.value
            if let old { await old.stop() }
            guard generations[index] == generation, !Task.isCancelled else { return }
            audio.setMedia(index, enabled: source.kind == .media)
            let session = VideoSourceSession()
            session.frame = { [weak self] frame in
                Task { @MainActor in
                    guard let self, self.generations[index] == generation else { return }
                    var queue = self.pending[index] ?? []; queue.append(frame)
                    if queue.count > 18 { queue.removeFirst(queue.count-18) }
                    self.pending[index] = queue
                }
            }
            session.onFailure = { [weak self] text in Task { @MainActor in self?.fail(index, generation: generation, text: text) } }
            sessions[index] = session
            do {
                try await session.start(source, audio: audio, slot: index)
                guard generations[index] == generation, !Task.isCancelled else { await session.stop(); return }
                sourceStatus[index] = source.kind == .media ? "Ready · press Play" : "Connected"
                audio.sourceFailures.remove(index); changed()
            } catch {
                if generations[index] == generation { fail(index, generation: generation, text: error.localizedDescription) }
                await session.stop()
            }
        }
    }
    private func fail(_ index: Int, generation: UUID, text: String) {
        guard generations[index] == generation else { return }
        generations[index] = UUID() // Invalidate late frames after failure; recovery is explicit.
        sourceStatus[index] = text; frames[index] = nil; pending[index] = []
        audio.sourceFailures.insert(index); audio.apply()
    }
    func clear(_ index: Int) {
        state.sources[index] = VisualSource(id: index); state.channels[index] = AudioChannel(); generations[index] = UUID()
        sourceTasks[index]?.cancel(); pending[index] = []; frames[index] = nil; sourceStatus[index] = "Choose a teaching source"
        if let old = sessions.removeValue(forKey: index) { Task { await old.stop() } }
        audio.setMedia(index, enabled: false); changed(); configuring = nil
    }
    func turnPage(_ change: Int) {
        guard let session = sessions[state.active], let document = session.document else { return }
        state.sources[state.active].page = min(max(0, state.sources[state.active].page + change), document.pageCount-1)
        finishStroke(); state.sources[state.active].zoom = 1
        pans[session.sourceID] = InkPoint(0,0)
        session.renderPDF(page: state.sources[state.active].page, zoom: 1); changed()
    }
    func togglePlay() {
        guard let player = sessions[state.active]?.player else { return }
        finishStroke(); if let id = frames[state.active]?.sourceID { frozen.removeValue(forKey: id) }; annotationRevision += 1
        if player.rate > 0 { player.pause() }
        else { if duration > 0 && playhead >= duration-0.1 { player.seek(to: .zero) }; player.play() }
    }
    func seek(_ seconds: Double) {
        finishStroke(); if let id = frames[state.active]?.sourceID { frozen.removeValue(forKey: id) }; annotationRevision += 1
        sessions[state.active]?.player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func openProgram(screen: NSScreen? = nil) {
        if let outputClosing { NotificationCenter.default.removeObserver(outputClosing); self.outputClosing = nil }
        if let window = outputWindow { window.close() }
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 960,height: 540), styleMask: screen == nil ? [.titled,.closable,.miniaturizable,.resizable] : [.borderless], backing: .buffered, defer: false)
        window.title = "Smixx Stream — Program"; window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.contentView = NSHostingView(rootView: ProgramCanvas(store: self, output: true))
        if let screen { window.setFrame(screen.frame, display: true); window.level = .normal } else { window.center() }
        outputWindow = window
        if let outputClosing { NotificationCenter.default.removeObserver(outputClosing) }
        outputClosing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in Task { @MainActor in if self?.outputWindow === window { self?.stopPresentation(closeWindow: false) } } }
        presenting = true; paused = false; window.makeKeyAndOrderFront(nil); changed()
        message = "Program window open. Choose its window in your meeting app; configure Program audio in Setup."
    }
    func stopPresentation(closeWindow: Bool = true) {
        presenting = false
        if !recordingInProgress { paused = false }
        message = recording ? "Display presentation stopped; recording continues." : "Presentation stopped. Preview and source controls remain available."
        if closeWindow { outputWindow?.close(); outputWindow = nil }
        changed()
    }
    func togglePause() { paused.toggle(); changed() }
    func startRecording() {
        guard !recordingInProgress else { return }
        guard !preview else { message = "Recording requires normal mode. Quit and reopen the app without --preview."; return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        panel.nameFieldStringValue = "Smixx-Lesson-\(formatter.string(from: Date())).mp4"
        panel.title = "Save Program recording"
        panel.message = "Records Program video and enabled audio channels. Monitor volume does not affect the recording. Existing files are not overwritten."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recordingBusy = true; recordingError = nil; savedRecording = nil
        Task {
            do {
                let dsp = audio.dsp
                let session = try ProgramRecorder(url: url, initial: composition, renderAudio: { buffers in sm_render(dsp, 1, buffers, 48000) }, onFailure: { [weak self] error in
                    Task { @MainActor in self?.recordingFailed(error) }
                })
                audio.recordingMuted = paused
                try audio.prepareRecording()
                recorder = session
                try await session.start()
                recording = true; recordingBusy = false; recordingStart = Date(); recordingSeconds = 0
                changed()
                message = "Recording Program locally. Enable your microphone/media channels; muted channels record silence."
            } catch { recordingFailed(error.localizedDescription) }
        }
    }
    private func recordingFailed(_ text: String) {
        recording = false; recordingBusy = false; recordingStart = nil
        audio.endRecording(); recorder = nil
        recordingError = text; message = "Recording failed: \(text)"
    }
    func stopRecording() async {
        if let finishingTask { await finishingTask.value; return }
        guard let recorder, recording else { return }
        recording = false; recordingBusy = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await recorder.finish()
                savedRecording = result.url; recordingSeconds = Int(result.duration)
                message = "Saved Program recording: \(result.url.lastPathComponent)"
            } catch { recordingError = "\(error.localizedDescription) Partial file, if present: \(recorder.partialURL.path)"; message = recordingError! }
            audio.endRecording(); self.recorder = nil; recordingStart = nil; recordingBusy = false
            if !presenting { paused = false; changed() }
        }
        finishingTask = task
        await task.value
        finishingTask = nil
    }
    func revealRecording() { if let savedRecording { NSWorkspace.shared.activateFileViewerSelecting([savedRecording]) } }
    private func tick() {
        for session in sessions.values { session.pollMedia() }
        let cutoff = CACurrentMediaTime() - state.videoDelayMS/1000
        for i in 0..<4 {
            guard var queue = pending[i], let index = queue.lastIndex(where: { $0.hostTime <= cutoff }) else { continue }
            frames[i] = queue[index]; queue.removeFirst(index+1); pending[i] = queue
        }
        let source = state.sources[state.active]
        let signature = "\(state.active):\(frames[state.active]?.hostTime ?? -1):\(source.scaling):\(source.zoom):\(paused):\(annotationRevision)"
        if signature != renderSignature {
            let snapshot = composition
            programImage = snapshot.render()
            recorder?.update(snapshot)
            renderSignature = signature
        }
        if let recordingStart { recordingSeconds = Int(Date().timeIntervalSince(recordingStart)) }
        if let session = sessions[state.active] {
            pageCount = session.document?.pageCount ?? 0
            if let player = session.player {
                let d = player.currentItem?.duration.seconds ?? 0; duration = d.isFinite ? max(d,0) : 0
                let t = player.currentTime().seconds; playhead = t.isFinite ? max(t,0) : 0; playing = player.rate > 0
                if let error = player.currentItem?.error { sourceStatus[state.active] = error.localizedDescription }
            } else { playing = false; duration = 0 }
        }
    }
    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in Task { @MainActor in self?.changed() } }
    }
    func resetSettings() {
        do {
            if FileManager.default.fileExists(atPath: configurationURL.path) { try FileManager.default.copyItem(at: configurationURL, to: configurationURL.deletingLastPathComponent().appendingPathComponent("configuration-backup-\(UUID()).json")) }
            guard !recordingInProgress else { message = "Finish the recording before resetting settings."; return }
            stopPresentation(); for i in 0..<4 { clear(i) }; state = StreamState(); loadFailed = false; changed()
            message = "Settings reset. Previous settings were backed up."
        } catch { message = "Cannot back up settings: \(error.localizedDescription)" }
    }
    func exportDiagnostics() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Smixx-Stream-diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = "Smixx Stream 0.3.0 engineering alpha\n\(ProcessInfo.processInfo.operatingSystemVersionString)\nProgram: \(audio.programStatus)\nMonitor: \(audio.monitorStatus)\nSource status: \(sourceStatus.joined(separator: " | "))\nAudio status: \(audio.status.joined(separator: " | "))\nOutput enabled: \(presenting), paused: \(paused)\nVideo delay: \(state.videoDelayMS) ms\n\(audio.diagnostics)\nLive receiver compatibility not certified.\n"
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { message = error.localizedDescription }
    }
    func shutdown() {
        finishStroke(); saveAnnotations(); annotationSaveTask?.cancel()
        timer?.invalidate(); saveTask?.cancel(); audio.shutdown()
        for task in sourceTasks.values { task.cancel() }
        for session in sessions.values { session.player?.pause() }
    }
}
