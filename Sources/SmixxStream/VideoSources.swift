import AppKit
@preconcurrency import AVFoundation
import ScreenCaptureKit
import PDFKit
import StreamCore
import CoreImage
import StreamMedia
import CryptoKit

struct CapturedFrame {
    let image: CGImage
    let hostTime: Double
    var sourceID: String = ""
    var contextID: String = ""
    var citation: SourceCitation? = nil
}
final class FrameReceiver: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "org.smixx.stream.video", qos: .userInteractive)
    let context = CIContext(options: [.cacheIntermediates: false])
    var onFrame: ((CapturedFrame) -> Void)?
    var onFailure: (@Sendable (String) -> Void)?
    func receive(_ pixel: CVPixelBuffer, time: Double) {
        let ci = CIImage(cvPixelBuffer: pixel)
        guard let image = context.createCGImage(ci, from: ci.extent) else { return }
        onFrame?(CapturedFrame(image: image, hostTime: time))
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int else { return }
        if status == SCFrameStatus.stopped.rawValue { onFailure?("Source capture stopped. Reconnect or choose a different window."); return }
        guard status == SCFrameStatus.complete.rawValue, let pixel = sampleBuffer.imageBuffer else { return }
        receive(pixel, time: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onFailure?(error.localizedDescription) }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixel = sampleBuffer.imageBuffer else { return }
        receive(pixel, time: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
    }
}

@MainActor final class VideoSourceSession {
    let receiver = FrameReceiver()
    var stream: SCStream?
    var camera: AVCaptureSession?
    var document: PDFDocument?
    var player: AVPlayer?
    var mediaOutput: AVPlayerItemVideoOutput?
    var mediaAudio: MediaAudioTap?
    var scopeURL: URL?
    var sourceID = ""
    var notifications: [NSObjectProtocol] = []
    var onFailure: (@Sendable (String) -> Void)?
    var frame: ((CapturedFrame) -> Void)? { didSet { receiver.onFrame = frame } }
    func start(_ source: VisualSource, audio: AudioEngine, slot: Int) async throws {
        receiver.onFailure = onFailure
        switch source.kind {
        case .empty: break
        case .window, .display:
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            let filter: SCContentFilter
            let size: CGSize
            if source.kind == .window {
                guard let window = content.windows.first(where: { String($0.windowID) == source.identifier }), window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier else { throw SourceError.message("Window unavailable. Select it again.") }
                filter = SCContentFilter(desktopIndependentWindow: window)
                size = window.frame.size
            } else {
                guard let display = content.displays.first(where: { String($0.displayID) == source.identifier }) else { throw SourceError.message("Display unavailable. Select it again.") }
                let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                size = CGSize(width: display.width, height: display.height)
            }
            let config = SCStreamConfiguration()
            let scale = min(1920 / max(size.width,1), 1080 / max(size.height,1))
            config.width = max(2,Int(size.width*scale)); config.height = max(2,Int(size.height*scale)); config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.queueDepth = 3; config.showsCursor = true; config.capturesAudio = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            let capture = SCStream(filter: filter, configuration: config, delegate: receiver)
            stream = capture
            try capture.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: receiver.queue)
            try await capture.startCapture()
        case .camera:
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw SourceError.message("Camera permission denied. Enable Smixx Stream in Privacy & Security.") }
            guard let device = AVCaptureDevice(uniqueID: source.identifier) else { throw SourceError.message("Camera disconnected.") }
            let session = AVCaptureSession(); session.beginConfiguration(); session.sessionPreset = .high
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw SourceError.message("Camera is unavailable or in use.") }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput(); output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(receiver, queue: receiver.queue)
            guard session.canAddOutput(output) else { throw SourceError.message("Cannot open camera video.") }
            session.addOutput(output); session.commitConfiguration(); camera = session
            for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
                notifications.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [failure = receiver.onFailure] _ in failure?("Camera interrupted. Reconnect the camera source.") })
            }
            await withCheckedContinuation { continuation in receiver.queue.async { session.startRunning(); continuation.resume() } }
        case .pdf, .media:
            let url: URL
            if let bookmark = source.bookmark {
                var stale = false
                url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale)
            } else { url = URL(fileURLWithPath: source.identifier) }
            _ = url.startAccessingSecurityScopedResource(); scopeURL = url
            let values = try url.resourceValues(forKeys: [.fileSizeKey,.contentModificationDateKey])
            let identity = "\(url.standardizedFileURL.path):\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            sourceID = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x",$0) }.joined()
            if source.kind == .pdf {
                guard let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.pageCount > 0 else { throw SourceError.message("Cannot open PDF. Unlock it or choose another file.") }
                document = pdf; renderPDF(page: source.page, zoom: source.zoom)
            } else {
                let asset = AVURLAsset(url: url)
                let item = AVPlayerItem(asset: asset)
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                item.add(output); mediaOutput = output
                if let track = try await asset.loadTracks(withMediaType: .audio).first {
                    let tap = try MediaAudioTap(engine: audio, slot: slot)
                    let parameters = AVMutableAudioMixInputParameters(track: track); parameters.audioTapProcessor = tap.tap
                    let mix = AVMutableAudioMix(); mix.inputParameters = [parameters]; item.audioMix = mix; mediaAudio = tap
                }
                player = AVPlayer(playerItem: item)
                player?.actionAtItemEnd = .pause
            }
        }
    }
    func pollMedia() {
        guard let output = mediaOutput else { return }
        let host = CACurrentMediaTime(), time = output.itemTime(forHostTime: host)
        var displayed = CMTime.invalid
        guard output.hasNewPixelBuffer(forItemTime: time), let pixel = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayed) else { return }
        let ci = CIImage(cvPixelBuffer: pixel)
        guard let image = receiver.context.createCGImage(ci,from: ci.extent) else { return }
        let seconds = displayed.isValid && displayed.isNumeric ? displayed.seconds : nil
        frame?(CapturedFrame(image: image,hostTime: host,sourceID: sourceID,contextID: "",citation: SourceCitation(filename: scopeURL?.lastPathComponent ?? "",seconds: seconds)))
    }
    func renderPDF(page index: Int, zoom: Double) {
        guard let document else { return }
        let index = max(0,min(index,document.pageCount-1))
        guard let page = document.page(at: index) else { return }
        // PDFKit thumbnail applies crop-box origin and rotation consistently. Ink is
        // normalized to this oriented page, not to resolution-dependent bitmap pixels.
        let bounds = page.bounds(for: .cropBox)
        let rotated = abs(page.rotation % 180) == 90
        let size = rotated ? CGSize(width: bounds.height,height: bounds.width) : bounds.size
        let base: CGFloat = min(1920/max(1,size.width),1080/max(1,size.height))
        let scale: CGFloat = base * CGFloat(max(1,min(4,zoom)))
        let thumbnail = page.thumbnail(of: CGSize(width: size.width*scale,height: size.height*scale),for: .cropBox)
        var rect = CGRect(origin: .zero,size: thumbnail.size)
        if let image = thumbnail.cgImage(forProposedRect: &rect,context: nil,hints: nil) {
            frame?(CapturedFrame(image: image,hostTime: CACurrentMediaTime(),sourceID: sourceID,contextID: "\(sourceID)-page-\(index)",citation: SourceCitation(filename: scopeURL?.lastPathComponent ?? "",page: index+1,pages: document.pageCount)))
        }
    }
    func stop() async {
        for token in notifications { NotificationCenter.default.removeObserver(token) }; notifications = []
        if let stream { try? await stream.stopCapture() }; stream = nil
        if let camera { await withCheckedContinuation { continuation in receiver.queue.async { camera.stopRunning(); continuation.resume() } } }; camera = nil
        player?.pause(); player = nil; mediaOutput = nil; mediaAudio = nil
        scopeURL?.stopAccessingSecurityScopedResource(); scopeURL = nil; document = nil
    }
}
enum SourceError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let text) = self { return text }; return nil } }
