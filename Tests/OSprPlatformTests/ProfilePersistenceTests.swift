import XCTest
@testable import OSpr
@testable import OSprCore

final class ProfilePersistenceTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-profile-save-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    @MainActor func testAllOverridesEditAndRemovalSurviveModelRestart() async throws {
        let directory = try directory()
        let profile = AppProfile(bundleID: "com.example.browser", mode: .custom, enabled: false,
            name: "Technical notes", site: "https://example.org/project", localModel: "whisper-turbo",
            language: "en-GB", customPrompt: "Keep exact identifiers and uncertainty.")
        weak var previous: AppModel?
        do {
            let app = AppModel(instanceLock: try AppInstanceLock(directory: directory), directory: directory, enableServices: false)
            previous = app
            try app.saveProfile(profile)
            XCTAssertEqual(app.settings.profiles, [profile])
            try await app.prepareForTermination()
        }
        var lease: AppInstanceLock?
        for _ in 0..<1000 {
            do { lease = try AppInstanceLock(directory: directory); break }
            catch AppInstanceLock.Failure.alreadyRunning { try await Task.sleep(for: .milliseconds(5)) }
        }
        XCTAssertNil(previous)
        let restarted = AppModel(instanceLock: try XCTUnwrap(lease), directory: directory, enableServices: false)
        XCTAssertEqual(restarted.settings.profiles, [profile])
        var edited = profile
        edited.mode = .translate; edited.customPrompt = nil; edited.translationLanguage = "French"; edited.enabled = true
        try restarted.saveProfile(edited)
        let store = try LocalStore(directory: directory)
        XCTAssertEqual(try store.read(OSprSettings.self, name: "settings.json")?.profiles, [edited])
        try restarted.removeProfile(profile.id)
        XCTAssertTrue(restarted.settings.profiles.isEmpty)
        XCTAssertEqual(try store.read(OSprSettings.self, name: "settings.json")?.profiles, [])
        try await restarted.prepareForTermination()
    }

    @MainActor func testProfileMutationDoesNotCommitPendingGlobalsOrApplyRetention() async throws {
        let directory = try directory(), store = try LocalStore(directory: directory)
        var persisted = OSprSettings(); persisted.retentionDays = 0; persisted.customPrompt = "Saved global instruction."
        try store.write(persisted, name: "settings.json")
        let app = AppModel(instanceLock: try AppInstanceLock(directory: directory), directory: directory, enableServices: false)
        let record = Transcript(rawText: "Keep this public fixture.", text: "Keep this public fixture.", model: "fixture", mode: .verbatim, duration: 1, latencyMS: 1)
        app.historyState.submit(record, select: true); try await app.historyState.flush()
        let database = try HistoryDatabase(directory: directory)
        let before = try database.contentFingerprint()
        app.settings.saveHistory = false; app.settings.retentionDays = 1; app.settings.customPrompt = "Unsaved global instruction."
        app.settings.transcriptionProvider = "compatible"
        let profile = AppProfile(bundleID: "com.example.editor", mode: .code)
        try app.saveProfile(profile)
        var expected = persisted; expected.profiles = [profile]
        XCTAssertEqual(try store.read(OSprSettings.self, name: "settings.json"), expected)
        XCTAssertFalse(app.settings.saveHistory); XCTAssertEqual(app.settings.customPrompt, "Unsaved global instruction.")
        XCTAssertEqual(app.settings.transcriptionProvider, "compatible")
        XCTAssertEqual(try database.contentFingerprint(), before)
        XCTAssertEqual(try database.record(id: record.id)?.rawText, record.rawText)
        try app.removeProfile(profile.id)
        XCTAssertEqual(try store.read(OSprSettings.self, name: "settings.json"), persisted)
        XCTAssertEqual(try database.contentFingerprint(), before)
        XCTAssertEqual(try database.record(id: record.id)?.rawText, record.rawText)
        try await app.prepareForTermination()
    }

    @MainActor func testDuplicateAndInvalidProfilesPreserveFileAndPublishedList() async throws {
        let directory = try directory()
        let app = AppModel(instanceLock: try AppInstanceLock(directory: directory), directory: directory, enableServices: false)
        let profile = AppProfile(bundleID: "com.example.browser", site: "https://example.org/team")
        try app.saveProfile(profile)
        let url = directory.appendingPathComponent("settings.json"), original = try Data(contentsOf: url)
        XCTAssertThrowsError(try app.saveProfile(AppProfile(bundleID: profile.bundleID, site: "https://EXAMPLE.org:443/team/")))
        XCTAssertThrowsError(try app.saveProfile(AppProfile(bundleID: "", mode: .custom)))
        XCTAssertEqual(app.settings.profiles, [profile]); XCTAssertEqual(try Data(contentsOf: url), original)
        try await app.prepareForTermination()
    }

    @MainActor func testUnreadableSettingsAreNotReplacedByProfileSaveOrDelete() async throws {
        let directory = try directory()
        let app = AppModel(instanceLock: try AppInstanceLock(directory: directory), directory: directory, enableServices: false)
        let profile = AppProfile(bundleID: "com.example.editor")
        try app.saveProfile(profile)
        let url = directory.appendingPathComponent("settings.json"), broken = Data("{ public malformed fixture".utf8)
        try broken.write(to: url)
        XCTAssertThrowsError(try app.saveProfile(AppProfile(bundleID: "com.example.other")))
        XCTAssertThrowsError(try app.removeProfile(profile.id))
        XCTAssertEqual(app.settings.profiles, [profile]); XCTAssertEqual(try Data(contentsOf: url), broken)
        try await app.prepareForTermination()
    }

    @MainActor func testUnacknowledgedWriteDoesNotPublishProfileMutation() async throws {
        let directory = try directory()
        let app = AppModel(instanceLock: try AppInstanceLock(directory: directory), directory: directory, enableServices: false)
        let url = directory.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try app.saveProfile(AppProfile(bundleID: "com.example.editor")))
        XCTAssertTrue(app.settings.profiles.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty)
        try await app.prepareForTermination()
    }

    @MainActor func testClosingRefusesProfileMutations() async throws {
        let directory = try directory()
        let app = AppModel(instanceLock: try AppInstanceLock(directory: directory), directory: directory, enableServices: false)
        let profile = AppProfile(bundleID: "com.example.editor")
        try app.saveProfile(profile)
        try await app.prepareForTermination()
        let url = directory.appendingPathComponent("settings.json"), before = try Data(contentsOf: url)
        XCTAssertThrowsError(try app.saveProfile(AppProfile(bundleID: "com.example.other")))
        XCTAssertThrowsError(try app.removeProfile(profile.id))
        XCTAssertEqual(app.settings.profiles, [profile]); XCTAssertEqual(try Data(contentsOf: url), before)
    }
}
