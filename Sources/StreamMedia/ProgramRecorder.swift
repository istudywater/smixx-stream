import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import AudioToolbox

public enum RecordingError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
public struct RecordingResult: Sendable {
    public let url: URL
    public let duration: Double
    public let videoFrames: Int
    public let audioFrames: Int64
}

/// One serial writer queue and one independent audio-ring consumer. No encoder
/// work runs on capture/HAL callbacks. The snapshot mailbox is bounded to one.
public final class ProgramRecorder: @unchecked Sendable {
    public typealias AudioRenderer = (UnsafeMutablePointer<AudioBufferList>) -> Void
    private let queue = DispatchQueue(label: "org.smixx.stream.recording",qos: .userInitiated)
    private let lock = NSLock()
    private var snapshot: ProgramComposition
    private var timer: DispatchSourceTimer?
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioFormat: CMAudioFormatDescription
    private let renderAudio: AudioRenderer
    private let failure: @Sendable (String) -> Void
    private let destination: URL
    public let partialURL: URL
    private let width: Int
    private let height: Int
    private var epoch: UInt64 = 0
    private var samples: Int64 = 0
    private var videoFrames = 0
    private var lastVideoTime = -1.0
    private var nextVideoTime = 0.0
    private var ended = false
    private var finishing = false
    private var error: Error?
    private var scratch = Array(repeating: Float(0),count: 960)
    private let sampleRate: Int32 = 48000

    public init(url: URL, initial: ProgramComposition, width: Int = 1920, height: Int = 1080,
                renderAudio: @escaping AudioRenderer, onFailure: @escaping @Sendable (String) -> Void) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw RecordingError.message("Choose a new filename. Existing recordings are never overwritten.") }
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0 else { throw RecordingError.message("Recording dimensions must be positive and even.") }
        self.destination = url; self.width = width; self.height = height
        snapshot = initial; self.renderAudio = renderAudio; failure = onFailure
        partialURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).partial.mp4")
        writer = try AVAssetWriter(outputURL: partialURL,fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        video = AVAssetWriterInput(mediaType: .video,outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,AVVideoWidthKey: width,AVVideoHeightKey: height,AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000,AVVideoExpectedSourceFrameRateKey: 30,AVVideoMaxKeyFrameIntervalKey: 60]])
        audio = AVAssetWriterInput(mediaType: .audio,outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,AVSampleRateKey: sampleRate,AVNumberOfChannelsKey: 2,AVEncoderBitRateKey: 192_000])
        video.expectsMediaDataInRealTime = true; audio.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String: width,kCVPixelBufferHeightKey as String: height,kCVPixelBufferCGImageCompatibilityKey as String: true,kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        var description = AudioStreamBasicDescription(mSampleRate: 48000,mFormatID: kAudioFormatLinearPCM,mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,mBytesPerPacket: 8,mFramesPerPacket: 1,mBytesPerFrame: 8,mChannelsPerFrame: 2,mBitsPerChannel: 32,mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,asbd: &description,layoutSize: 0,layout: nil,magicCookieSize: 0,magicCookie: nil,extensions: nil,formatDescriptionOut: &format) == noErr, let format else { throw RecordingError.message("Cannot create the recording audio format.") }
        audioFormat = format
        guard writer.canAdd(video), writer.canAdd(audio) else { throw RecordingError.message("H.264/AAC recording is unavailable on this Mac.") }
        writer.add(video); writer.add(audio)
    }
    public func update(_ value: ProgramComposition) { lock.lock(); snapshot = value; lock.unlock() }
    public func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
            queue.async {
                guard self.epoch == 0, !self.ended else { continuation.resume(throwing: RecordingError.message("Recording already started or finished.")); return }
                guard self.writer.startWriting() else { continuation.resume(throwing: self.writer.error ?? RecordingError.message("Cannot start writing the recording.")); return }
                self.writer.startSession(atSourceTime: .zero)
                self.epoch = DispatchTime.now().uptimeNanoseconds
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(),repeating: .milliseconds(10),leeway: .milliseconds(1))
                timer.setEventHandler { [weak self] in self?.pump() }; self.timer = timer; timer.resume()
                continuation.resume()
            }
        }
    }
    private func pump() {
        guard !ended, !finishing else { return }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - epoch)/1_000_000_000
        do {
            guard writer.status == .writing else { throw writer.error ?? RecordingError.message("The recording writer stopped unexpectedly.") }
            // Never grow a backlog or silently change recording speed on overload.
            guard elapsed - Double(samples)/48000 < 0.5 else { throw RecordingError.message("Recording could not keep up with audio. Free disk space or reduce system load and start a new recording.") }
            while Double(samples + 480)/48000 <= elapsed && audio.isReadyForMoreMediaData {
                try appendAudio()
            }
            if elapsed >= nextVideoTime, video.isReadyForMoreMediaData {
                lock.lock(); let value = snapshot; lock.unlock()
                try appendVideo(value,time: elapsed)
                nextVideoTime = (floor(elapsed * 30) + 1) / 30
            }
        } catch { fail(error) }
    }
    private func appendAudio() throws {
        try scratch.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(mNumberBuffers: 1,mBuffers: AudioBuffer(mNumberChannels: 2,mDataByteSize: UInt32(bytes.count),mData: bytes.baseAddress))
            renderAudio(&list)
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,memoryBlock: nil,blockLength: bytes.count,blockAllocator: kCFAllocatorDefault,customBlockSource: nil,offsetToData: 0,dataLength: bytes.count,flags: 0,blockBufferOut: &block) == kCMBlockBufferNoErr, let block,
                  CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!,blockBuffer: block,offsetIntoDestination: 0,dataLength: bytes.count) == kCMBlockBufferNoErr else { throw RecordingError.message("Cannot allocate recording audio.") }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1,timescale: sampleRate),presentationTimeStamp: CMTime(value: samples,timescale: sampleRate),decodeTimeStamp: .invalid)
            var size = 8
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,dataBuffer: block,formatDescription: audioFormat,sampleCount: 480,sampleTimingEntryCount: 1,sampleTimingArray: &timing,sampleSizeEntryCount: 1,sampleSizeArray: &size,sampleBufferOut: &sample) == noErr, let sample,
                  audio.append(sample) else { throw writer.error ?? RecordingError.message("Cannot append recording audio.") }
        }
        samples += 480
    }
    private func appendVideo(_ value: ProgramComposition,time: Double) throws {
        guard let pool = adaptor.pixelBufferPool else { throw RecordingError.message("Recording video buffer pool is unavailable.") }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,pool,&buffer) == kCVReturnSuccess, let buffer else { throw RecordingError.message("Cannot allocate recording video.") }
        CVPixelBufferLockBaseAddress(buffer,[])
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),width: width,height: height,bitsPerComponent: 8,bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { CVPixelBufferUnlockBaseAddress(buffer,[]); throw RecordingError.message("Cannot draw recording video.") }
        value.draw(in: context,width: width,height: height)
        CVPixelBufferUnlockBaseAddress(buffer,[])
        let pts = videoFrames == 0 ? CMTime.zero : CMTime(seconds: time,preferredTimescale: 60000)
        guard adaptor.append(buffer,withPresentationTime: pts) else { throw writer.error ?? RecordingError.message("Cannot append recording video.") }
        lastVideoTime = time; videoFrames += 1
    }
    private func fail(_ error: Error) {
        self.error = error; ended = true; timer?.cancel(); timer = nil
        writer.cancelWriting()
        failure("\(error.localizedDescription) Unfinished file, if present: \(partialURL.path)")
    }
    public func finish() async throws -> RecordingResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RecordingResult,Error>) in
            queue.async {
                if let error = self.error { continuation.resume(throwing: error); return }
                guard !self.finishing, !self.ended, self.epoch != 0 else { continuation.resume(throwing: RecordingError.message("Recording is not active.")); return }
                self.pump()
                if let error = self.error { continuation.resume(throwing: error); return }
                self.finishing = true; self.timer?.cancel(); self.timer = nil
                guard self.videoFrames > 0, self.samples > 0 else {
                    self.writer.cancelWriting(); self.ended = true
                    continuation.resume(throwing: RecordingError.message("Recording was too short. Start again and record for at least one second.")); return
                }
                let duration = max(Double(self.samples)/48000,self.lastVideoTime + 1.0/30)
                self.writer.endSession(atSourceTime: CMTime(seconds: duration,preferredTimescale: 60000))
                self.video.markAsFinished(); self.audio.markAsFinished()
                self.writer.finishWriting {
                    self.queue.async {
                        self.ended = true
                        guard self.writer.status == .completed else { continuation.resume(throwing: self.writer.error ?? RecordingError.message("Recording could not be finalized. Partial file: \(self.partialURL.path)")); return }
                        do {
                            // moveItem refuses replacement if another file appeared after Start.
                            try FileManager.default.moveItem(at: self.partialURL,to: self.destination)
                            continuation.resume(returning: RecordingResult(url: self.destination,duration: duration,videoFrames: self.videoFrames,audioFrames: self.samples))
                        } catch { continuation.resume(throwing: RecordingError.message("Recording completed but could not be moved to its destination. Recover it at \(self.partialURL.path). \(error.localizedDescription)")) }
                    }
                }
            }
        }
    }
}
