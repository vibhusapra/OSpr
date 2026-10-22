import XCTest
@testable import OSprCore

final class EngineLocationTests: XCTestCase {
    func testBundledCLIAndSymlinkDiscoverMovedEngineFromForeignDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("Moved OSpr.app/Contents/MacOS/ospr-cli")
        let engine = root.appendingPathComponent("Moved OSpr.app/Contents/Resources/Engine")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: engine.appendingPathComponent(".venv/bin"), withIntermediateDirectories: true)
        try Data().write(to: executable)
        let python = engine.appendingPathComponent(".venv/bin/python")
        try Data("#!/bin/sh\n".utf8).write(to: python)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        XCTAssertEqual(EngineLocation.resolve(environment: [:], executable: executable, currentDirectory: "/foreign"), engine.path)
        let link = root.appendingPathComponent("linked-cli")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        XCTAssertEqual(EngineLocation.resolve(environment: [:], executable: link, currentDirectory: "/foreign"), engine.path)
        XCTAssertEqual(EngineLocation.resolve(environment: ["OSPR_ROOT": "/explicit"], executable: link, currentDirectory: "/foreign"), "/explicit")
    }
    func testDevelopmentMarkerAndUnbundledFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Dev.app/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let checkout = root.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try Data().write(to: checkout.appendingPathComponent("pyproject.toml"))
        try Data((checkout.path + "\n").utf8).write(to: resources.appendingPathComponent("checkout-root.txt"))
        XCTAssertEqual(EngineLocation.resolve(environment: [:], executable: root.appendingPathComponent("Dev.app/Contents/MacOS/ospr-cli"), currentDirectory: "/foreign"), checkout.path)
        XCTAssertEqual(EngineLocation.resolve(environment: [:], executable: nil, currentDirectory: "/foreign"), "/foreign")
    }
}
