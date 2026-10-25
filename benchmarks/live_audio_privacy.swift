import XCTest
import CryptoKit
@testable import OSpr
@testable import OSprCore

/// Invoked only by live_audio_privacy.py in an isolated, owned profile.
final class LiveAudioPrivacyTemporary: XCTestCase {
    @MainActor private func settle(_ condition: () -> Bool) async throws {
        let until = Date().addingTimeInterval(45)
        while !condition() {
            guard Date() < until else { throw OSprError.message("Real audio privacy control did not settle") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func json(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    @MainActor func testStage() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["OSPR_AUDIO_PRIVACY_ROOT"], let stage = env["OSPR_AUDIO_PRIVACY_STAGE"] else { throw XCTSkip("Run using the owned real-audio privacy harness") }
        let root = URL(fileURLWithPath: path), profile = root.appendingPathComponent("Profile")
        let metadata = root.appendingPathComponent("exercise.json")
        if stage == "exercise" {
            var settings = OSprSettings()
            settings.rootPath = root.appendingPathComponent("engine").path; settings.saveHistory = true; settings.keepAudio = true
            settings.mode = .verbatim; settings.autoPaste = false; settings.model = "parakeet-v3"; settings.retentionDays = 0
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            try json(settings).write(to: profile.appendingPathComponent("settings.json"))
            let app = AppModel(instanceLock: try AppInstanceLock(directory: profile), directory: profile, enableServices: false)
            try await settle { !app.busy }
            let priorSource = root.appendingPathComponent("prior.wav"), active = root.appendingPathComponent("active.wav"), later = root.appendingPathComponent("later.wav")
            let original = try Data(contentsOf: priorSource)
            app.importFiles([priorSource]); try await settle { !app.busy }
            let oldID = try XCTUnwrap(app.importBatch?.items.first?.transcriptID)
            let oldValue = try await app.historyState.record(id: oldID), old = try XCTUnwrap(oldValue)
            XCTAssertFalse(old.text.isEmpty)
            let oldPayload = try json(old), audioName = try XCTUnwrap(old.audioFile)
            let audioURL = profile.appendingPathComponent("Audio/" + audioName), oldAudio = try Data(contentsOf: audioURL)
            app.importFiles([active, later])
            let admission = root.appendingPathComponent("engine/admitted.json")
            try await settle { FileManager.default.fileExists(atPath: admission.path) }
            let marker = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: admission)) as? [String: Any])
            let inferencePath = try XCTUnwrap(marker["path"] as? String)
            XCTAssertTrue(inferencePath.hasPrefix(profile.appendingPathComponent("Audio").path + "/"))
            XCTAssertEqual(marker["generation_call"] as? Int, 2)
            let device = try XCTUnwrap(marker["device"] as? String)
            XCTAssertTrue(device.contains("gpu"), "This control requires the local MLX GPU device")
            app.settings.keepAudio = false; app.saveOSprSettings()
            try await settle { !app.audioMaintenance }
            XCTAssertTrue(FileManager.default.fileExists(atPath: inferencePath))
            try Data().write(to: root.appendingPathComponent("engine/release-generation"))
            try await settle { !app.busy }
            XCTAssertEqual(app.importBatch?.completedCount, 2)
            var ids = [UUID](), texts = [String]()
            for item in app.importBatch?.items ?? [] {
                let id = try XCTUnwrap(item.transcriptID); ids.append(id); XCTAssertEqual(id, item.resultID)
                let stored = try await app.historyState.record(id: id), record = try XCTUnwrap(stored)
                XCTAssertNil(record.audioFile)
                XCTAssertNil(record.warning)
                XCTAssertEqual(record.text, old.text); XCTAssertEqual(record.rawText, old.rawText)
                XCTAssertEqual(record.model, old.model); XCTAssertEqual(record.duration, old.duration)
                XCTAssertEqual(try json(record.segments), try json(old.segments))
                texts.append(record.text)
            }
            let reloadedValue = try await app.historyState.record(id: oldID), reloaded = try XCTUnwrap(reloadedValue)
            XCTAssertEqual(try json(reloaded), oldPayload)
            XCTAssertEqual(try Data(contentsOf: audioURL), oldAudio)
            try await settle {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: profile.appendingPathComponent("Audio").path)) ?? []
                return Set(names) == [audioName]
            }
            for url in [priorSource, active, later] { XCTAssertEqual(try Data(contentsOf: url), original) }
            try await app.prepareForTermination()
            let result: [String: Any] = ["status": "passed", "old_id": oldID.uuidString, "new_ids": ids.map(\.uuidString),
                "old_payload_sha256": sha(oldPayload), "old_audio_sha256": sha(oldAudio), "audio_name": audioName,
                "source_sha256": sha(original), "texts": texts, "worker_pid": marker["worker_pid"]!, "device": device,
                "admission_boundary": "After actual review preparation/adoption, before second real model.generate call; gate released after live preference save",
                "all_new_audio_absent": true, "prior_payload_and_audio_unchanged": true, "source_bytes_unchanged": true]
            try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: metadata, options: .atomic)
        } else if stage == "restart" {
            let previous = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
            let app = AppModel(instanceLock: try AppInstanceLock(directory: profile), directory: profile, enableServices: false)
            try await settle { !app.busy }
            XCTAssertFalse(app.settings.keepAudio)
            let id = try XCTUnwrap(UUID(uuidString: XCTUnwrap(previous["old_id"] as? String)))
            let oldValue = try await app.historyState.record(id: id), old = try XCTUnwrap(oldValue)
            XCTAssertEqual(sha(try json(old)), previous["old_payload_sha256"] as? String)
            let audioName = try XCTUnwrap(previous["audio_name"] as? String)
            XCTAssertEqual(sha(try Data(contentsOf: profile.appendingPathComponent("Audio/" + audioName))), previous["old_audio_sha256"] as? String)
            for (index, textID) in try XCTUnwrap(previous["new_ids"] as? [String]).enumerated() {
                let recordID = try XCTUnwrap(UUID(uuidString: textID))
                let value = try await app.historyState.record(id: recordID), record = try XCTUnwrap(value)
                XCTAssertNil(record.audioFile); XCTAssertEqual(record.text, (previous["texts"] as? [String])?[index])
            }
            XCTAssertEqual(try HistoryDatabase(directory: profile).statistics().records, 3)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: profile.appendingPathComponent("Audio").path)), [audioName])
            try await app.prepareForTermination()
            try JSONSerialization.data(withJSONObject: ["status": "passed", "records": 3, "new_audio_references": 0, "retained_audio_files": 1, "prior_payload_preserved": true], options: [.sortedKeys]).write(to: root.appendingPathComponent("restart.json"), options: .atomic)
        } else { XCTFail("Unknown real-audio stage") }
    }
}
