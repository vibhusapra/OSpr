import XCTest
@testable import OSpr
@testable import OSprCore

final class LocalRefinementSettingsTests: XCTestCase {
    @MainActor func testLargerChoiceIsLocalDespiteUnusedCloudURLAndSurvivesRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-local-text-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        weak var previous: AppModel?
        do {
            let app = AppModel(instanceLock: try AppInstanceLock(directory: directory), directory: directory, enableServices: false)
            previous = app
            app.settings.rewriteProvider = LocalRefinementModel.larger.rawValue
            app.settings.rewriteURL = "https://example.invalid/v1"
            app.settings.rewriteModel = "retained-cloud-model"
            XCTAssertTrue(app.localOnly)
            app.settings.transcriptionProvider = "compatible"
            XCTAssertFalse(app.localOnly)
            app.settings.transcriptionProvider = "local"
            app.saveOSprSettings()
            try await app.prepareForTermination()
        }
        // The repository intentionally keeps its GUI lease until queued SQLite
        // teardown finishes. Simulate process exit by waiting for that release,
        // rather than racing a second model against the old owner.
        var acquired: AppInstanceLock?
        for _ in 0..<1000 {
            do { acquired = try AppInstanceLock(directory: directory); break }
            catch AppInstanceLock.Failure.alreadyRunning { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        XCTAssertNil(previous)
        let restarted = AppModel(instanceLock: try XCTUnwrap(acquired), directory: directory, enableServices: false)
        XCTAssertEqual(restarted.settings.localRefinementModel, .larger)
        XCTAssertEqual(restarted.settings.rewriteModel, "retained-cloud-model")
        XCTAssertTrue(restarted.localOnly)
        try await restarted.prepareForTermination()
    }
}
