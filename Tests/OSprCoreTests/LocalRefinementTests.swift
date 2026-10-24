import XCTest
@testable import OSprCore

final class LocalRefinementTests: XCTestCase {
    func testDefaultAndLargerChoicePersistWithoutReusingCloudModelField() throws {
        var settings = OSprSettings()
        XCTAssertNil(settings.localRefinementModel)
        settings.rewriteModel = "retained-cloud-deployment"
        for choice in LocalRefinementModel.allCases {
            settings.rewriteProvider = choice.rawValue
            let encoded = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(OSprSettings.self, from: encoded)
            XCTAssertEqual(decoded.localRefinementModel, choice)
            XCTAssertEqual(decoded.rewriteModel, "retained-cloud-deployment")
            XCTAssertEqual((try JSONSerialization.jsonObject(with: encoded) as? [String: Any])?["rewriteProvider"] as? String, choice.rawValue)
        }
    }
    func testRequestKeepsExplicitModelAndEditingTask() {
        for choice in LocalRefinementModel.allCases {
            let normal = choice.request(text: "Question?", instruction: "Clean.")
            XCTAssertEqual(normal["model"] as? String, choice.workerModel)
            XCTAssertEqual(normal["task"] as? String, "transcript")
            let editing = choice.request(text: "Selected passage.", instruction: "Edit.", editingSelection: true)
            XCTAssertEqual(editing["task"] as? String, "edit-selection")
            XCTAssertEqual(editing["model"] as? String, choice.workerModel)
        }
    }
    func testOnlySelectedModelWithAcknowledgedCompletionCanReturnText() throws {
        let choice = LocalRefinementModel.larger
        let valid: [String: Any] = ["model": choice.repository, "text": "完了。", "finish_reason": "stop", "generation_tokens": 3]
        XCTAssertEqual(try choice.completedText(valid), "完了。")
        var malformed = valid
        for (field, value) in [("model", LocalRefinementModel.standard.repository as Any), ("finish_reason", "length"),
                               ("generation_tokens", 0), ("generation_tokens", true), ("generation_tokens", 4097), ("text", " ")] {
            malformed = valid; malformed[field] = value
            XCTAssertThrowsError(try choice.completedText(malformed), field)
        }
        for field in ["model", "finish_reason", "generation_tokens"] {
            malformed = valid; malformed.removeValue(forKey: field)
            XCTAssertThrowsError(try choice.completedText(malformed), "Older engine must not silently substitute a model: \(field)")
        }
    }
    func testOlderProviderParserRefusesTheNewTagBeforeEndpointValidation() async {
        do {
            _ = try await ProviderClient.rewrite(text: "Public fixture.", instruction: "Clean.", provider: LocalRefinementModel.larger.rawValue,
                                                 base: "not a URL", model: "unused", key: "")
            XCTFail("Local model tags must never become remote compatible requests")
        } catch { XCTAssertEqual(error.localizedDescription, "Choose a supported rewrite provider in Settings.") }
    }
}
