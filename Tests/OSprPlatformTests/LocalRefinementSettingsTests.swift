import XCTest
@testable import OSpr
@testable import OSprCore

final class LocalRefinementSettingsTests: XCTestCase {
    @MainActor func testLargerChoiceIsLocalDespiteUnusedCloudURLAndSurvivesRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-local-text-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let app = AppModel(instanceLock: try AppInstanceLock(directory: directory), directory: directory, enableServices: false)
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
        let restarted = AppModel(instanceLock: try AppInstanceLock(directory: directory), directory: directory, enableServices: false)
        XCTAssertEqual(restarted.settings.localRefinementModel, .larger)
        XCTAssertEqual(restarted.settings.rewriteModel, "retained-cloud-model")
        XCTAssertTrue(restarted.localOnly)
        try await restarted.prepareForTermination()
    }
}
