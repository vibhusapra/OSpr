import Foundation
import SQLite3
import XCTest
@testable import OSprCore

final class EditedSummarySourceTests: XCTestCase {
    private let original = "Ship Friday. The price is $15.50."
    private let edited = "Do not ship Friday. The price is $12.50."
    private func record() -> Transcript {
        .init(rawText: original, text: edited, model: "fixture", mode: .clean, duration: 2, latencyMS: 3,
              words: [.init(start: 0, end: 1, text: original, speaker: 1)])
    }
    private func summary(_ source: String, kind: SummarySource = .edited) throws -> MeetingSummary {
        try MeetingSummary(source: source, items: [.init(section: .overview, text: "Release plan.", sourceIDs: [0])],
            excerpts: [.init(id: 0, text: source)], model: "fixture", chunks: 1, sourceKind: kind)
    }
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-edited-summary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }; return path
    }
    private func version(_ path: URL) throws -> Int32 {
        var db: OpaquePointer?, query: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path.appendingPathComponent(HistoryDatabase.fileName).path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_finalize(query); sqlite3_close(db) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &query, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
        return sqlite3_column_int(query, 0)
    }

    func testOriginalEncodingRemainsLegacyAndDefaultsToOriginalOnDecode() throws {
        let value = try summary(original, kind: .original)
        let data = try JSONEncoder().encode(value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["items", "excerpts", "sourceSHA256", "model", "chunks", "created"])
        let decoded = try JSONDecoder().decode(MeetingSummary.self, from: data)
        XCTAssertEqual(decoded.sourceKind, .original); XCTAssertNil(decoded.sourceSnapshot)
        XCTAssertTrue(decoded.validatesStoredSource(for: record()))
        XCTAssertTrue(decoded.markdown.contains("Source: Original transcript"))
    }

    func testEditedSourceRoundTripRetainsSnapshotAndStaleNotesStayValid() throws {
        let value = try summary(edited)
        let decoded = try JSONDecoder().decode(MeetingSummary.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded.sourceKind, .edited); XCTAssertEqual(decoded.sourceSnapshot, edited)
        XCTAssertTrue(decoded.matches(edited)); XCTAssertFalse(decoded.matches(original))
        var item = record()
        XCTAssertTrue(decoded.sourceIsCurrent(in: item))
        item.text = "A later correction."
        XCTAssertFalse(decoded.sourceIsCurrent(in: item)); XCTAssertTrue(decoded.validatesStoredSource(for: item))
        XCTAssertEqual(decoded.excerpts.first?.text, edited)
        XCTAssertTrue(decoded.markdown.contains("Later transcript edits do not update"))
        XCTAssertTrue(decoded.markdown.contains(decoded.sourceSHA256))
    }

    func testSnapshotAndFreshnessUseLiteralUnicodeBytes() throws {
        let composed = "Ask Zoë about the release."
        let decomposed = composed.replacingOccurrences(of: "ë", with: "e\u{308}")
        XCTAssertEqual(composed, decomposed)
        let value = try summary(composed)
        var item = record(); item.text = decomposed
        XCTAssertFalse(value.matches(decomposed)); XCTAssertFalse(value.sourceIsCurrent(in: item))
        let decoded = try JSONDecoder().decode(MeetingSummary.self, from: JSONEncoder().encode(value))
        XCTAssertTrue(try XCTUnwrap(decoded.sourceSnapshot).utf8.elementsEqual(composed.utf8))
        XCTAssertTrue(decoded.matches(composed))
    }

    func testMalformedSnapshotMetadataCannotSilentlyBecomeOriginal() throws {
        let encoded = try JSONEncoder().encode(summary(edited))
        for change in ["missing", "null", "changed", "unknown-kind", "null-kind", "original-with-snapshot"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            switch change {
            case "missing": object.removeValue(forKey: "sourceSnapshot")
            case "null": object["sourceSnapshot"] = NSNull()
            case "changed": object["sourceSnapshot"] = "PRIVATE changed source."
            case "unknown-kind": object["sourceKind"] = "future-source"
            case "null-kind": object["sourceKind"] = NSNull()
            default: object["sourceKind"] = "original"
            }
            XCTAssertThrowsError(try JSONDecoder().decode(MeetingSummary.self, from: JSONSerialization.data(withJSONObject: object)), change)
        }
    }

    func testWorkerCannotOverrideHostSelectedProvenance() throws {
        let response: [String: Any] = ["items": [["section": "decisions", "text": "Hold the Friday release.", "source_ids": [0]]],
            "excerpts": [["id": 0, "text": edited]], "model": "fixture", "chunks": 1,
            "sourceKind": "original", "sourceSnapshot": "PRIVATE forged metadata"]
        let value = try MeetingSummary.fromWorker(response, source: edited, sourceKind: .edited)
        XCTAssertEqual(value.sourceKind, .edited); XCTAssertEqual(value.sourceSnapshot, edited)
        XCTAssertFalse(value.markdown.contains("PRIVATE"))
        var invalid = value; invalid.items[0].text = "The price is $99.00."
        XCTAssertFalse(invalid.validatesStoredSource(for: record()))
    }

    func testEditedSourcePersistsAcrossEditsRestartAndKeepsWriterFence() throws {
        let path = try directory()
        var item = record()
        item.notes = try MeetingNotes(source: original, excerpts: [.init(id: 0, text: original)], model: "extractive")
        item.summary = try summary(edited)
        do {
            let db = try HistoryDatabase(directory: path)
            XCTAssertEqual(try version(path), 2)
            try db.upsert([item]); XCTAssertEqual(try version(path), 4)
            item.text = "Later edited text."
            try db.upsert([item]); try db.verifyIntegrity()
        }
        let db = try HistoryDatabase(directory: path), saved = try XCTUnwrap(db.record(id: item.id))
        XCTAssertEqual(saved.rawText, original); XCTAssertEqual(saved.text, item.text)
        XCTAssertEqual(saved.summary?.sourceSnapshot, edited)
        XCTAssertEqual(saved.notes?.model, "extractive"); XCTAssertEqual(saved.words, item.words)
        XCTAssertFalse(try XCTUnwrap(saved.summary).sourceIsCurrent(in: saved))
        var removed = saved; removed.summary = nil; try db.upsert([removed])
        XCTAssertEqual(try version(path), 4)
        try db.clear(); XCTAssertEqual(try version(path), 4)
    }

    func testFailedSnapshotBatchRollsBackDataAndVersionFromBothOlderFormats() throws {
        for initialVersion in [2, 3] {
            let path = try directory(), db = try HistoryDatabase(directory: path)
            var prior = record()
            if initialVersion == 3 { prior.summary = try summary(original, kind: .original) }
            try db.upsert([prior]); XCTAssertEqual(try version(path), Int32(initialVersion))
            let before = try db.contentFingerprint()
            var good = prior; good.summary = try summary(edited)
            var bad = record(); bad.rawText = "Other source."
            bad.summary = try summary(original, kind: .original)
            XCTAssertThrowsError(try db.upsert([good, bad]))
            XCTAssertEqual(try version(path), Int32(initialVersion))
            XCTAssertEqual(try db.contentFingerprint(), before)
        }
    }

    func testLegacyJSONMigrationAndSessionTransferPreserveStaleSnapshot() throws {
        var item = record(); item.summary = try summary(edited); item.text = "Later edit."
        let path = try directory(), originalBytes = try JSONEncoder().encode([item])
        try originalBytes.write(to: path.appendingPathComponent("history.json"))
        let disk = try HistoryDatabase(directory: path)
        XCTAssertEqual(try version(path), 4)
        XCTAssertEqual(try disk.record(id: item.id)?.summary?.sourceSnapshot, edited)
        let memory = try HistoryDatabase.inMemory(); try disk.copyContents(to: memory)
        let snapshot = try memory.memoryCopy(); try memory.clear()
        let transferredPath = try directory(), transferred = try HistoryDatabase(directory: transferredPath)
        try snapshot.copyContents(to: transferred)
        let saved = try XCTUnwrap(transferred.record(id: item.id))
        XCTAssertEqual(saved.text, item.text); XCTAssertEqual(saved.summary?.sourceSnapshot, edited)
        XCTAssertFalse(try XCTUnwrap(saved.summary).sourceIsCurrent(in: saved))
        XCTAssertEqual(try version(transferredPath), 4)
    }

    func testUnknownSourceAndSnapshotFieldsPreserveLegacyArchiveIntact() throws {
        var item = record(); item.summary = try summary(edited)
        for field in ["sourceKind", "futureSnapshotField"] {
            let path = try directory()
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
            var value = try XCTUnwrap(object["summary"] as? [String: Any])
            value[field] = "future-source"; object["summary"] = value
            let bytes = try JSONSerialization.data(withJSONObject: [object])
            let legacy = path.appendingPathComponent("history.json"); try bytes.write(to: legacy)
            XCTAssertThrowsError(try HistoryDatabase(directory: path))
            XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        }
    }

    func testRepositoryRequiresCapturedEditedTextAndRefusesLateCanonicalEdits() async throws {
        let path = try directory(), repository = HistoryRepository(directory: path)
        var item = record(); item.text = "Ask Zoë about the release."
        repository.submit(item); try await repository.flushAsync()
        let value = try summary(item.text)
        let uncaptured = expectation(description: "edited source requires captured field")
        repository.updateSummary(id: item.id, summary: value, expectedRawText: item.rawText) { result in
            XCTAssertNotNil(result.failure); uncaptured.fulfill()
        }
        await fulfillment(of: [uncaptured], timeout: 2)
        repository.updateSummary(id: item.id, summary: value, expectedRawText: item.rawText, expectedEditedText: item.text)
        try await repository.flushAsync()
        let accepted = try await repository.record(id: item.id)
        XCTAssertEqual(accepted?.summary?.sourceKind, .edited)
        let changed = item.text.replacingOccurrences(of: "ë", with: "e\u{308}")
        repository.updateText(id: item.id, text: changed, delay: 60)
        let stale = expectation(description: "canonical edit still changes exact source")
        repository.updateSummary(id: item.id, summary: value, expectedRawText: item.rawText, expectedEditedText: item.text) { result in
            XCTAssertNotNil(result.failure); stale.fulfill()
        }
        await fulfillment(of: [stale], timeout: 2); try await repository.flushAsync()
        let afterLoad = try await repository.record(id: item.id)
        let after = try XCTUnwrap(afterLoad)
        XCTAssertTrue(after.text.utf8.elementsEqual(changed.utf8))
        XCTAssertEqual(after.summary?.sourceSnapshot, item.text)
        XCTAssertFalse(try XCTUnwrap(after.summary).sourceIsCurrent(in: after))
    }

    func testRemoveSummaryPreservesOtherFieldsAndRefusesStaleRemoval() async throws {
        let path = try directory(), repository = HistoryRepository(directory: path)
        var item = record(); item.audioFile = "owned-fixture.wav"
        item.notes = try MeetingNotes(source: original, excerpts: [.init(id: 0, text: original)], model: "extractive")
        let first = try summary(edited)
        item.summary = first
        repository.submit(item); try await repository.flushAsync()
        var replacement = first; replacement.model = "replacement"
        repository.updateSummary(id: item.id, summary: replacement, expectedRawText: original, expectedEditedText: edited)
        try await repository.flushAsync()
        let rejected = expectation(description: "stale removal refuses newer summary")
        repository.clearSummary(id: item.id, expected: first) { result in
            XCTAssertNotNil(result.failure); rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 2)
        let stillSaved = try await repository.record(id: item.id)
        XCTAssertEqual(stillSaved?.summary, replacement)
        repository.updateText(id: item.id, text: "A later edit.", delay: 60)
        repository.clearSummary(id: item.id, expected: replacement)
        try await repository.flushAsync()
        let loaded = try await repository.record(id: item.id)
        let saved = try XCTUnwrap(loaded)
        XCTAssertNil(saved.summary); XCTAssertEqual(saved.text, "A later edit.")
        XCTAssertEqual(saved.rawText, original); XCTAssertEqual(saved.words, item.words)
        XCTAssertEqual(saved.notes?.excerpts, item.notes?.excerpts); XCTAssertEqual(saved.audioFile, item.audioFile)
        XCTAssertEqual(try version(path), 4)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        XCTAssertNil(object["summary"])
    }

    func testEditedSnapshotFollowsSessionOnlyAndExplicitPersistence() async throws {
        let path = try directory(), repository = HistoryRepository(directory: path, saveHistory: false)
        var item = record(); item.summary = try summary(edited)
        repository.submit(item); try await repository.flushAsync()
        let session = try await repository.record(id: item.id)
        XCTAssertEqual(session?.summary?.sourceSnapshot, edited)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent(HistoryDatabase.fileName).path))
        repository.setSaving(true)
        try await repository.flushAsync()
        XCTAssertEqual(try version(path), 4)
        repository.setSaving(false)
        try await repository.flushAsync()
        let retained = try await repository.record(id: item.id)
        XCTAssertEqual(retained?.summary?.sourceSnapshot, edited)
        let disk = try HistoryDatabase(directory: path)
        XCTAssertEqual(try disk.statistics().records, 0)
        repository.clearSummary(id: item.id, expected: try XCTUnwrap(item.summary))
        try await repository.flushAsync()
        let removed = try await repository.record(id: item.id)
        XCTAssertNil(removed?.summary); XCTAssertEqual(removed?.text, edited)
    }
}
