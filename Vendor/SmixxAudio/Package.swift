// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SmixxAudio", platforms: [.macOS("14.2")],
    products: [.library(name: "SmixxCore", targets: ["SmixxCore"]), .library(name: "MixerDSP", targets: ["MixerDSP"])],
    targets: [
        .target(name: "MixerDSP", publicHeadersPath: "include", linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox")]),
        .target(name: "SmixxCore"),
        .testTarget(name: "SmixxCoreTests", dependencies: ["SmixxCore", "MixerDSP"])
    ], swiftLanguageModes: [.v5])
