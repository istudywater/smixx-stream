import AppKit
import SwiftUI
import AVFoundation
import ScreenCaptureKit
import UniformTypeIdentifiers
import StreamCore
import SmixxCore

@MainActor final class StreamStore: ObservableObject {
    @Published var state = StreamState()
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
    private var sessions: [Int: VideoSourceSession] = [:]
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
        preview = ProcessInfo.processInfo.arguments.contains("--preview")
        audio = AudioEngine(preview: preview)
        configurationURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SmixxStream/configuration.json")
        if !preview && FileManager.default.fileExists(atPath: configurationURL.path) {
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
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/30, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }
    func changed() {
        if !preview { audio.reconcile(state, presenting: presenting && !paused) }
        saveTask?.cancel()
        guard !preview && !loadFailed else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            do { try StateFile.write(state, to: configurationURL) } catch { message = "Settings were not saved: \(error.localizedDescription)" }
        }
    }
    func select(_ index: Int) {
        guard state.sources[index].kind != .empty else { configuring = index; return }
        state.active = index; playhead = 0; duration = 0; pageCount = 0; changed()
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
        session.renderPDF(page: state.sources[state.active].page, zoom: 1); changed()
    }
    func togglePlay() {
        guard let player = sessions[state.active]?.player else { return }
        if player.rate > 0 { player.pause() }
        else { if duration > 0 && playhead >= duration-0.1 { player.seek(to: .zero) }; player.play() }
    }
    func seek(_ seconds: Double) {
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
        presenting = false; paused = false
        message = "Presentation stopped. Preview and source controls remain available."
        if closeWindow { outputWindow?.close(); outputWindow = nil }
        changed()
    }
    func togglePause() { paused.toggle(); changed() }
    private func tick() {
        for session in sessions.values { session.pollMedia() }
        let cutoff = CACurrentMediaTime() - state.videoDelayMS/1000
        for i in 0..<4 {
            guard var queue = pending[i], let index = queue.lastIndex(where: { $0.hostTime <= cutoff }) else { continue }
            frames[i] = queue[index]; queue.removeFirst(index+1); pending[i] = queue
        }
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
            stopPresentation(); for i in 0..<4 { clear(i) }; state = StreamState(); loadFailed = false; changed()
            message = "Settings reset. Previous settings were backed up."
        } catch { message = "Cannot back up settings: \(error.localizedDescription)" }
    }
    func exportDiagnostics() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Smixx-Stream-diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = "Smixx Stream 0.1.0 engineering alpha\n\(ProcessInfo.processInfo.operatingSystemVersionString)\nProgram: \(audio.programStatus)\nMonitor: \(audio.monitorStatus)\nSource status: \(sourceStatus.joined(separator: " | "))\nAudio status: \(audio.status.joined(separator: " | "))\nOutput enabled: \(presenting), paused: \(paused)\nVideo delay: \(state.videoDelayMS) ms\n\(audio.diagnostics)\nLive receiver compatibility not certified.\n"
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { message = error.localizedDescription }
    }
    func shutdown() {
        timer?.invalidate(); saveTask?.cancel(); audio.shutdown()
        for task in sourceTasks.values { task.cancel() }
        for session in sessions.values { session.player?.pause() }
    }
}
