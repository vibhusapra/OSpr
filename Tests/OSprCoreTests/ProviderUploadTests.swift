import XCTest
@testable import OSprCore

final class ProviderUploadTests: XCTestCase {
    func testWorkspaceIsPrivateExclusiveAndCleanupDoesNotRemoveOtherWorkspace() throws {
        let first = try ProviderUploadWorkspace(), second = try ProviderUploadWorkspace()
        defer { first.close(); second.close() }
        XCTAssertNotEqual(first.url, second.url)
        let attributes = try FileManager.default.attributesOfItem(atPath: first.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        first.close(); first.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
    }
    func testPlanRequiresContiguousFullSampleCoverage() throws {
        let workspace = try ProviderUploadWorkspace(); defer { workspace.close() }
        let file = workspace.url.appendingPathComponent("part-0000.wav")
        try Data("part".utf8).write(to: file)
        for (start, count, total) in [(1, 16000, 16000), (0, 15999, 16000), (0, 16001, 16000), (0, 0, 16000)] {
            XCTAssertThrowsError(try ProviderUploadPlan(["sample_rate": 16000, "frames": total,
                "parts": [["path": file.path, "start_frame": start, "frames": count]]], directory: workspace.url))
        }
    }
    func testPlanRejectsSymlinkAndOutsidePathBeforeUpload() throws {
        let workspace = try ProviderUploadWorkspace(), other = try ProviderUploadWorkspace()
        defer { workspace.close(); other.close() }
        let outside = other.url.appendingPathComponent("part-0000.wav")
        try Data("untouched".utf8).write(to: outside)
        let link = workspace.url.appendingPathComponent("part-0000.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        for path in [outside.path, link.path] {
            XCTAssertThrowsError(try ProviderUploadPlan(["sample_rate": 16000, "frames": 16000,
                "parts": [["path": path, "start_frame": 0, "frames": 16000]]], directory: workspace.url))
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data("untouched".utf8))
    }
    func testPlanRejectsOversizedPartBeforeUpload() throws {
        let workspace = try ProviderUploadWorkspace(); defer { workspace.close() }
        let file = workspace.url.appendingPathComponent("part-0000.wav")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(ProviderClient.maximumUploadBytes)); try handle.close()
        XCTAssertThrowsError(try ProviderUploadPlan(["sample_rate": 16000, "frames": 16000,
            "parts": [["path": file.path, "start_frame": 0, "frames": 16000]]], directory: workspace.url))
    }
}
