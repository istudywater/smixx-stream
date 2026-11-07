// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "SmixxStream", platforms: [.macOS("14.2")],
    products: [.executable(name: "SmixxStream", targets: ["SmixxStream"])],
    dependencies: [.package(path: "Vendor/SmixxAudio")],
    targets: [
        .target(name: "StreamCore"),
        .target(name: "StreamMedia", dependencies: ["StreamCore"]),
        .executableTarget(name: "SmixxStream", dependencies: ["StreamCore", "StreamMedia", .product(name: "SmixxCore", package: "SmixxAudio"), .product(name: "MixerDSP", package: "SmixxAudio")]),
        .testTarget(name: "SmixxStreamTests", dependencies: ["SmixxStream"]),
        .testTarget(name: "StreamCoreTests", dependencies: ["StreamCore"]),
        .testTarget(name: "StreamMediaTests", dependencies: ["StreamMedia", .product(name: "MixerDSP", package: "SmixxAudio")])
    ], swiftLanguageModes: [.v5]
)
