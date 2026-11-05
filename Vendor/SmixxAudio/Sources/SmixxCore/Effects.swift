import Foundation

public struct MonitorSettings: Codable, Equatable {
    public var bus = 0
    public var endpointUID: String?
    public var endpointName: String?
    public var levelDB: Double = -12
    public var muted = true
    public init() {}
}

/// Deliberately limited to verified Apple AU controls. No ratio or true-peak claim.
public struct Effects: Codable, Equatable {
    public var eqEnabled = false
    public var highPassHz: Double = 80
    public var lowDB: Double = 0
    public var midDB: Double = 0
    public var highDB: Double = 0
    public var compressorEnabled = false
    public var thresholdDB: Double = -18
    public var headroomDB: Double = 10
    public var attackMS: Double = 10
    public var releaseMS: Double = 100
    public var limiterEnabled = false
    public var limiterAttackMS: Double = 2
    public var limiterReleaseMS: Double = 5
    public var limiterPreGainDB: Double = 0
    public init() {}
    public static var bus: Effects { var e = Effects(); e.limiterEnabled = true; return e }
    public var enabled: Bool { eqEnabled || compressorEnabled || limiterEnabled }
    public var valid: Bool {
        let checks: [(Double, ClosedRange<Double>)] = [(highPassHz, 20...500), (lowDB, -12...12), (midDB, -12...12), (highDB, -12...12), (thresholdDB, -60...0), (headroomDB, 0.1...40), (attackMS, 1...300), (releaseMS, 10...3000), (limiterAttackMS, 2...2), (limiterReleaseMS, 1...40), (limiterPreGainDB, -40...0)]
        return checks.allSatisfy { $0.0.isFinite && $0.1.contains($0.0) }
    }
}
