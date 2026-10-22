import XCTest
@testable import OSprCore

final class RecoveryTests: XCTestCase {
    func testCompletedTakeSurvivesRestartAndCannotBeOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = try RecordingRecovery(directory: root)
        let audio = root.appendingPathComponent("input.wav")
        let bytes = Data([82, 73, 70, 70, 1, 2, 3])
        try bytes.write(to: audio)
        _ = try recovery.preserve(audio: audio, duration: 3.5, settings: OSprSettings(), mode: .clean)
        let reopened = try RecordingRecovery(directory: root)
        XCTAssertEqual(try reopened.load()?.duration, 3.5)
        XCTAssertEqual(try Data(contentsOf: reopened.audioURL), bytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: reopened.audioURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try reopened.preserve(audio: audio, duration: 2, settings: OSprSettings(), mode: .verbatim))
        try reopened.discard()
        XCTAssertNil(try reopened.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.audioURL.path))
    }
    func testBrokenMetadataKeepsAudioForExportInsteadOfSilentlyDeletingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = try RecordingRecovery(directory: root)
        try Data([1, 2, 3]).write(to: recovery.audioURL)
        XCTAssertThrowsError(try recovery.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.audioURL.path))
        try recovery.discard()
    }
}
