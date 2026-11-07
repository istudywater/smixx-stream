import AppKit
import StreamMedia

@MainActor extension StreamStore {
    var canAnnotate: Bool { !paused && displayedFrame?.contextID.isEmpty == false }
    var canFreeze: Bool { !paused && state.sources[state.active].kind == .media && frames[state.active]?.citation?.seconds != nil }
    var isFrozen: Bool { guard let frame = frames[state.active] else { return false }; return frozen[frame.sourceID] != nil }
    var currentHistory: InkHistory { histories[displayedFrame?.contextID ?? ""] ?? InkHistory() }
    var availableSnapshots: [CapturedFrame] {
        guard let id = frames[state.active]?.sourceID else { return [] }
        return snapshots.values.filter { $0.sourceID == id }.sorted { ($0.citation?.seconds ?? 0) < ($1.citation?.seconds ?? 0) }
    }
    func loadAnnotations() {
        do { let (archive,images) = try annotationArchive.load(); histories = archive.histories; snapshots = images }
        catch { annotationLoadFailed = true; message = "Annotations could not be loaded and were preserved: \(error.localizedDescription)" }
    }
    func saveAnnotations() {
        guard !temporarySession, !preview, !annotationLoadFailed else { return }
        do { try annotationArchive.save(histories: histories,snapshots: snapshots) }
        catch { annotationError = "Annotations could not be saved: \(error.localizedDescription)" }
    }
    func inkChanged(persist: Bool = true) {
        annotationRevision += 1
        guard persist else { return }
        annotationSaveTask?.cancel()
        annotationSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }; self?.saveAnnotations()
        }
    }
    func freezeFrame() {
        finishStroke()
        guard canFreeze, var frame = frames[state.active] else { return }
        sessions[state.active]?.player?.pause()
        frame.contextID = UUID().uuidString
        frozen[frame.sourceID] = frame; snapshots[frame.contextID] = frame
        annotationTool = .pen; inkChanged()
    }
    func restoreSnapshot(_ frame: CapturedFrame) {
        finishStroke(); sessions[state.active]?.player?.pause()
        frozen[frame.sourceID] = frame; inkChanged(persist: false)
    }
    func beginStroke(_ canvasPoint: InkPoint) {
        finishStroke()
        guard canAnnotate, let frame = displayedFrame, let point = composition.sourcePoint(canvasPoint) else { return }
        draftContext = frame.contextID
        if annotationTool == .eraser { erase(at: point); return }
        guard annotationTool == .pen || annotationTool == .highlighter else { return }
        let colors: [(Double,Double,Double)] = [(1,0.25,0.25),(1,0.83,0.15),(0.1,0.75,1),(0.3,0.95,0.55),(1,1,1),(0.1,0.1,0.1)]
        let rgb = colors[max(0,min(colors.count-1,inkColor))]
        let rect = composition.contentRect(width: 1920,height: 1080)
        draft = InkStroke(points: [point],red: rgb.0,green: rgb.1,blue: rgb.2,opacity: annotationTool == .highlighter ? 0.32 : 1,width: inkWidth * (annotationTool == .highlighter ? 5 : 1)/max(1,rect.width))
        inkChanged(persist: false)
    }
    func continueStroke(_ canvasPoint: InkPoint) {
        guard canAnnotate, draftContext == displayedFrame?.contextID else { finishStroke(); return }
        guard let point = composition.sourcePoint(canvasPoint) else { finishStroke(); return }
        if annotationTool == .eraser { erase(at: point) }
        else if draft != nil { draft?.points.append(point); inkChanged(persist: false) }
    }
    func finishStroke() {
        defer { draft = nil; draftContext = nil }
        guard let draft, let id = draftContext else { return }
        var history = histories[id] ?? InkHistory(); history.replace(history.strokes+[draft]); histories[id] = history; inkChanged()
    }
    func cancelStroke() { draft = nil; draftContext = nil; inkChanged(persist: false) }
    func erase(at point: InkPoint) {
        guard let id = displayedFrame?.contextID else { return }
        var history = histories[id] ?? InkHistory()
        let rect = composition.contentRect(width: 1920,height: 1080)
        let target = CGPoint(x: point.x*rect.width,y: point.y*rect.height)
        func distance(_ a: InkPoint, _ b: InkPoint) -> Double {
            let ax = a.x*rect.width, ay = a.y*rect.height, dx = (b.x-a.x)*rect.width, dy = (b.y-a.y)*rect.height
            let t = max(0,min(1,((target.x-ax)*dx+(target.y-ay)*dy)/max(0.00001,dx*dx+dy*dy)))
            return hypot(target.x-ax-t*dx,target.y-ay-t*dy)
        }
        guard let index = history.strokes.lastIndex(where: { stroke in
            let threshold = max(12,stroke.width*rect.width/2+6)
            if stroke.points.count == 1 { return distance(stroke.points[0],stroke.points[0]) <= threshold }
            return zip(stroke.points,stroke.points.dropFirst()).contains { distance($0,$1) <= threshold }
        }) else { return }
        var value = history.strokes; value.remove(at: index); history.replace(value); histories[id] = history; inkChanged()
    }
    func undoInk() { finishStroke(); guard let id = displayedFrame?.contextID else { return }; histories[id]?.undo(); inkChanged() }
    func redoInk() { finishStroke(); guard let id = displayedFrame?.contextID else { return }; histories[id]?.redo(); inkChanged() }
    func clearInk() { finishStroke(); guard let id = displayedFrame?.contextID else { return }; histories[id]?.replace([]); inkChanged() }
    func panBy(x: Double,y: Double) {
        guard !paused, let frame = displayedFrame else { return }
        var c = composition; c.pan.x += x; c.pan.y += y
        let rect = c.contentRect(width: 1920,height: 1080)
        pans[frame.sourceID] = InkPoint((rect.midX-960)/1920,(rect.midY-540)/1080); inkChanged(persist: false)
    }
    func zoomTo(_ value: Double, anchor: InkPoint = InkPoint(0.5,0.5), rerender: Bool = true) {
        guard !paused, let frame = displayedFrame else { return }
        let old = composition, before = old.contentRect(width: 1920,height: 1080)
        let z = max(1,min(4,value)); state.sources[state.active].zoom = z
        var after = composition; let rect = after.contentRect(width: 1920,height: 1080)
        let sx = (anchor.x*1920-Double(before.minX))/max(1,Double(before.width))
        let sy = (anchor.y*1080-Double(before.minY))/max(1,Double(before.height))
        after.pan.x += (anchor.x*1920-(Double(rect.minX)+sx*Double(rect.width)))/1920.0
        after.pan.y += (anchor.y*1080-(Double(rect.minY)+sy*Double(rect.height)))/1080.0
        let clamped = after.contentRect(width: 1920,height: 1080)
        pans[frame.sourceID] = InkPoint((clamped.midX-960)/1920,(clamped.midY-540)/1080)
        inkChanged(persist: false); changed()
        if rerender { refreshPDFResolution() }
    }
    func refreshPDFResolution() {
        let source = state.sources[state.active]
        if source.kind == .pdf { sessions[state.active]?.renderPDF(page: source.page,zoom: source.zoom) }
    }
    func resetView() {
        finishStroke(); if let id = displayedFrame?.sourceID { pans[id] = InkPoint(0,0) }
        state.sources[state.active].scaling = .fit; zoomTo(1)
    }
    func exportHandout() {
        finishStroke()
        guard canAnnotate, let citation = displayedFrame?.citation else { annotationError = "Choose a PDF page or Freeze & annotate a local video first."; return }
        // Capture pixels, marks, transform and citation together BEFORE the modal panel.
        let snapshot = composition
        do {
            let image = try HandoutExporter.render(snapshot,citation: citation)
            let panel = NSSavePanel(); panel.allowedContentTypes = [.png]
            let location = (citation.location ?? "").replacingOccurrences(of: ":",with: "-")
            panel.nameFieldStringValue = "\((citation.filename as NSString).deletingPathExtension)-\(location).png"
            panel.message = "Exports the visible Program image and annotations. Logo bottom left; filename and source location bottom right."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try HandoutExporter.write(image,to: url); savedHandout = url; message = "Saved annotated handout: \(url.lastPathComponent)"
        } catch { annotationError = error.localizedDescription }
    }
}
