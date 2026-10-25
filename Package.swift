// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OSpr",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "OSpr", targets: ["OSpr"]), .executable(name: "ospr-cli", targets: ["OSprCLI"]), .executable(name: "ospr-worker-guardian", targets: ["OSprWorkerGuardian"])],
    targets: [
        .target(name: "OSprCore"),
        .executableTarget(name: "OSpr", dependencies: ["OSprCore"]),
        .executableTarget(name: "OSprCLI", dependencies: ["OSprCore"]),
        .executableTarget(name: "OSprWorkerGuardian", dependencies: ["OSprCore"]),
        .testTarget(name: "OSprCoreTests", dependencies: ["OSprCore"]),
        .testTarget(name: "OSprPlatformTests", dependencies: ["OSpr", "OSprCore"])
    ],
    swiftLanguageModes: [.v5]
)
