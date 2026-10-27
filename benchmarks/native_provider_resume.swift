// Own-profile preparation/storage verification around separately observed UI.
import Foundation
import XCTest
@testable import OSpr
@testable import OSprCore

final class NativeProviderResumeTemporary: XCTestCase {
    @MainActor private func settle(_ test: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(15))
        while !test() {
            guard ContinuousClock.now < end else { throw OSprError.message("Provider fixture did not settle") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor func testStage() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let stage = env["OSPR_PROVIDER_RESUME_STAGE"], let path = env["OSPR_PROVIDER_RESUME_ROOT"] else {
            throw XCTSkip("Explicit local provider fixture only")
        }
        let root = URL(fileURLWithPath: path), profile = root.appendingPathComponent("ospr-native-provider-profile")
        let plan = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("server.json"))) as? [String: Any])
        let savedURL = try XCTUnwrap(plan["saved_base"] as? String), currentURL = try XCTUnwrap(plan["current_base"] as? String)
        let model = try XCTUnwrap(plan["saved_model"] as? String), text = try XCTUnwrap(plan["response_text"] as? String)
        if stage == "prepare" {
            guard !FileManager.default.fileExists(atPath: profile.path) else { throw OSprError.message("Refusing to replace a provider fixture profile") }
            let store = try LocalStore(directory: profile)
            var current = OSprSettings(); current.mode = .verbatim; current.model = "whisper-small"; current.language = "fr"
            current.transcriptionProvider = "local"; current.transcriptionURL = currentURL
            current.transcriptionModel = "current-model-must-not-be-sent"; current.vocabulary = "current vocabulary must not be uploaded"
            current.keepAudio = false; current.autoPaste = false; current.saveHistory = true; current.retentionDays = 0
            try store.write(current, name: "settings.json")
            var saved = current; saved.transcriptionProvider = "compatible"; saved.transcriptionURL = savedURL
            saved.transcriptionModel = model; saved.language = "en"; saved.vocabulary = "original public vocabulary"
            let batch = FileImportBatch(urls: [root.appendingPathComponent("Provider Resume.wav")])
            try await FileImportJournal(directory: profile).save(FileImportSnapshot(batch: batch, settings: saved), revision: 1)
            try JSONSerialization.data(withJSONObject: ["planned_id": batch.items[0].resultID.uuidString, "native_interaction_proven": false], options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("prepare-result.json"))
            return
        }
        guard ["verify-declined", "verify-completed"].contains(stage) else { throw OSprError.message("Unknown provider fixture stage") }
        let prepared = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("prepare-result.json"))) as? [String: Any])
        let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(prepared["planned_id"] as? String)))
        var app: AppModel? = AppModel(instanceLock: try AppInstanceLock(directory: profile), directory: profile, enableServices: false)
        try await settle { app?.busy == false && app?.historyState.loading == false }
        XCTAssertEqual(app!.settings.transcriptionProvider, "local"); XCTAssertEqual(app!.settings.transcriptionURL, currentURL)
        XCTAssertEqual(app!.settings.model, "whisper-small"); XCTAssertEqual(app!.settings.language, "fr")
        XCTAssertEqual(app!.importBatch?.items.first?.resultID, id)
        XCTAssertTrue(app!.importRecovered)
        if stage == "verify-declined" {
            XCTAssertEqual(app!.historyState.statistics.records, 0)
            XCTAssertEqual(app!.importBatch?.retryCount, 1)
            XCTAssertNil(app!.importBatch?.items.first?.transcriptID)
        } else {
            XCTAssertEqual(app!.historyState.statistics.records, 1); XCTAssertEqual(app!.importBatch?.completedCount, 1)
            XCTAssertEqual(app!.importBatch?.retryCount, 0)
            let pending = try await app!.historyState.record(id: id), record = try XCTUnwrap(pending)
            XCTAssertEqual(record.rawText, text); XCTAssertEqual(record.text, text)
            XCTAssertEqual(record.model, model); XCTAssertEqual(record.source, "Provider Resume.wav")
            XCTAssertNil(record.audioFile); XCTAssertEqual(app!.importBatch?.items.first?.transcriptID, id)
        }
        try await app!.prepareForTermination()
        weak var released = app; app = nil; try await settle { released == nil }
        let result: [String: Any] = ["status": "passed-" + stage, "planned_id": id.uuidString,
            "current_global_local_settings_preserved": true, "native_interaction_proven": false,
            "records": stage == "verify-declined" ? 0 : 1]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent(stage + "-result.json"))
    }
}
