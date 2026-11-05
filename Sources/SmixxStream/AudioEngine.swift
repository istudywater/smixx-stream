import AppKit
import AVFoundation
import AudioToolbox
import MixerDSP
import SmixxCore
import StreamCore

@MainActor final class AudioEngine: ObservableObject {
    let dsp: OpaquePointer
    @Published var inventory = HardwareInventory()
    @Published var levels = Array(repeating: Float(0), count: 8)
    @Published var status = Array(repeating: "No audio assigned", count: 6)
    @Published var programStatus = "Choose an audio destination"
    @Published var monitorStatus = "Monitor muted"
    @Published var monitorEnabled = false
    private var inputs: [Int: AudioConnection] = [:]
    private var program: AudioConnection?
    private var monitor: AudioConnection?
    private var mediaSlots: Set<Int> = []
    private var timer: Timer?
    private var ticks = 0
    var current = StreamState()
    var outputEnabled = false
    var sourceFailures: Set<Int> = []
    init(preview: Bool) {
        dsp = sm_create()!
        if !preview {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        }
    }
    func refresh() { inventory = HardwareInventory.scan() }
    var availableInputs: [SourceReference] { inventory.sources.filter { !Routing.meetingReturn(bundleID: $0.uid) } }
    var outputs: [HardwareDevice] { inventory.devices.filter { $0.outputs >= 2 } }
    func setMedia(_ slot: Int, enabled: Bool) {
        if enabled { inputs[slot] = nil; mediaSlots.insert(slot); status[slot] = "Media audio · playback controlled below Program" }
        else { mediaSlots.remove(slot) }
    }
    func reconcile(_ state: StreamState, presenting: Bool) {
        current = state; outputEnabled = presenting
        for i in 0..<6 {
            let identity = state.channels[i].sourceIdentity
            if mediaSlots.contains(i) { continue }
            guard !identity.isEmpty, let ref = availableInputs.first(where: { $0.identity == identity }) else {
                silence(i); inputs[i] = nil
                status[i] = identity.isEmpty ? "No audio assigned" : "Source unavailable · reconnect or reselect"
                continue
            }
            if let other = Routing.duplicateOwner(identity: identity, assignments: state.channels.map(\.sourceIdentity), excluding: i), other < i {
                silence(i); inputs[i] = nil; status[i] = "Shared audio · controlled by channel \(other+1)"; continue
            }
            // Hardware ranges and routed/copy variants can overlap despite different identity strings.
            let overlaps = (0..<i).contains { j in
                guard let previous = availableInputs.first(where: { $0.identity == state.channels[j].sourceIdentity }), previous.uid == ref.uid, previous.kind == ref.kind else { return false }
                return ref.kind == .application || (ref.channel..<(ref.channel + (ref.stereo ? 2 : 1))).overlaps(previous.channel..<(previous.channel + (previous.stereo ? 2 : 1)))
            }
            if overlaps { silence(i); inputs[i] = nil; status[i] = "Overlapping audio source · use its existing channel"; continue }
            if state.channels[i].muted {
                silence(i); inputs[i] = nil; status[i] = "Muted · \(ref.name)"; continue
            }
            let dev = inventory.devices.first { $0.uid == ref.uid }
            let app = inventory.apps.first { $0.id == ref.uid }
            let signature = "\(identity):\(dev?.id ?? 0):\(dev?.rate ?? 0):\(app?.processes ?? [])"
            if inputs[i]?.signature != signature {
                silence(i); inputs[i] = nil
                if ref.kind == .device && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                    status[i] = "Microphone permission required"; continue
                }
                do { inputs[i] = try AudioConnection(dsp: dsp, slot: i, source: ref, inventory: inventory, signature: signature); status[i] = "Capture open · \(ref.name)" }
                catch { status[i] = error.localizedDescription }
            }
        }
        connectOutput(uid: presenting ? state.programUID : "", monitorBus: false)
        connectOutput(uid: monitorEnabled ? state.monitorUID : "", monitorBus: true)
        apply()
    }
    private func connectOutput(uid: String, monitorBus: Bool) {
        let bus: Int32 = monitorBus ? 3 : 0
        func close(_ reason: String) {
            sm_set_master(dsp, bus, 0)
            if monitorBus { monitor = nil; monitorStatus = reason } else { program = nil; programStatus = reason }
        }
        guard !uid.isEmpty else { close(monitorBus ? "Monitor off" : "Program audio off"); return }
        guard let device = outputs.first(where: { $0.uid == uid }) else { close("Saved output disconnected"); return }
        if monitorBus && uid == current.programUID && outputEnabled { close("Choose separate headphones or turn Monitor off"); return }
        if SmixxTransport.feedUIDs.contains(uid) {
            if monitorBus { close("Choose physical headphones for Monitor"); return }
            let model = HAL.string(device.id, kAudioDevicePropertyModelUID)
            guard model == "org.smixx.audio.virtual.v2" else { close("Driver upgrade needed · see Setup"); return }
            let owner = Int32(HAL.string(device.id, 0x736d6f77)) ?? -1
            guard owner == 0 || owner == getpid() else { close("Virtual bus is owned by another process (PID \(owner))"); return }
            let conflicts = NSWorkspace.shared.runningApplications.contains { ["org.smixx.desktop", "org.smixx.transport-probe"].contains($0.bundleIdentifier ?? "") }
            guard !conflicts else { close("Quit Smixx Desktop / transport probe before using the shared driver"); return }
        }
        let signature = "\(uid):\(device.id):\(device.rate)"
        if (monitorBus ? monitor : program)?.signature == signature {
            if !monitorBus && SmixxTransport.feedUIDs.contains(uid) {
                programStatus = "Driver writer active → \(device.name) · remote listener unverified"
            }
            return
        }
        close("Connecting…")
        do {
            let connection = try AudioConnection(dsp: dsp, output: Int(bus), device: device, signature: signature)
            if monitorBus { monitor = connection; monitorStatus = "Monitor → \(device.name)" }
            else { program = connection; programStatus = "Audio endpoint open → \(device.name) · listener unverified" }
        } catch { close(error.localizedDescription) }
    }
    private func silence(_ index: Int) { for bus in 0..<4 { sm_set_gain(dsp, Int32(index), Int32(bus), 0) } }
    func apply() {
        for i in 0..<6 {
            let channel = current.channels[i]
            let ready = (inputs[i] != nil || mediaSlots.contains(i)) && !sourceFailures.contains(i)
            let gain: Float = ready && !channel.muted ? Float(channel.gain) : 0
            sm_set_gain(dsp, Int32(i), 0, program != nil && outputEnabled ? gain : 0)
            sm_set_gain(dsp, Int32(i), 3, monitor != nil && channel.monitor ? gain : 0)
        }
        sm_set_master(dsp, 0, program != nil && outputEnabled ? Float(current.programGain) : 0)
        sm_set_master(dsp, 3, monitor != nil && monitorEnabled ? Float(current.monitorGain) : 0)
    }
    private func tick() {
        ticks += 1
        for i in 0..<6 { levels[i] = sm_take_source_peak(dsp, Int32(i)) }
        levels[6] = sm_take_output_peak(dsp, 3); levels[7] = sm_take_output_peak(dsp, 0)
        if ticks % 40 == 0 { refresh(); reconcile(current, presenting: outputEnabled) }
    }
    var diagnostics: String {
        "Capture callbacks: \((0..<6).map { sm_capture_count(dsp, Int32($0)) })\nDropouts: \(sm_dropouts(dsp))\nAudio Unit errors: \(sm_effect_errors(dsp))"
    }
    func shutdown() { timer?.invalidate(); timer = nil; outputEnabled = false; monitorEnabled = false; for i in 0..<6 { silence(i) }; inputs.removeAll(); program = nil; monitor = nil }
}

// AVPlayer processes each local file once. Its normal speaker output is silenced
// after copying PCM into the mixer; no self-process recapture or doubled playback.
private final class MediaTapContext {
    let dsp: OpaquePointer
    let slot: Int32
    var prepared = false
    init(dsp: OpaquePointer, slot: Int32) { self.dsp = dsp; self.slot = slot }
}
final class MediaAudioTap {
    var tap: MTAudioProcessingTap?
    let dsp: OpaquePointer
    let slot: Int32
    @MainActor init(engine: AudioEngine, slot: Int) throws {
        dsp = engine.dsp; self.slot = Int32(slot)
        let context = Unmanaged.passRetained(MediaTapContext(dsp: dsp, slot: self.slot))
        var callbacks = MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: context.toOpaque(),
            init: { _, info, storage in storage.pointee = info }, finalize: { tap in Unmanaged<MediaTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                let owner = Unmanaged<MediaTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                owner.prepared = format.pointee.mFormatID == kAudioFormatLinearPCM && format.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.pointee.mBitsPerChannel == 32 && sm_prepare_source(owner.dsp, owner.slot, format.pointee.mSampleRate) == noErr
            }, unprepare: { _ in },
            process: { tap, frames, _, buffers, count, flags in
                let owner = Unmanaged<MediaTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                var range = CMTimeRange.zero
                let result = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flags, &range, count)
                if result == noErr && owner.prepared {
                    let channels = UnsafeMutableAudioBufferListPointer(buffers).reduce(0) { $0 + Int($1.mNumberChannels) }
                    sm_capture_at_host_time(owner.dsp, owner.slot, buffers, 0, channels > 1 ? 1 : 0, AudioGetCurrentHostTime())
                }
                for buffer in UnsafeMutableAudioBufferListPointer(buffers) { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
            })
        var value: MTAudioProcessingTap?
        let result = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &value)
        guard result == noErr, let value else { context.release(); throw SourceError.message("Cannot prepare media audio (\(result)).") }
        tap = value
    }
}
