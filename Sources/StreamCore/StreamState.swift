import Foundation

public enum SourceKind: String, Codable, CaseIterable { case empty, camera, window, display, pdf, media }
public enum Scaling: String, Codable, CaseIterable { case fit, fill }
public struct VisualSource: Codable, Equatable, Identifiable {
    public var id: Int
    public var kind: SourceKind = .empty
    public var name = "Choose source"
    public var identifier = ""
    public var bookmark: Data?
    public var scaling: Scaling = .fit
    public var page = 0
    public var zoom: Double = 1
    public init(id: Int) { self.id = id }
}
public struct AudioChannel: Codable, Equatable {
    public var gain: Double = 0.75
    public var muted = true
    public var monitor = true
    public var sourceIdentity = ""
    public init() {}
}
public struct StreamState: Codable, Equatable {
    public var version = 1
    public var sources = (0..<4).map(VisualSource.init)
    public var channels = (0..<6).map { _ in AudioChannel() }
    public var active = 0
    public var programGain: Double = 0.75
    public var monitorGain: Double = 0.5
    public var monitorUID = ""
    public var programUID = ""
    public var horizontal = false
    public var videoDelayMS: Double = 80
    public init() {}
    public func validated() throws -> Self {
        guard version == 1, sources.count == 4, channels.count == 6,
              sources.enumerated().allSatisfy({ $0.offset == $0.element.id }),
              (0..<4).contains(active), [programGain,monitorGain].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              videoDelayMS.isFinite, (0...500).contains(videoDelayMS),
              channels.allSatisfy({ $0.gain.isFinite && (0...1).contains($0.gain) }),
              sources.allSatisfy({ $0.page >= 0 && $0.zoom.isFinite && (1...4).contains($0.zoom) }) else { throw StateError.invalid }
        return self
    }
}
public enum StateError: Error { case invalid }
public enum Routing {
    public static func duplicateOwner(identity: String, assignments: [String], excluding: Int) -> Int? {
        guard !identity.isEmpty else { return nil }
        return assignments.indices.first { $0 != excluding && assignments[$0] == identity }
    }
    public static func meetingReturn(bundleID: String) -> Bool {
        ["com.microsoft.teams", "com.microsoft.teams2", "us.zoom.xos", "com.cisco.webexmeetingsapp"].contains(bundleID.lowercased())
    }
    public static func videoRect(width: Double, height: Double, canvasWidth: Double, canvasHeight: Double, scaling: Scaling) -> (x: Double, y: Double, width: Double, height: Double) {
        guard width > 0, height > 0 else { return (0,0,0,0) }
        let factor = scaling == .fit ? min(canvasWidth / width, canvasHeight / height) : max(canvasWidth / width, canvasHeight / height)
        let w = width * factor, h = height * factor
        return ((canvasWidth-w)/2, (canvasHeight-h)/2, w,h)
    }
}
public enum StateFile {
    public static func read(_ url: URL) throws -> StreamState { try JSONDecoder().decode(StreamState.self, from: Data(contentsOf: url)).validated() }
    public static func write(_ state: StreamState, to url: URL) throws {
        _ = try state.validated()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
