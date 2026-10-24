import XCTest
import Foundation
import CryptoKit
@testable import OSpr
@testable import OSprCore

final class RealArchiveUpgradeTemporary: XCTestCase {
    @MainActor private func settle(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw OSprError.message("Private upgrade fixture did not settle") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    @MainActor func testIsolatedExistingArchiveUpgradeAndRestart() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OSPR_UPGRADE_COPY"]!)
        let path = root.appendingPathComponent("profile")
        let store = try LocalStore(directory: path)
        let original = try XCTUnwrap(store.read([Transcript].self, name: "history.json"))
        let config = try XCTUnwrap(store.read(OSprSettings.self, name: "settings.json")).validated()
        let retained = LocalStore.retained(original, days: config.retentionDays)
        guard config.saveHistory, !retained.isEmpty else { throw OSprError.message("Fixture policy needs a separate session-only acceptance check") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        func same(_ a: Transcript, _ b: Transcript) throws -> Bool { try encoder.encode(a) == encoder.encode(b) }
        let audio = try Dictionary(uniqueKeysWithValues: retained.compactMap(\.audioFile).map { name in
            (name, Data(SHA256.hash(data: try Data(contentsOf: path.appendingPathComponent("Audio").appendingPathComponent(name)))))
        })
        var app: AppModel? = AppModel(instanceLock: try AppInstanceLock(directory: path), directory: path, enableServices: false)
        try await settle { app?.audioMaintenance == false && app?.historyState.loading == false }
        guard app!.error.isEmpty else {
            try Data(app!.error.utf8).write(to: root.appendingPathComponent("startup-error-private.txt"))
            throw OSprError.message("Private migration startup failed; details kept locally")
        }
        XCTAssertTrue(app!.settings == config, "Validated configuration changed")
        XCTAssertTrue(app!.historyState.statistics.records == retained.count, "Retained record count changed")
        XCTAssertTrue(app!.historyState.rows.map(\.id) == retained.map(\.id), "Legacy record order changed")
        for value in retained {
            let pending = try await app!.historyState.record(id: value.id)
            let saved = try XCTUnwrap(pending)
            XCTAssertTrue(try same(saved, value), "Canonical migrated record fields changed")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent("history.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathComponent(HistoryDatabase.fileName).path))
        var searchChecked = false
        for value in retained {
            if let term = value.text.split(whereSeparator: { !$0.isLetter }).first(where: { $0.count >= 3 && $0.unicodeScalars.allSatisfy { $0.isASCII } }) {
                app!.historyState.query = String(term)
                try await settle { app!.historyState.loading == false }
                XCTAssertTrue(app!.historyState.rows.contains { $0.id == value.id }, "A migrated record was missing from search")
                searchChecked = true; break
            }
        }
        let chosen = retained[0]
        let marker = "OSpr isolated upgrade copy edit."
        app!.historyState.updateText(id: chosen.id, text: marker)
        try await app!.prepareForTermination()
        weak var stopped = app; app = nil
        try await settle { stopped == nil }
        app = AppModel(instanceLock: try AppInstanceLock(directory: path), directory: path, enableServices: false)
        try await settle { app?.audioMaintenance == false && app?.historyState.loading == false }
        guard app!.error.isEmpty else { throw OSprError.message("Private restart failed; no data printed") }
        XCTAssertTrue(app!.historyState.statistics.records == retained.count, "Restart duplicated or lost records")
        for value in retained {
            var expected = value
            if expected.id == chosen.id { expected.text = marker }
            let pending = try await app!.historyState.record(id: value.id)
            let saved = try XCTUnwrap(pending)
            XCTAssertTrue(try same(saved, expected), "Restart changed raw text, metadata, timing or edited text")
        }
        for (name, hash) in audio {
            XCTAssertTrue(Data(SHA256.hash(data: try Data(contentsOf: path.appendingPathComponent("Audio").appendingPathComponent(name)))) == hash, "Referenced audio bytes changed")
        }
        try await app!.prepareForTermination(); app = nil
        let result: [String: Any] = ["status": "passed-isolated-actual-legacy-archive-app-model-upgrade", "source_records": original.count,
            "retained_records": retained.count, "referenced_audio_files": audio.count, "configured_retention_days": config.retentionDays,
            "saving_enabled": config.saveHistory, "canonical_record_fields_preserved_before_edit": true, "record_order_preserved": true,
            "validated_configuration_preserved": true, "private_search_checked": searchChecked, "quit_barrier_edit_survives_restart": true,
            "raw_text_metadata_timing_audio_links_preserved_after_edit": true, "referenced_audio_bytes_preserved": true,
            "no_restart_duplicate_or_loss": true, "source_content_emitted": false,
            "boundary": "Actual existing legacy records/audio copied into a private isolated profile. Current AppModel startup, SQLite migration, search, edit/quit flush and restart run with native services disabled. Original files are not passed to AppModel. No GUI/native app launch, permissions, Keychain, microphone, playback, models, provider requests, original-profile upgrade or abrupt-crash/device acceptance."]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("component-result.json"))
    }
}
