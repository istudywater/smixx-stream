import Foundation
import Testing
import AVFoundation
import CoreGraphics
import AudioToolbox
import MixerDSP
@testable import StreamMedia

@Suite(.serialized) struct RecordingTests {
    func color(_ red: CGFloat,_ green: CGFloat,_ blue: CGFloat) -> CGImage {
        let context = CGContext(data:nil,width:320,height:180,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red:red,green:green,blue:blue,alpha:1));context.fill(CGRect(x:0,y:0,width:320,height:180));return context.makeImage()!
    }
    @Test func recordsPlayableAVAndSourceChanges() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SmixxRecorder-\(UUID())")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let url = folder.appendingPathComponent("lesson.mp4")
        let recorder = try ProgramRecorder(url:url,initial:ProgramComposition(image:color(1,0,0)),width:320,height:180,renderAudio: { buffers in
            let buffer = buffers.pointee.mBuffers
            let samples = buffer.mData!.assumingMemoryBound(to:Float.self)
            for i in 0..<Int(buffer.mDataByteSize)/8 { let value = Float(sin(Double(i)*2 * .pi * 400/48000))*0.2; samples[2*i]=value;samples[2*i+1]=value }
        },onFailure: { _ in })
        try await recorder.start()
        try await Task.sleep(nanoseconds:1_100_000_000)
        #expect(!FileManager.default.fileExists(atPath:url.path)) // Final filename is never advertised early.
        var annotated = ProgramComposition(image:color(0,0,1))
        annotated.strokes = [InkStroke(points:[InkPoint(0.2,0.5),InkPoint(0.8,0.5)],red:0,green:1,blue:0,opacity:1,width:0.04)]
        recorder.update(annotated)
        try await Task.sleep(nanoseconds:1_100_000_000)
        let result = try await recorder.finish()
        #expect(result.audioFrames >= 96000)
        #expect(result.videoFrames >= 40)
        #expect(!FileManager.default.fileExists(atPath:recorder.partialURL.path))
        let asset = AVURLAsset(url:url)
        let video = try await asset.loadTracks(withMediaType:.video)
        let audio = try await asset.loadTracks(withMediaType:.audio)
        #expect(video.count == 1); #expect(audio.count == 1)
        let duration = try await asset.load(.duration).seconds
        #expect(duration >= 2 && duration < 4)
        let size = try await video[0].load(.naturalSize)
        #expect(size.width == 320 && size.height == 180)
        let videoEnd = try await video[0].load(.timeRange).end.seconds
        let audioEnd = try await audio[0].load(.timeRange).end.seconds
        #expect(abs(videoEnd-audioEnd) < 0.1)
        let generator = AVAssetImageGenerator(asset:asset)
        let first = try generator.copyCGImage(at:CMTime(seconds:0.3,preferredTimescale:600),actualTime:nil)
        let second = try generator.copyCGImage(at:CMTime(seconds:1.6,preferredTimescale:600),actualTime:nil)
        func rgb(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating:0,count:4)
            bytes.withUnsafeMutableBytes { buffer in
                let ctx = CGContext(data:buffer.baseAddress,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(image,in:CGRect(x:0,y:0,width:1,height:1))
            }; return bytes
        }
        #expect(rgb(first)[0] > 180 && rgb(first)[2] < 60)
        #expect(rgb(second)[2] > 180 && rgb(second)[0] < 60)
        let mark = try #require(second.cropping(to: CGRect(x:155,y:87,width:10,height:6)))
        #expect(rgb(mark)[1] > 170 && rgb(mark)[2] < 80) // Actual ink survives the MP4 encoder.
        // Decode AAC back to PCM: an audio track alone does not prove it contains signal.
        let reader = try AVAssetReader(asset:asset)
        let output = AVAssetReaderTrackOutput(track:audio[0],outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVLinearPCMIsFloatKey:true,AVLinearPCMBitDepthKey:32,AVLinearPCMIsNonInterleaved:false])
        reader.add(output); #expect(reader.startReading())
        var peak:Float = 0
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let length = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating:0,count:length/4)
            _ = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:length,destination:$0.baseAddress!) }
            peak = max(peak,values.map { abs($0) }.max() ?? 0)
        }
        #expect(reader.status == .completed); #expect(peak > 0.1)
        do { _ = try await recorder.finish(); Issue.record("Second finish should fail") } catch {}
    }
    @Test func recordingMixWorksWithoutPhysicalOutputsAndIgnoresMonitorGain() throws {
        let dsp = try #require(sm_create()); defer { sm_destroy(dsp) }
        #expect(sm_prepare_source(dsp,0,48000) == noErr)
        #expect(sm_prepare_bus(dsp,1,48000) == noErr)
        sm_set_gain(dsp,0,1,0.5); sm_set_master(dsp,1,0.8)
        sm_set_master(dsp,0,0); sm_set_master(dsp,3,0)
        var input = [Float](repeating:0.3,count:960), output = [Float](repeating:0,count:960)
        for _ in 0..<100 {
            input.withUnsafeMutableBytes { bytes in
                var list = AudioBufferList(mNumberBuffers:1,mBuffers:AudioBuffer(mNumberChannels:2,mDataByteSize:UInt32(bytes.count),mData:bytes.baseAddress))
                sm_capture(dsp,0,&list,0,1)
            }
            output.withUnsafeMutableBytes { bytes in
                var list = AudioBufferList(mNumberBuffers:1,mBuffers:AudioBuffer(mNumberChannels:2,mDataByteSize:UInt32(bytes.count),mData:bytes.baseAddress))
                sm_render(dsp,1,&list,48000)
            }
        }
        #expect(output.max()! > 0.1) // No HAL output, Monitor, or driver needed.
        sm_set_master(dsp,1,0)
        output.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(mNumberBuffers:1,mBuffers:AudioBuffer(mNumberChannels:2,mDataByteSize:UInt32(bytes.count),mData:bytes.baseAddress))
            sm_render(dsp,1,&list,48000)
        }
        #expect(output.allSatisfy { $0 == 0 }) // Pause/master mute suppresses delayed effects too.
    }
    @Test func protectsExistingFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Smixx-existing-\(UUID()).mp4")
        let bytes = Data("existing lesson".utf8); try bytes.write(to:url)
        defer { try? FileManager.default.removeItem(at:url) }
        #expect(throws:(any Error).self) { try ProgramRecorder(url:url,initial:ProgramComposition(image:nil),renderAudio:{ _ in },onFailure:{ _ in }) }
        #expect(try Data(contentsOf:url) == bytes)
    }
    @Test func compositionUsesSameFitZoomAndSlate() {
        let red = color(1,0,0)
        #expect(ProgramComposition(image:red,zoom:2).render(width:1920,height:1080)?.width == 1920)
        #expect(ProgramComposition(image:red,slate:"Presentation paused").render(width:320,height:180) != nil)
    }
}
