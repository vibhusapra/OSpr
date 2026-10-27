// Headless preparation/verification around a separate native UI acceptance run.
// This never presses a button or claims native interaction from stored state.
import CryptoKit
import Foundation
import XCTest
@testable import OSpr
@testable import OSprCore

final class NativeBatchAcceptanceTemporary: XCTestCase {
    @MainActor private func settle(_ condition: () -> Bool) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(120))
        while !condition() {
            guard ContinuousClock.now < limit else { throw OSprError.message("Native batch fixture did not settle") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private func hash(_ record: Transcript) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(record)).map { String(format: "%02x", $0) }.joined()
    }
    private func emit(_ value: [String: Any], _ name: String, _ output: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent(name), options: .atomic)
    }
    @MainActor func testStage() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let stage = env["OSPR_NATIVE_BATCH_STAGE"], let path = env["OSPR_NATIVE_BATCH_OUTPUT"],
              let engine = env["OSPR_NATIVE_BATCH_ENGINE"] else { throw XCTSkip("Explicit owned-profile native batch harness only") }
        let output = URL(fileURLWithPath: path), profile = output.appendingPathComponent("ospr-native-batch-profile")
        guard ["prepare", "verify-resumed", "verify-dismissed", "verify-cancelled"].contains(stage) else {
            throw OSprError.message("Unknown native batch stage")
        }
        if stage == "prepare" {
            guard !FileManager.default.fileExists(atPath: profile.path) else { throw OSprError.message("Refusing to replace a native fixture profile") }
            let store = try LocalStore(directory: profile)
            var config = OSprSettings(); config.rootPath = engine; config.model = "parakeet-v3"; config.language = "en"
            config.mode = .verbatim; config.saveHistory = true; config.retentionDays = 0; config.keepAudio = false; config.autoPaste = false
            try store.write(config, name: "settings.json")
        }
        var app: AppModel? = AppModel(instanceLock: try AppInstanceLock(directory: profile), directory: profile, enableServices: false)
        try await settle { app?.busy == false && app?.historyState.loading == false }
        if stage == "prepare" {
            let files = ["Resume Alpha.wav", "Resume Repair.wav", "Resume Omega.wav"]
                .map { output.appendingPathComponent("inputs").appendingPathComponent($0) }
            app!.importFiles(files); try await settle { app?.busy == false }
            let batch = try XCTUnwrap(app!.importBatch)
            XCTAssertEqual(batch.items.map(\.state), [.completed, .failed, .completed])
            XCTAssertEqual(app!.historyState.statistics.records, 2)
            var hashes: [String: String] = [:]
            for item in batch.items where item.transcriptID != nil {
                let pending = try await app!.historyState.record(id: item.resultID), record = try XCTUnwrap(pending)
                XCTAssertNil(record.audioFile); XCTAssertEqual(record.text, record.rawText)
                XCTAssertTrue(record.rawText.lowercased().contains("quilter"))
                hashes[item.resultID.uuidString] = try hash(record)
            }
            try await app!.prepareForTermination()
            try emit(["status": "prepared-real-local-two-complete-one-failed", "planned_ids": batch.items.map { $0.resultID.uuidString },
                      "completed_payload_sha256": hashes, "history_records": 2, "provider": "local", "model": "parakeet-v3",
                      "language": "en", "mode": "verbatim", "native_interaction_proven": false], "prepare-result.json", output)
        } else {
            let baselineName = stage == "verify-resumed" ? "prepare-result.json" : "verify-resumed-result.json"
            let before = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent(baselineName))) as? [String: Any])
            let expected = try XCTUnwrap(before["planned_ids"] as? [String])
            let oldHashes = try XCTUnwrap(before["completed_payload_sha256"] as? [String: String])
            XCTAssertEqual(app!.historyState.statistics.records, 3)
            var hashes: [String: String] = [:], texts: [String] = []
            for id in expected {
                let pending = try await app!.historyState.record(id: try XCTUnwrap(UUID(uuidString: id)))
                let record = try XCTUnwrap(pending), digest = try hash(record)
                if let old = oldHashes[id] { XCTAssertEqual(digest, old) }
                XCTAssertNil(record.audioFile); XCTAssertEqual(record.text, record.rawText)
                XCTAssertEqual(record.model, "parakeet-v3"); texts.append(record.rawText); hashes[id] = digest
            }
            XCTAssertEqual(Set(texts).count, 1)
            if stage == "verify-resumed" {
                XCTAssertTrue(app!.importRecovered); XCTAssertEqual(app!.importBatch?.completedCount, 3)
                XCTAssertEqual(app!.importBatch?.retryCount, 0)
                XCTAssertEqual(app!.importBatch?.items.map { $0.resultID.uuidString }, expected)
                XCTAssertEqual(app!.importBatch?.items.compactMap { $0.transcriptID?.uuidString }, expected)
            } else if stage == "verify-dismissed" {
                XCTAssertNil(app!.importBatch)
                XCTAssertFalse(FileManager.default.fileExists(atPath: profile.appendingPathComponent(FileImportJournal.fileName).path))
            } else {
                let batch = try XCTUnwrap(app!.importBatch)
                XCTAssertEqual(batch.items.count, 2); XCTAssertEqual(batch.items.map(\.state), [.cancelled, .cancelled])
                XCTAssertTrue(batch.items.allSatisfy { $0.transcriptID == nil && !$0.historyCommitted })
                XCTAssertEqual(batch.retryCount, 2)
            }
            try await app!.prepareForTermination()
            try emit(["status": "passed-" + stage + "-stored-invariants", "planned_ids": expected, "completed_payload_sha256": hashes,
                      "history_records": 3, "prior_payloads_preserved": true, "raw_text_matches_original": true,
                      "new_audio_references": 0, "native_interaction_proven": false], stage + "-result.json", output)
        }
        weak var released = app; app = nil; try await settle { released == nil }
    }
}
