import Testing
import Foundation
@testable import SmixxCore

struct MixerTests {
    func active() -> MixerState {
        var s = MixerState()
        for i in 0..<6 { s.sources[i].source = .init(kind: .device, uid: "input\(i)", name: "Input \(i)") }
        for o in 0..<3 { s.outputs[o].muted = false }
        return s
    }
    @Test func freshConfiguration() {
        let s = MixerState()
        #expect(s.sources.count == 6 && s.outputs.count == 3)
        #expect(s.outputs.map(\.name) == ["Smixx Bus 1", "Smixx Bus 2", "Smixx Bus 3"])
        #expect(s.monitor.bus == 0 && s.monitor.endpointUID == nil && s.monitor.muted)
        for o in 0..<3 { for i in 0..<6 { #expect(s.routeGain(source: i, output: o) == 0) } }
    }
    @Test func busMuteSoloIsolationAndPendingSolo() {
        var s = active(); s.outputs[0].sends[1].solo = true; s.outputs[0].sends[1].muted = true
        for i in 0..<6 { #expect(s.routeGain(source: i, output: 0) == 0); #expect(s.routeGain(source: i, output: 1) == 1) }
        s.outputs[0].sends[1].muted = false
        #expect(s.routeGain(source: 1, output: 0) == 1)
        s.outputs[0].sends[2].solo = true
        #expect(s.routeGain(source: 2, output: 0) == 1)
        s.sources[2].muted = true
        for o in 0..<3 { #expect(s.routeGain(source: 2, output: o) == 0) }
        s.clearSolos(); #expect(s.routeGain(source: 0, output: 0) == 1)
    }
    @Test func editingAndMonitorSelectionsAreIndependent() {
        var s = active(); s.outputs[1].sends[2].levelDB = -6
        let routes = (0..<3).map { s.routeGain(source: 2, output: $0) }
        let outputs = s.outputs
        s.selectedOutput = 2
        #expect(s.monitor.bus == 0 && s.outputs == outputs)
        s.monitor.bus = 1; s.monitor.levelDB = -30
        #expect(s.selectedOutput == 2 && s.outputs == outputs)
        #expect(routes == (0..<3).map { s.routeGain(source: 2, output: $0) })
    }
    @Test func replacementSafeguardAndGlobalMutePreserved() {
        var s = active(); s.sources[2].muted = true
        s.outputs[1].sends[2].levelDB = -9; s.outputs[0].sends[2].solo = true
        s.assign(.init(kind: .application, uid: "app", name: "App"), to: 2)
        #expect(s.sources[2].muted)
        for o in 0..<3 { #expect(!s.outputs[o].sends[2].enabled && !s.outputs[o].sends[2].solo) }
        #expect(s.outputs[1].sends[2].levelDB == -9)
        s.sources[2].muted = false; s.outputs[1].sends[2].muted = false; s.outputs[1].sends[2].enabled = true
        s.assign(s.sources[2].source, to: 2)
        #expect(!s.outputs[1].sends[2].muted)
        #expect(s.routeGain(source: 2, output: 0) == 0)
        #expect(s.routeGain(source: 2, output: 1) > 0)
    }
    @Test func emptySlotAlwaysSilent() {
        var s = active(); s.sources[1].source = nil
        for o in 0..<3 { #expect(s.routeGain(source: 1, output: o) == 0) }
    }
    @Test func persistEffectsMonitorMutesButNotSolos() throws {
        var s = active(); s.selectedOutput = 2; s.monitor.bus = 1; s.monitor.levelDB = -9
        s.outputs[0].sends[3].muted = true; s.outputs[2].sends[1].solo = true
        s.sources[1].effects = Effects(); s.sources[1].effects?.eqEnabled = true
        s.outputs[2].effects = .bus; s.outputs[2].effects?.compressorEnabled = true
        let d = try JSONDecoder().decode(MixerState.self, from: JSONEncoder().encode(s)).validated()
        s.clearSolos(); #expect(d == s)
    }
    @Test func invalidStateAndEffectsRejected() {
        var s = active(); s.outputs[0].leader = 1
        #expect(throws: (any Error).self) { try s.validated() }
        s = active(); s.sources[0].effects = Effects(); s.sources[0].effects?.attackMS = .nan
        #expect(throws: (any Error).self) { try s.validated() }
        s = active(); s.monitor.bus = 3
        #expect(throws: (any Error).self) { try s.validated() }
    }
    @Test func feedbackAndEndpointIsolation() throws {
        var s = active()
        s.assign(.init(kind: .application, uid: "com.microsoft.teams2", name: "Renamed Teams"), to: 0)
        try s.checkTransportIsolation()
        s.outputs[1].sends[0].muted = false
        try s.checkTransportIsolation()
        s.outputs[0].sends[0].enabled = true
        #expect(throws: (any Error).self) { try s.checkTransportIsolation() }
        s.outputs[0].sends[0].enabled = false
        s.sources[0].source = .init(kind: .device, uid: "org.smixx.audio.out4", name: "Old feed")
        #expect(throws: (any Error).self) { try s.checkTransportIsolation() }
        #expect(throws: (any Error).self) { try s.assignMonitor(SmixxTransport.meetingUID, name: "Feed") }
        try s.assignMonitor("headphones", name: "Headphones")
        #expect(s.monitor.muted)
        #expect(throws: (any Error).self) { try s.assignOutput("headphones", name: "Duplicate", to: 2) }
    }
    @Test func returnMonitoringAndCaptureOverlapWarnings() throws {
        var s = active(); s.assign(.init(kind: .application, uid: "com.microsoft.teams2", name: "Teams"), to: 0)
        s.outputs[1].sends[0].muted = false
        try s.assignMonitor("phones", name: "Phones"); s.monitor.muted = false; s.monitor.bus = 1
        #expect(s.risks().contains { $0.contains("heard twice") })
        s.sources[1].source = s.sources[0].source
        #expect(s.risks().contains { $0.contains("Overlapping captures") })
    }
    @Test func migrationBacksUpAllFourMixesAndMaterializesFourthLeader() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("configuration.json")
        var s = active(); s.version = 1; s.selectedOutput = 3; s.monitoring = nil
        s.outputs.append(OutputMix(id: 3, name: "Fourth", role: .custom))
        s.sources.removeLast()
        for o in s.outputs.indices { s.outputs[o].sends.removeLast() }
        s.outputs[3].sends[1].levelDB = -17; s.outputs[3].sends[1].enabled = false
        s.outputs[0].leader = 3; s.sources[1].muted = true
        try ConfigurationFile.save(s, to: url)
        let original = try Data(contentsOf: url)
        let migrated = try ConfigurationFile.load(url)
        #expect(migrated.version == 3 && migrated.outputs.count == 3 && migrated.selectedOutput == 2)
        #expect(migrated.outputs[0].sends[1].muted && migrated.outputs[0].sends[1].levelDB == -17)
        #expect(migrated.sources[1].muted && migrated.outputs.allSatisfy { $0.leader == nil })
        #expect(migrated.monitor.endpointUID == nil)
        let backup = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains("v1-backup") }!
        #expect(try Data(contentsOf: backup) == original)
        #expect(try ConfigurationFile.load(url) == migrated)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2)
    }
    @Test func headphonesIgnoreSendAndBusControls() {
        var s = active()
        s.outputs[0].sends[5].levelDB = -6
        let expected = MixerState.amplitude(-6)
        #expect(s.headphoneGain(source: 5) == expected)
        s.outputs[0].sends[5].enabled = false
        s.outputs[0].sends[5].muted = true
        s.outputs[0].sends[0].solo = true
        s.outputs[0].muted = true
        #expect(s.headphoneGain(source: 5) == expected)
        #expect(s.routeGain(source: 5, output: 0) == 0)
        s.monitor.levelDB = -40
        #expect(s.headphoneGain(source: 5) == expected)
        s.sources[5].muted = true
        #expect(s.headphoneGain(source: 5) == 0)
    }
    @Test func versionTwoMigrationPreservesRoutesAndBacksUp() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("configuration.json")
        var s = active(); s.version = 2; s.sources.removeLast()
        for o in s.outputs.indices { s.outputs[o].sends.removeLast() }
        s.outputs[0].sends[2].enabled = false
        s.outputs[1].sends[4].levelDB = -11
        try s.assignMonitor("phones", name: "Phones"); s.monitor.muted = false
        // Encode an authentic legacy Send object without the new independent mute field.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any]
        var outputs = json["outputs"] as! [[String: Any]]
        for o in outputs.indices {
            var sends = outputs[o]["sends"] as! [[String: Any]]
            for i in sends.indices { sends[i].removeValue(forKey: "muted") }
            outputs[o]["sends"] = sends
        }
        json["outputs"] = outputs
        let original = try JSONSerialization.data(withJSONObject: json)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try original.write(to: url)
        let migrated = try ConfigurationFile.load(url)
        #expect(migrated.sources.count == 6 && migrated.sources[5].source == nil)
        #expect(migrated.monitor.endpointUID == "phones" && migrated.monitor.muted)
        #expect(migrated.outputs[1].sends[4].levelDB == -11)
        #expect(!migrated.outputs[0].sends[2].enabled && migrated.outputs[0].sends[2].muted)
        #expect(migrated.outputs.allSatisfy { !$0.sends[5].enabled })
        let backup = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains("v2-backup") }!
        #expect(try Data(contentsOf: backup) == original)
        #expect(try ConfigurationFile.load(url) == migrated)
    }
    @Test func corruptConfigurationIsNotOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data("{broken".utf8); try data.write(to: url)
        #expect(throws: (any Error).self) { try ConfigurationFile.load(url) }
        #expect(try Data(contentsOf: url) == data)
    }
    @Test func hiddenInputPreferenceDoesNotChangeRoutes() throws {
        var s = active(); let before = s.sources
        s.setInputVisible(false, key: MixerState.inputMenuKey(.device, "input1"), name: "Input")
        #expect(!s.offers(s.sources[1].source!) && s.sources == before)
        let d = try JSONDecoder().decode(MixerState.self, from: JSONEncoder().encode(s))
        #expect(!d.offers(s.sources[1].source!))
    }
}
