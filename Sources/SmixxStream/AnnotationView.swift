import SwiftUI
import AppKit
import StreamMedia

struct AnnotationToolbar: View {
    @ObservedObject var store: StreamStore
    var body: some View {
        VStack(alignment: .leading,spacing: 8) {
            HStack(spacing: 8) {
                Picker("Annotation tool",selection: Binding(get: { store.annotationTool },set: { store.finishStroke(); store.annotationTool = $0 })) {
                    Text("Hand").tag(AnnotationTool.hand)
                    Text("Pen").tag(AnnotationTool.pen)
                    Text("Highlight").tag(AnnotationTool.highlighter)
                    Text("Eraser").tag(AnnotationTool.eraser)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
                .disabled(!store.canAnnotate)
                Button("Undo") { store.undoInk() }.disabled(store.currentHistory.undoStack.isEmpty || !store.canAnnotate)
                Button("Redo") { store.redoInk() }.disabled(store.currentHistory.redoStack.isEmpty || !store.canAnnotate)
                Button("Clear") { store.clearInk() }.disabled(store.currentHistory.strokes.isEmpty || !store.canAnnotate)
                Spacer(minLength: 0)
                Button("Fit") { store.resetView() }.disabled(store.displayedFrame == nil)
            }
            HStack(spacing: 8) {
                Picker("Ink",selection: $store.inkColor) {
                    Text("Red").tag(0); Text("Yellow").tag(1); Text("Blue").tag(2)
                    Text("Green").tag(3); Text("White").tag(4); Text("Black").tag(5)
                }.frame(width: 115)
                Picker("Width",selection: $store.inkWidth) {
                    Text("Fine").tag(2.0); Text("Medium").tag(4.0); Text("Thick").tag(8.0)
                }.frame(width: 145)
                if store.state.sources[store.state.active].kind == .media {
                    Button(store.isFrozen ? "Freeze new frame" : "Freeze & annotate") { store.freezeFrame() }.disabled(!store.canFreeze || store.isFrozen)
                    if !store.availableSnapshots.isEmpty {
                        Menu("Snapshots") {
                            ForEach(store.availableSnapshots,id: \.contextID) { frame in
                                Button(frame.citation?.location ?? "Snapshot") { store.restoreSnapshot(frame) }
                            }
                        }.fixedSize()
                    }
                }
                Spacer(minLength: 0)
                Button("Export PNG") { store.exportHandout() }.disabled(!store.canAnnotate)
                if let url = store.savedHandout {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }.help("Show saved PNG")
                }
            }
            Text(store.isFrozen ? "Frozen frame · marks stay with this snapshot. Play resumes video." : "Drag with Hand to pan · pinch or ⌘ scroll to zoom · Space-drag temporarily pans")
                .font(.caption2).foregroundStyle(.secondary)
        }.controlSize(.small)
    }
}

struct AnnotationInput: NSViewRepresentable {
    var store: StreamStore
    func makeNSView(context: Context) -> InkInputView { let view = InkInputView(); view.store = store; return view }
    func updateNSView(_ view: InkInputView,context: Context) { view.store = store }
}
@MainActor final class InkInputView: NSView {
    weak var store: StreamStore?
    var lastPoint: CGPoint?
    var panning = false
    var spaceDown = false
    var zoomRefresh: DispatchWorkItem?
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds,cursor: store?.annotationTool == .hand ? .openHand : .crosshair) }
    func point(_ event: NSEvent) -> InkPoint {
        let p = convert(event.locationInWindow,from: nil)
        return InkPoint(p.x/max(1,bounds.width),p.y/max(1,bounds.height))
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = point(event); lastPoint = CGPoint(x: p.x,y: p.y)
        panning = spaceDown || store?.annotationTool == .hand
        if !panning { store?.beginStroke(p) }
    }
    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        if panning, let lastPoint { store?.panBy(x: p.x-lastPoint.x,y: p.y-lastPoint.y) }
        else { store?.continueStroke(p) }
        lastPoint = CGPoint(x: p.x,y: p.y)
    }
    override func mouseUp(with event: NSEvent) { store?.finishStroke(); lastPoint = nil }
    override func magnify(with event: NSEvent) {
        guard let store else { return }; store.finishStroke()
        store.zoomTo(store.state.sources[store.state.active].zoom*(1+event.magnification),anchor: point(event),rerender: false)
        scheduleResolution()
    }
    override func scrollWheel(with event: NSEvent) {
        guard let store else { return }; store.finishStroke()
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            store.zoomTo(store.state.sources[store.state.active].zoom*exp(Double(event.scrollingDeltaY)*0.012),anchor: point(event),rerender: false)
            scheduleResolution()
        } else { store.panBy(x: Double(event.scrollingDeltaX)/max(1,bounds.width),y: -Double(event.scrollingDeltaY)/max(1,bounds.height)) }
    }
    func scheduleResolution() {
        zoomRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.store?.refreshPDFResolution() }; zoomRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now()+0.15,execute: item)
    }
    override func keyDown(with event: NSEvent) {
        guard let store else { return }
        if event.keyCode == 49 { spaceDown = true; return }
        if event.keyCode == 53 { store.cancelStroke(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            if event.modifierFlags.contains(.shift) { store.redoInk() } else { store.undoInk() }; return
        }
        switch event.charactersIgnoringModifiers {
        case "+", "=": store.zoomTo(store.state.sources[store.state.active].zoom*1.2)
        case "-": store.zoomTo(store.state.sources[store.state.active].zoom/1.2)
        case "0": store.resetView()
        default:
            switch event.keyCode {
            case 123: store.panBy(x: 0.05,y: 0)
            case 124: store.panBy(x: -0.05,y: 0)
            case 125: store.panBy(x: 0,y: 0.05)
            case 126: store.panBy(x: 0,y: -0.05)
            default: super.keyDown(with: event)
            }
        }
    }
    override func keyUp(with event: NSEvent) { if event.keyCode == 49 { spaceDown = false } else { super.keyUp(with: event) } }
    override func resignFirstResponder() -> Bool { spaceDown = false; store?.finishStroke(); return true }
}
