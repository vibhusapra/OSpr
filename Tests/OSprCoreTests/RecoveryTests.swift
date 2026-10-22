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
    func testRawMeetingTracksSurviveRestartAndBecomeOneRecoverableMix() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = try RecordingRecovery(directory: root.appendingPathComponent("Recovery"))
        let first = root.appendingPathComponent("first.wav"), second = root.appendingPathComponent("second.wav"), mixed = root.appendingPathComponent("mixed.wav")
        try Data([1, 2]).write(to: first); try Data([3, 4]).write(to: second); try Data([5, 6]).write(to: mixed)
        _ = try recovery.preserveTracks([.init(url: first, start: 1000), .init(url: second, start: 1000.25)], duration: 3,
            settings: OSprSettings(), warning: "Device disconnected")
        let reopened = try RecordingRecovery(directory: recovery.directory)
        XCTAssertTrue(reopened.exists); XCTAssertTrue(reopened.needsMix)
        XCTAssertEqual(try reopened.mixSources().map(\.start), [1000, 1000.25])
        XCTAssertEqual(try reopened.load()?.captureWarning, "Device disconnected")
        try reopened.replaceWithMix(mixed)
        XCTAssertFalse(reopened.needsMix)
        XCTAssertNil(try reopened.load()?.tracks)
        XCTAssertEqual(try Data(contentsOf: reopened.audioURL), Data([5, 6]))
        XCTAssertEqual(reopened.managedAudio.count, 1)
        try reopened.discard(); XCTAssertFalse(reopened.exists)
    }
    func testMeetingRecoveryRejectsPathTraversalAndMissingTracks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = try RecordingRecovery(directory: root)
        let source = root.appendingPathComponent("source.wav"); try Data([1]).write(to: source)
        var pending = try recovery.preserveTracks([.init(url: source, start: 1)], duration: 1, settings: OSprSettings())
        pending.tracks = [RecoveredTrack(name: "../source.wav", start: 1)]
        try LocalStore(directory: root).write(pending, name: "pending.json")
        XCTAssertThrowsError(try recovery.load())
        XCTAssertTrue(recovery.exists)
        try recovery.discard()
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
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
