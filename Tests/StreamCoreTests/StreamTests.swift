import Foundation
import Testing
@testable import StreamCore

@Test func corruptPresetCannotActivateAnInvalidSource() throws {
    var state = StreamState(); state.active = 4
    #expect(throws: StateError.self) { try state.validated() }
    state = StreamState(); state.channels[0].gain = .nan
    #expect(throws: StateError.self) { try state.validated() }
    state = StreamState(); state.sources[0].id = 2
    #expect(throws: StateError.self) { try state.validated() }
}
@Test func portraitPDFKeepsEntirePageInFit() {
    let fit = Routing.videoRect(width: 612,height: 792,canvasWidth: 1920,canvasHeight: 1080,scaling: .fit)
    #expect(abs(fit.height-1080) < 0.001); #expect(fit.width < 1920); #expect(fit.x > 0)
    let fill = Routing.videoRect(width: 612,height: 792,canvasWidth: 1920,canvasHeight: 1080,scaling: .fill)
    #expect(fill.width == 1920); #expect(fill.y < 0)
}
@Test func browserAudioHasOneOwner() {
    #expect(Routing.duplicateOwner(identity: "safari",assignments: ["safari","safari","",""],excluding: 1) == 0)
    #expect(Routing.duplicateOwner(identity: "",assignments: ["",""],excluding: 1) == nil)
}
@Test func knownMeetingReturnsAreExcluded() {
    #expect(Routing.meetingReturn(bundleID: "com.microsoft.teams2"))
    #expect(Routing.meetingReturn(bundleID: "us.zoom.xos"))
    #expect(!Routing.meetingReturn(bundleID: "com.apple.Safari")) // Browser meetings require an explicit user workflow.
}
@Test func atomicPresetRoundtripAndCorruptionPreservation() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("settings.json")
    var state = StreamState(); state.sources[0].kind = .pdf; state.sources[0].page = 4; state.channels[4].monitor = false
    try StateFile.write(state,to: url)
    #expect(try StateFile.read(url) == state)
    let corrupt = Data("{broken".utf8); try corrupt.write(to: url)
    #expect(throws: (any Error).self) { try StateFile.read(url) }
    #expect(try Data(contentsOf: url) == corrupt)
}
