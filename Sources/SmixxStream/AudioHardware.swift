import AppKit
import CoreAudio
import AVFoundation
import SmixxCore
import MixerDSP

struct AudioFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
func checked(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw AudioFailure(message: "\(operation) failed (Core Audio \(status)). Check device availability and macOS Privacy & Security permissions, then Retry audio.") }
}
enum HAL {
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func value<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> T {
        var result = initial, size = UInt32(MemoryLayout<T>.size), a = address(selector, scope)
        _ = withUnsafeMutablePointer(to: &result) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
        return result
    }
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size), a = address(selector)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }
    static func ids(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var a = address(selector, scope), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var values = Array(repeating: AudioObjectID(0), count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &values) == noErr else { return [] }
        return values
    }
    static func channels(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    static func format(_ device: AudioObjectID, input: Bool) throws -> AudioStreamBasicDescription {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        let streams = ids(device, kAudioDevicePropertyStreams, scope: scope)
        guard !streams.isEmpty else { throw AudioFailure(message: "This device has no \(input ? "input" : "output") streams.") }
        var first: AudioStreamBasicDescription?
        for stream in streams {
            let f = value(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
            guard f.mFormatID == kAudioFormatLinearPCM, f.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  f.mBitsPerChannel == 32, f.mSampleRate > 0 else {
                throw AudioFailure(message: "This device’s format is unsupported. Choose 32-bit float PCM in Audio MIDI Setup or use a compatible device.")
            }
            if let first, first.mSampleRate != f.mSampleRate { throw AudioFailure(message: "Device streams have different sample rates. Configure matching rates in Audio MIDI Setup.") }
            if first == nil { first = f }
        }
        return first!
    }
}
struct HardwareDevice: Identifiable, Equatable {
    var id: AudioObjectID
    var uid: String
    var name: String
    var inputs: Int
    var outputs: Int
    var rate: Double
}
struct AppSource: Identifiable, Equatable {
    var id: String
    var name: String
    var processes: [AudioObjectID]
}
struct HardwareInventory: Equatable {
    var devices: [HardwareDevice] = []
    var apps: [AppSource] = []
    static func scan() -> Self {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let devices = HAL.ids(system, kAudioHardwarePropertyDevices).compactMap { id -> HardwareDevice? in
            let uid = HAL.string(id, kAudioDevicePropertyDeviceUID)
            guard !uid.isEmpty, !uid.hasPrefix("org.smixx.tap.") else { return nil }
            let alive: UInt32 = HAL.value(id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))
            guard alive != 0 else { return nil }
            return HardwareDevice(id: id, uid: uid, name: HAL.string(id, kAudioObjectPropertyName), inputs: HAL.channels(id, kAudioObjectPropertyScopeInput), outputs: HAL.channels(id, kAudioObjectPropertyScopeOutput), rate: HAL.value(id, kAudioDevicePropertyNominalSampleRate, initial: Double(0)))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var grouped: [String: AppSource] = [:]
        for process in HAL.ids(system, kAudioHardwarePropertyProcessObjectList) {
            let pid: pid_t = HAL.value(process, kAudioProcessPropertyPID, initial: pid_t(0))
            guard pid != getpid(), let app = NSRunningApplication(processIdentifier: pid) else { continue }
            let bundle = HAL.string(process, kAudioProcessPropertyBundleID)
            guard !bundle.isEmpty else { continue }
            var item = grouped[bundle] ?? AppSource(id: bundle, name: app.localizedName ?? bundle, processes: [])
            item.processes.append(process); grouped[bundle] = item
        }
        return .init(devices: devices, apps: grouped.values.sorted { $0.name < $1.name })
    }
    var sources: [SourceReference] {
        var result: [SourceReference] = []
        for device in devices where device.inputs > 0 && !SmixxTransport.feedUIDs.contains(device.uid) {
            for channel in 0..<device.inputs {
                result.append(.init(kind: .device, uid: device.uid, name: "\(device.name) · \(channel + 1) mono", channel: channel, stereo: false))
                if channel % 2 == 0 && channel + 1 < device.inputs {
                    result.append(.init(kind: .device, uid: device.uid, name: "\(device.name) · \(channel + 1)–\(channel + 2) stereo", channel: channel, stereo: true))
                }
            }
        }
        for app in apps {
            result.append(.init(kind: .application, uid: app.id, name: app.name + " · capture copy"))
            result.append(.init(kind: .application, uid: app.id, name: app.name + " · route playback", routeAppPlayback: true))
        }
        return result
    }
}
private final class IOContext {
    let dsp: OpaquePointer
    let index: Int32
    let input: Bool
    let channel: Int32
    let stereo: Int32
    let rate: Double
    init(dsp: OpaquePointer, index: Int, input: Bool, channel: Int = 0, stereo: Bool = true, rate: Double) {
        self.dsp = dsp; self.index = Int32(index); self.input = input; self.channel = Int32(channel); self.stereo = stereo ? 1 : 0; self.rate = rate
    }
}
private let audioCallback: AudioDeviceIOProc = { _, _, input, _, output, _, user in
    guard let user else { return noErr }
    let context = Unmanaged<IOContext>.fromOpaque(user).takeUnretainedValue()
    if context.input {
        sm_capture_at_host_time(context.dsp, context.index, input, context.channel, context.stereo, AudioGetCurrentHostTime())
        for buffer in UnsafeMutableAudioBufferListPointer(output) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
    } else { sm_render(context.dsp, context.index, output, context.rate) }
    return noErr
}
final class AudioConnection {
    let signature: String
    let device: AudioObjectID
    private var proc: AudioDeviceIOProcID?
    private var context: IOContext?
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    init(dsp: OpaquePointer, slot: Int, source: SourceReference, inventory: HardwareInventory, signature: String) throws {
        self.signature = signature
        if source.kind == .device {
            guard let found = inventory.devices.first(where: { $0.uid == source.uid }), source.channel + (source.stereo ? 2 : 1) <= found.inputs else {
                throw AudioFailure(message: "Disconnected — reconnect \(source.name).")
            }
            device = found.id
        } else {
            guard let app = inventory.apps.first(where: { $0.id == source.uid }), !app.processes.isEmpty else {
                throw AudioFailure(message: "Unavailable — open \(source.name) and play audio, then Retry audio.")
            }
            let description = CATapDescription(stereoMixdownOfProcesses: app.processes)
            description.name = "Smixx · \(app.name)"; description.isPrivate = true; description.muteBehavior = source.routeAppPlayback ? .mutedWhenTapped : .unmuted
            var newTap: AudioObjectID = 0
            try checked(AudioHardwareCreateProcessTap(description, &newTap), "Capture \(app.name)")
            let uid = "org.smixx.tap.\(UUID().uuidString)"
            let properties: [String: Any] = [kAudioAggregateDeviceNameKey: "Smixx capture", kAudioAggregateDeviceUIDKey: uid,
                kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]]
            var newDevice: AudioObjectID = 0
            let status = AudioHardwareCreateAggregateDevice(properties as CFDictionary, &newDevice)
            if status != noErr { AudioHardwareDestroyProcessTap(newTap); try checked(status, "Create app capture") }
            device = newDevice; tap = newTap; aggregate = newDevice
        }
        do {
            let format = try HAL.format(device, input: true)
            try checked(sm_prepare_source(dsp, Int32(slot), format.mSampleRate), "Prepare source effects (32–192 kHz required)")
            try start(IOContext(dsp: dsp, index: slot, input: true, channel: source.channel, stereo: source.stereo, rate: format.mSampleRate))
        } catch { stop(); throw error }
    }
    init(dsp: OpaquePointer, output: Int, device: HardwareDevice, signature: String) throws {
        self.signature = signature; self.device = device.id
        guard device.outputs >= 2 else { throw AudioFailure(message: "This prototype requires a stereo output endpoint.") }
        let format = try HAL.format(device.id, input: false)
        if output < 4 { try checked(sm_prepare_bus(dsp, Int32(output), format.mSampleRate), "Prepare bus effects (32–192 kHz required)") }
        try start(IOContext(dsp: dsp, index: output, input: false, rate: format.mSampleRate))
    }
    private func start(_ context: IOContext) throws {
        self.context = context
        try checked(AudioDeviceCreateIOProcID(device, audioCallback, Unmanaged.passUnretained(context).toOpaque(), &proc), "Open audio device")
        do { try checked(AudioDeviceStart(device, proc), "Start audio device") }
        catch { stop(); throw error }
    }
    func stop() {
        if let proc { AudioDeviceStop(device, proc); AudioDeviceDestroyIOProcID(device, proc); self.proc = nil }
        context = nil
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
    }
    deinit { stop() }
}
