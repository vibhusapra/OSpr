// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OSpr",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "OSpr", targets: ["OSpr"]), .executable(name: "ospr-cli", targets: ["OSprCLI"])],
    targets: [
        .target(name: "OSprCore"),
        .executableTarget(name: "OSpr", dependencies: ["OSprCore"]),
        .executableTarget(name: "OSprCLI", dependencies: ["OSprCore"]),
        .testTarget(name: "OSprCoreTests", dependencies: ["OSprCore"]),
        .testTarget(name: "OSprPlatformTests", dependencies: ["OSpr", "OSprCore"])
    ],
    swiftLanguageModes: [.v5]
)
