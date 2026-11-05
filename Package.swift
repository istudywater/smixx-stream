// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "SmixxStream", platforms: [.macOS("14.2")],
    products: [.executable(name: "SmixxStream", targets: ["SmixxStream"])],
    dependencies: [.package(path: "Vendor/SmixxAudio")],
    targets: [
        .target(name: "StreamCore"),
        .executableTarget(name: "SmixxStream", dependencies: ["StreamCore", .product(name: "SmixxCore", package: "SmixxAudio"), .product(name: "MixerDSP", package: "SmixxAudio")]),
        .testTarget(name: "StreamCoreTests", dependencies: ["StreamCore"])
    ], swiftLanguageModes: [.v5]
)
