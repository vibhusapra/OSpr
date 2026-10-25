// Temporarily copy into platform tests. Real local file ASR via AppModel;
// private public-fixture profile, background services off, no native UI.
import CryptoKit
import Foundation
import XCTest
@testable import OSpr
@testable import OSprCore

final class DurableImportRealTemporary: XCTestCase {
    @MainActor private func settle(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(180)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard condition() else { throw OSprError.message("Real local import did not finish within the control deadline.") }
    }
    private func fingerprint(_ record: Transcript) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(record)).map { String(format: "%02x", $0) }.joined()
    }
    @MainActor func testStage() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let stage = env["OSPR_REAL_IMPORT_STAGE"], let path = env["OSPR_REAL_IMPORT_ROOT"], let engine = env["OSPR_REAL_IMPORT_ENGINE"], let audio = env["OSPR_REAL_IMPORT_AUDIO"] else { throw XCTSkip("Explicit public-fixture local-ASR probe only.") }
        let root = URL(fileURLWithPath: path), fixture = URL(fileURLWithPath: audio)
        guard root.lastPathComponent.hasPrefix("ospr-real-import-"), ["import-retry", "restart"].contains(stage) else { throw OSprError.message("Use a fresh disposable real-import profile.") }
        if stage == "import-retry" {
            guard !FileManager.default.fileExists(atPath: path) else { throw OSprError.message("Refusing to replace an existing real-import profile.") }
            let store = try LocalStore(directory: root)
            var settings = OSprSettings(); settings.rootPath = engine; settings.model = "parakeet-v3"; settings.mode = .verbatim
            settings.saveHistory = true; settings.autoPaste = false; settings.retentionDays = 0; settings.keepAudio = false
            try store.write(settings, name: "settings.json")
            try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("first.wav"))
            try Data("Public malformed-file control".utf8).write(to: root.appendingPathComponent("bad.wav"))
        }
        let app = AppModel(instanceLock: try AppInstanceLock(directory: root), directory: root, enableServices: false)
        try await settle { !app.busy }
        if stage == "import-retry" {
            app.importFiles([root.appendingPathComponent("first.wav"), root.appendingPathComponent("bad.wav")])
            try await settle { !app.busy }
            XCTAssertEqual(app.importBatch?.items.map(\.state), [.completed, .failed])
            let batch = try XCTUnwrap(app.importBatch), ids = batch.items.map(\.resultID)
            let maybeFirst = try await app.historyState.record(id: ids[0]), first = try XCTUnwrap(maybeFirst)
            XCTAssertFalse(first.rawText.isEmpty); XCTAssertEqual(first.rawText, first.text)
            let before = try fingerprint(first), failure = try XCTUnwrap(batch.items[1].message)
            try FileManager.default.removeItem(at: root.appendingPathComponent("bad.wav"))
            try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("bad.wav"))
            app.settings.model = "whisper-small"; app.settings.language = "fr"
            app.retryImports(); try await settle { !app.busy }
            XCTAssertEqual(app.importBatch?.completedCount, 2)
            XCTAssertEqual(app.importBatch?.items.compactMap(\.transcriptID), ids)
            let maybeKept = try await app.historyState.record(id: ids[0]), kept = try XCTUnwrap(maybeKept)
            let maybeSecond = try await app.historyState.record(id: ids[1]), second = try XCTUnwrap(maybeSecond)
            XCTAssertEqual(try fingerprint(kept), before)
            XCTAssertEqual(second.rawText, first.rawText); XCTAssertEqual(second.model, first.model)
            try await app.prepareForTermination()
            let result: [String: Any] = ["status": "passed", "model": first.model, "provider": "local", "raw_text": first.rawText,
                "malformed_file_message": failure, "result_ids": ids.map(\.uuidString), "first_payload_sha256": before,
                "first_payload_unchanged_after_retry": true, "history_records": 2, "original_configuration_preserved": true]
            try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]).write(to: root.appendingPathComponent("import-retry-result.json"), options: .atomic)
        } else {
            let prior = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("import-retry-result.json"))) as? [String: Any])
            let ids = try XCTUnwrap(prior["result_ids"] as? [String])
            XCTAssertTrue(app.importRecovered); XCTAssertEqual(app.importBatch?.completedCount, 2)
            XCTAssertEqual(app.importBatch?.retryCount, 0)
            XCTAssertEqual(app.importBatch?.items.compactMap { $0.transcriptID?.uuidString }, ids)
            let maybeFirst = try await app.historyState.record(id: try XCTUnwrap(UUID(uuidString: ids[0]))), first = try XCTUnwrap(maybeFirst)
            XCTAssertEqual(try fingerprint(first), prior["first_payload_sha256"] as? String)
            XCTAssertEqual(try HistoryDatabase(directory: root).statistics().records, 2)
            try await app.prepareForTermination()
            let result: [String: Any] = ["status": "passed", "history_records": 2, "result_ids_preserved": true,
                "first_payload_preserved": true, "all_completed_no_resume_needed": true]
            try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]).write(to: root.appendingPathComponent("restart-result.json"), options: .atomic)
        }
    }
}
