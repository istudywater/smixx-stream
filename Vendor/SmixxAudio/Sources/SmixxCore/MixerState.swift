import Foundation

public enum SourceKind: String, Codable { case device, application }
public struct SourceReference: Codable, Equatable, Hashable {
    public var kind: SourceKind
    public var uid: String
    public var name: String
    public var channel: Int
    public var stereo: Bool
    public var routeAppPlayback: Bool
    public init(kind: SourceKind, uid: String, name: String, channel: Int = 0, stereo: Bool = true, routeAppPlayback: Bool = false) {
        self.kind = kind; self.uid = uid; self.name = name; self.channel = channel; self.stereo = stereo; self.routeAppPlayback = routeAppPlayback
    }
    public var identity: String { "\(kind.rawValue):\(uid):\(channel):\(stereo):\(routeAppPlayback)" }
}
public struct SourceSlot: Codable, Equatable, Identifiable {
    public var id: Int
    public var source: SourceReference?
    public var customName = ""
    public var gainDB: Double = 0
    public var muted = false
    public var effects: Effects?
    public var name: String { customName.isEmpty ? (source?.name ?? "Choose source") : customName }
    enum CodingKeys: String, CodingKey { case id, source, customName, gainDB, muted, effects }
    public init(id: Int) { self.id = id }
}
public struct Send: Codable, Equatable {
    public var enabled = true
    public var levelDB: Double = 0
    public var muted = false
    public var solo = false
    enum CodingKeys: String, CodingKey { case enabled, levelDB, muted }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        levelDB = try c.decode(Double.self, forKey: .levelDB)
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
    }
    public init(enabled: Bool = true, levelDB: Double = 0) { self.enabled = enabled; self.levelDB = levelDB }
}
public enum OutputRole: String, Codable, CaseIterable { case meeting, headphones, recording, custom }
public struct OutputMix: Codable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var role: OutputRole
    public var endpointUID: String?
    public var endpointName: String?
    public var sends = Array(repeating: Send(), count: 6)
    public var leader: Int?
    public var levelDB: Double = 0
    public var muted = true
    public var effects: Effects?
    enum CodingKeys: String, CodingKey { case id, name, role, endpointUID, endpointName, sends, leader, levelDB, muted, effects }
    public init(id: Int, name: String, role: OutputRole) { self.id = id; self.name = name; self.role = role }
}
public enum MixerError: LocalizedError {
    case invalidConfiguration, invalidLink, leaderHasFollowers, duplicateOutput, outgoingCapture, meetingReturn
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "The saved configuration is invalid or from an unsupported version. The file has been preserved."
        case .invalidLink: return "Choose a different independent mix. Links cannot form chains or cycles."
        case .leaderHasFollowers: return "Make this mix’s followers independent before linking it to another mix."
        case .outgoingCapture: return "An outgoing virtual feed cannot also be a Smixx input. Use isolated application capture for Teams return."
        case .meetingReturn: return "Teams return cannot be sent to the Teams meeting mix. Send it to headphones or the recording mix instead."
        case .duplicateOutput: return "This endpoint already belongs to another output. Choose distinct endpoints for independent mixes."
        }
    }
}
public struct MixerState: Codable, Equatable {
    public var version = 3
    public var sources = (0..<6).map { SourceSlot(id: $0) }
    public var outputs = SmixxTransport.orderedUIDs.enumerated().map { index, uid in
        var mix = OutputMix(id: index, name: "Smixx Bus \(index + 1)", role: [OutputRole.meeting, .recording, .custom][index])
        mix.endpointUID = uid; mix.endpointName = mix.name
        return mix
    }
    public var selectedOutput = 0
    public var monitoring: MonitorSettings?
    public var migrationNotice: String?
    public var monitor: MonitorSettings { get { monitoring ?? MonitorSettings() } set { monitoring = newValue } }
    // Optional for decoding configurations saved before input-menu preferences existed.
    public private(set) var hiddenInputs: [String: String]?
    public static func inputMenuKey(_ kind: SourceKind, _ uid: String) -> String { "\(kind.rawValue):\(uid)" }
    public func offers(_ source: SourceReference) -> Bool {
        hiddenInputs?[Self.inputMenuKey(source.kind, source.uid)] == nil
    }
    public mutating func setInputVisible(_ visible: Bool, key: String, name: String) {
        var hidden = hiddenInputs ?? [:]
        if visible { hidden.removeValue(forKey: key) } else { hidden[key] = name }
        hiddenInputs = hidden.isEmpty ? nil : hidden
    }
    public mutating func showAllInputs() { hiddenInputs = nil }
    public var expanded = false
    public init() {}
    public func effectiveSends(_ output: Int) -> [Send] { outputs[output].sends }
    public var hasSolos: Bool { outputs.contains { $0.sends.contains { $0.solo } } }
    public mutating func clearSolos() {
        for o in outputs.indices { for i in sources.indices { outputs[o].sends[i].solo = false } }
    }
    public mutating func assign(_ reference: SourceReference?, to slot: Int) {
        guard sources[slot].source?.identity != reference?.identity else { return }
        sources[slot].source = reference
        for o in outputs.indices { outputs[o].sends[slot].enabled = false; outputs[o].sends[slot].muted = false; outputs[o].sends[slot].solo = false }
        // Meeting buses exclude their own return on assignment.
        if let reference, reference.kind == .application, reference.uid.lowercased().hasPrefix("com.microsoft.teams") {
            for i in outputs.indices where outputs[i].leader == nil && (outputs[i].role == .meeting || outputs[i].endpointUID == SmixxTransport.meetingUID) {
                outputs[i].sends[slot].enabled = false
            }
        }
    }
    public mutating func assignOutput(_ uid: String?, name: String?, to output: Int) throws {
        guard outputs[output].endpointUID != uid else { return }
        if let uid, (outputs.contains(where: { $0.id != output && $0.endpointUID == uid }) || monitor.endpointUID == uid) { throw MixerError.duplicateOutput }
        outputs[output].muted = true; outputs[output].endpointUID = uid; outputs[output].endpointName = name
    }
    public mutating func assignMonitor(_ uid: String?, name: String?) throws {
        guard monitor.endpointUID != uid else { return }
        if let uid, outputs.contains(where: { $0.endpointUID == uid }) || SmixxTransport.feedUIDs.contains(uid) { throw MixerError.duplicateOutput }
        monitor.endpointUID = uid; monitor.endpointName = name; monitor.muted = true
    }
    public func sourceEligible(_ i: Int, output: Int) -> Bool {
        let sends = outputs[output].sends
        return sources[i].source != nil && !sources[i].muted && sends[i].enabled && !sends[i].muted && (!sends.contains { $0.solo } || sends[i].solo)
    }
    public func routeGain(source: Int, output: Int) -> Float {
        guard sourceEligible(source, output: output), !outputs[output].muted else { return 0 }
        return Self.amplitude(outputs[output].sends[source].levelDB)
    }
    /// Headphones use the selected balance before Send, bus mute/solo and bus processing.
    public func headphoneGain(source: Int) -> Float {
        guard sources[source].source != nil, !sources[source].muted else { return 0 }
        return Self.amplitude(outputs[monitor.bus].sends[source].levelDB)
    }
    public static func amplitude(_ db: Double) -> Float { db <= -60 ? 0 : Float(pow(10, db / 20)) }
    // Conservative warnings also cover hardware return feeds whose contents are not knowable.
    // Names are not used to establish meeting roles. All app captures sent to a meeting require confirmation.
    public func risks() -> Set<String> {
        var result = Set<String>()
        for output in outputs where output.role == .meeting {
            for (i, send) in effectiveSends(output.id).enumerated() where send.enabled {
                guard let source = sources[i].source else { continue }
                result.insert("Meeting route: \(source.identity) → \(output.endpointUID ?? "unassigned") (mix \(output.id)). Verify this source excludes meeting return and overlapping captures.")
            }
        }
        for output in outputs {
            for (i, send) in effectiveSends(output.id).enumerated() where send.enabled {
                if let source = sources[i].source, source.kind == .device, source.uid == output.endpointUID {
                    result.insert("Possible hardware loop: source \(i + 1) and \(output.name) use the same device. Verify channel routing and direct monitoring.")
                }
            }
        }
        if !monitor.muted, monitor.endpointUID != nil {
            for i in sources.indices where headphoneGain(source: i) > 0 {
                if let ref = sources[i].source, ref.kind == .application, ref.uid.lowercased().hasPrefix("com.microsoft.teams"), !ref.routeAppPlayback {
                    result.insert("Headphone monitor Bus \(monitor.bus + 1) includes a Teams capture copy. If Teams also plays to these headphones, participants will be heard twice. Use route playback to hear Teams only through Smixx. Send off excludes return from the call, not headphones.")
                }
            }
        }
        for i in sources.indices {
            guard let a = sources[i].source else { continue }
            for j in sources.indices where j > i {
                guard let b = sources[j].source, a.kind == b.kind, a.uid == b.uid else { continue }
                if a.kind == .application || (a.channel..<(a.channel + (a.stereo ? 2 : 1))).overlaps(b.channel..<(b.channel + (b.stereo ? 2 : 1))) {
                    result.insert("Overlapping captures in sources \(i + 1) and \(j + 1): the same application or hardware channels can be mixed twice.")
                }
            }
        }
        return result
    }
    public func checkTransportIsolation() throws {
        let transports = Set(outputs.compactMap(\.endpointUID).filter { $0.lowercased().hasPrefix("blackhole") }).union(SmixxTransport.feedUIDs)
        for output in outputs where output.role == .meeting || output.endpointUID == SmixxTransport.meetingUID {
            for (index, send) in effectiveSends(output.id).enumerated() where send.enabled {
                if let ref = sources[index].source, ref.kind == .application, ref.uid.lowercased().hasPrefix("com.microsoft.teams") {
                    throw MixerError.meetingReturn
                }
            }
        }
        if sources.contains(where: { $0.source?.kind == .device && transports.contains($0.source?.uid ?? "") }) {
            throw MixerError.outgoingCapture
        }
    }
    public func validated() throws -> MixerState {
        let count = version == 1 ? 4 : 3
        let sourceCount = version < 3 ? 5 : 6
        guard (1...3).contains(version), sources.count == sourceCount, outputs.count == count,
              sources.map(\.id) == Array(0..<sourceCount), outputs.map(\.id) == Array(0..<count), (0..<count).contains(selectedOutput),
              sources.allSatisfy({ $0.gainDB.isFinite && (-60...12).contains($0.gainDB) && ($0.source?.channel ?? 0) >= 0 && ($0.effects?.valid ?? true) }),
              outputs.allSatisfy({ $0.sends.count == sourceCount && $0.levelDB.isFinite && (-60...12).contains($0.levelDB) && ($0.effects?.valid ?? true) && $0.sends.allSatisfy { $0.levelDB.isFinite && (-60...12).contains($0.levelDB) } }) else { throw MixerError.invalidConfiguration }
        for output in outputs {
            if let leader = output.leader {
                guard version == 1, (0..<count).contains(leader), leader != output.id, outputs[leader].leader == nil else { throw MixerError.invalidConfiguration }
            }
        }
        let endpoints = outputs.compactMap(\.endpointUID)
        guard Set(endpoints).count == endpoints.count else { throw MixerError.invalidConfiguration }
        var result = self
        if version == 1 {
            // Materialize links before removing the fourth mix, including leaders in slot four.
            for i in outputs.indices { result.outputs[i].sends = outputs[outputs[i].leader ?? i].sends; result.outputs[i].leader = nil }
            result.outputs = Array(result.outputs.prefix(3)); result.version = 2
            result.selectedOutput = min(selectedOutput, 2)
            result.monitoring = MonitorSettings()
            result.migrationNotice = "Migrated the first three mixes independently. Original four-mix settings are retained in a dated backup beside configuration.json. Headphone monitoring starts unconfigured. Final Apple peak limiters are now enabled; EQ and compression remain bypassed."
        }
        if version < 3 {
            result.sources.append(SourceSlot(id: 5))
            for o in result.outputs.indices {
                // Legacy enabled was the mute control; preserve silence in outgoing feeds.
                for i in 0..<5 {
                    result.outputs[o].sends[i].muted = !result.outputs[o].sends[i].enabled
                }
                result.outputs[o].sends.append(Send(enabled: false))
            }
            result.version = 3
            result.monitor.muted = true
            result.migrationNotice = (result.migrationNotice ?? "") + " Six inputs and independent pre-Send headphones are now available. Headphones start muted because previously excluded sources are now audible locally; review the balance and unmute headphones. Existing outgoing routes and levels are preserved."
        }
        for i in result.outputs.indices {
            if result.outputs[i].role == .headphones { result.outputs[i].role = .custom }
            result.outputs[i].name = "Smixx Bus \(i + 1)"
            if let uid = result.outputs[i].endpointUID, let n = SmixxTransport.orderedUIDs.firstIndex(of: uid) { result.outputs[i].endpointName = "Smixx Bus \(n + 1)" }
        }
        let m = result.monitor
        guard (0..<3).contains(m.bus), m.levelDB.isFinite, (-60...0).contains(m.levelDB),
              m.endpointUID == nil || (!result.outputs.compactMap(\.endpointUID).contains(m.endpointUID!) && !SmixxTransport.feedUIDs.contains(m.endpointUID!)) else { throw MixerError.invalidConfiguration }
        try result.checkTransportIsolation()
        result.clearSolos(); return result
    }
}

public enum ConfigurationFile {
    public static func load(_ url: URL) throws -> MixerState {
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(MixerState.self, from: data)
        var result = try decoded.validated()
        if decoded.version < 3 {
            let backup = url.deletingPathExtension().appendingPathExtension("v\(decoded.version)-backup-\(UUID().uuidString).json")
            try data.write(to: backup, options: .atomic)
            result.migrationNotice = (result.migrationNotice ?? "") + " Backup: " + backup.path
            try save(result, to: url)
        }
        return result
    }
    public static func save(_ state: MixerState, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}

/// Transport identities only. The mixer and Core Audio adapter do not link libASPL.
/// Replacing the driver with another endpoint transport leaves the six-source/three-bus model intact.
public enum SmixxTransport {
    public static let meetingUID = "org.smixx.audio.meeting"
    public static let recordingUID = "org.smixx.audio.recording"
    public static let orderedUIDs = [meetingUID, "org.smixx.audio.out2", recordingUID]
    public static let feedUIDs = Set(orderedUIDs + ["org.smixx.audio.out4"])
}
