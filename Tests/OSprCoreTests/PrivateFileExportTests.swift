import XCTest
@testable import OSprCore

final class PrivateFileExportTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-export-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
    func testNewTextExportIsPrivateAndExact() throws {
        let root = try directory(), destination = root.appendingPathComponent("transcript.txt")
        let data = Data("Keep not, $12.50 and Unicode: नमस्ते".utf8)
        try PrivateFileExport.write(data, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), data)
        XCTAssertEqual(try mode(destination), 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["transcript.txt"])
    }
    func testReplacingPublicFileDoesNotPreserveItsReadablePermissions() throws {
        let root = try directory(), destination = root.appendingPathComponent("transcript.json")
        try Data("old".utf8).write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
        try PrivateFileExport.write(Data("new".utf8), to: destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new")
        XCTAssertEqual(try mode(destination), 0o600)
    }
    func testAudioCopyKeepsSourceUnchangedAndPublishesPrivateBytes() throws {
        let root = try directory(), source = root.appendingPathComponent("source.wav"), destination = root.appendingPathComponent("export.wav")
        let data = Data(repeating: 37, count: 1_048_577)
        try data.write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path)
        try PrivateFileExport.copy(source, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), data)
        XCTAssertEqual(try Data(contentsOf: source), data)
        XCTAssertEqual(try mode(source), 0o644)
        XCTAssertEqual(try mode(destination), 0o600)
    }
    func testFailedCopyAndDirectoryDestinationPreserveExistingDataAndCleanStaging() throws {
        let root = try directory(), destination = root.appendingPathComponent("existing.txt")
        try Data("keep".utf8).write(to: destination)
        XCTAssertThrowsError(try PrivateFileExport.copy(root.appendingPathComponent("missing.wav"), to: destination))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "keep")
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let marker = folder.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        XCTAssertThrowsError(try PrivateFileExport.write(Data("replace".utf8), to: folder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".ospr-export-") })
    }
    func testSymbolicLinkDestinationCannotOverwriteItsTarget() throws {
        let root = try directory(), target = root.appendingPathComponent("keep.txt"), link = root.appendingPathComponent("link.txt")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try PrivateFileExport.write(Data("replace".utf8), to: link))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }
}
