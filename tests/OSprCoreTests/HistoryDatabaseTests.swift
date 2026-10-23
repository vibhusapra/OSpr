import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import OSprCore

final class HistoryDatabaseTests: XCTestCase {
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-index-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }
    private func record(_ text: String, raw: String? = nil) -> Transcript {
        Transcript(rawText: raw ?? text, text: text, model: "fixture", mode: .clean,
                   duration: 1, latencyMS: 12, segments: [Segment(start: 0, end: 1, text: raw ?? text)])
    }
    private func canonical(_ record: Transcript) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }
    private func writeLegacy(_ items: [Transcript], to directory: URL) throws {
        try LocalStore(directory: directory).write(items, name: "history.json")
    }
    private func sql(_ statement: String, at directory: URL) throws {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent(HistoryDatabase.fileName).path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, statement, nil, nil, nil), SQLITE_OK)
    }

    func testMigrationPreservesEveryFieldAndArchiveOrderAcrossRestart() throws {
        let path = try directory()
        var first = record("Edited Ω café 日本語", raw: "Original \"[source]\" /Users/example\\notes")
        first.date = Date(timeIntervalSinceReferenceDate: 123456.123456789)
        first.app = "Fixture editor"; first.source = "file"; first.warning = "Review labels"
        first.audioFile = first.id.uuidString + ".wav"
        first.words = [Segment(start: 0.125, end: 0.875, text: "Original", speaker: 2, overlapSpeakers: [1, 2])]
        first.notes = try MeetingNotes(source: first.rawText, excerpts: [NoteExcerpt(id: 0, text: first.rawText)], model: "fixture")
        var second = record("Second row")
        second.date = first.date.addingTimeInterval(100) // Array order, not clock order.
        try writeLegacy([first, second], to: path)
        do {
            let database = try HistoryDatabase(directory: path)
            XCTAssertEqual(try database.page().rows.map(\.id), [first.id, second.id])
            XCTAssertEqual(try canonical(XCTUnwrap(database.record(id: first.id))), try canonical(first))
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent("history.json").path))
            try database.verifyIntegrity()
        }
        let reopened = try HistoryDatabase(directory: path)
        XCTAssertEqual(try canonical(XCTUnwrap(reopened.record(id: first.id))), try canonical(first))
        XCTAssertEqual(try reopened.statistics().records, 2)
    }

    func testStreamingMigrationCrossesBuffersAndKeepsNestedEscapes() throws {
        let path = try directory()
        let sentence = String(repeating: "quote \" \\ [ ] { } Ω 🙂 日本語\n", count: 700)
        let records = (0..<12).map { record("\($0): " + sentence) }
        try writeLegacy(records, to: path)
        let database = try HistoryDatabase(directory: path)
        for original in records {
            XCTAssertEqual(try canonical(XCTUnwrap(database.record(id: original.id))), try canonical(original))
        }
        XCTAssertEqual(try database.statistics().records, records.count)
    }

    func testInvalidOrTrailingLegacyJSONNeverCommitsPartialMigration() throws {
        for suffix in [",]", "] trailing", ",", "", " {}]", ",null]"] {
            let path = try directory(), original = try canonical(record("Keep me"))
            let bytes = Data("[".utf8) + original + Data(suffix.utf8)
            let legacy = path.appendingPathComponent("history.json")
            try bytes.write(to: legacy)
            XCTAssertThrowsError(try HistoryDatabase(directory: path), suffix)
            XCTAssertEqual(try Data(contentsOf: legacy), bytes)
            let replacement = [record("Recovered one"), record("Recovered two")]
            try writeLegacy(replacement, to: path)
            let database = try HistoryDatabase(directory: path)
            XCTAssertEqual(try database.page().rows.map(\.id), replacement.map(\.id))
            XCTAssertEqual(try database.statistics().records, 2)
        }
    }

    func testDuplicateIDsAndUnknownFutureFieldsPreserveOriginalArchive() throws {
        let item = record("Keep unknown data")
        for future in [false, true] {
            let path = try directory()
            if future {
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with: canonical(item)) as? [String: Any])
                json["futureImportantField"] = "preserve this"
                try JSONSerialization.data(withJSONObject: [json]).write(to: path.appendingPathComponent("history.json"))
            } else { try writeLegacy([item, item], to: path) }
            let bytes = try Data(contentsOf: path.appendingPathComponent("history.json"))
            XCTAssertThrowsError(try HistoryDatabase(directory: path))
            XCTAssertEqual(try Data(contentsOf: path.appendingPathComponent("history.json")), bytes)
        }
    }

    func testCommittedMigrationResumesRemovalWithoutDuplicatingOrResurrectingRows() throws {
        let path = try directory(), initial = [record("One"), record("Two")]
        try writeLegacy(initial, to: path)
        let legacy = try Data(contentsOf: path.appendingPathComponent("history.json"))
        do {
            let database = try HistoryDatabase(directory: path)
            try database.remove(ids: [initial[0].id])
        }
        // Simulate a crash after commit, before legacy-file removal.
        try legacy.write(to: path.appendingPathComponent("history.json"))
        let database = try HistoryDatabase(directory: path)
        XCTAssertEqual(try database.page().rows.map(\.id), [initial[1].id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent("history.json").path))
    }

    func testUnknownNestedFieldsNeverDisappearDuringMigration() throws {
        var original = record("Keep nested fields")
        original.words = [Segment(start: 0, end: 1, text: original.rawText)]
        original.notes = try MeetingNotes(source: original.rawText, excerpts: [NoteExcerpt(id: 0, text: original.rawText)], model: "fixture")
        for field in ["segments", "words", "notes", "excerpts"] {
            let path = try directory()
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: canonical(original)) as? [String: Any])
            if field == "segments" || field == "words" {
                var values = try XCTUnwrap(json[field] as? [[String: Any]])
                values[0]["futureConfidence"] = 0.75; json[field] = values
            } else {
                var notes = try XCTUnwrap(json["notes"] as? [String: Any])
                if field == "notes" { notes["futureSummary"] = "Keep this" }
                else {
                    var excerpts = try XCTUnwrap(notes["excerpts"] as? [[String: Any]])
                    excerpts[0]["futureSourceOffset"] = 17; notes["excerpts"] = excerpts
                }
                json["notes"] = notes
            }
            let bytes = try JSONSerialization.data(withJSONObject: [json])
            let legacy = path.appendingPathComponent("history.json")
            try bytes.write(to: legacy)
            XCTAssertThrowsError(try HistoryDatabase(directory: path), field)
            XCTAssertEqual(try Data(contentsOf: legacy), bytes, field)
            // The failed migration remains retryable with a supported archive.
            try writeLegacy([original], to: path)
            let recovered = try HistoryDatabase(directory: path)
            XCTAssertEqual(try canonical(XCTUnwrap(recovered.record(id: original.id))), try canonical(original))
        }
    }

    func testIndependentlyChangedLegacyArchiveIsNeverDeleted() throws {
        let path = try directory()
        do { _ = try HistoryDatabase(directory: path) }
        let legacy = path.appendingPathComponent("history.json")
        let data = Data("[]".utf8)
        try data.write(to: legacy)
        XCTAssertThrowsError(try HistoryDatabase(directory: path))
        XCTAssertEqual(try Data(contentsOf: legacy), data)
    }

    func testKeysetPaginationStaysStableAfterNewInsertAndEdit() throws {
        let path = try directory(), initial = (0..<13).map { record("Row \($0)") }
        try writeLegacy(initial, to: path)
        let database = try HistoryDatabase(directory: path)
        let first = try database.page(limit: 5)
        XCTAssertEqual(first.rows.map(\.id), Array(initial.prefix(5)).map(\.id))
        var edited = initial[8]; edited.text = "Changed without moving"
        let fresh = record("Fresh row")
        try database.upsert([edited, fresh])
        let second = try database.page(before: first.next, limit: 5)
        let third = try database.page(before: second.next, limit: 5)
        XCTAssertEqual((first.rows + second.rows + third.rows).map(\.id), initial.map(\.id))
        XCTAssertNil(third.next)
        XCTAssertEqual(try database.page().rows.first?.id, fresh.id)
        XCTAssertEqual(try database.page(limit: 10_000).rows.count, 14)
    }

    func testSearchTreatsOperatorsQuotesAndPunctuationAsLiteralSubstrings() throws {
        let path = try directory(), database = try HistoryDatabase(directory: path)
        let a = record("Keep C++ and 100% /Users/example", raw: "Original [braces] \"quote\" OR NOT value")
        let b = record("Different result")
        try database.upsert([a, b])
        for query in ["C++", "++", "%", "/Users/", "[braces]", "\"quote\"", "OR NOT", "NOT value", "Original"] {
            XCTAssertEqual(try database.page(query: query).rows.map(\.id), [a.id], query)
        }
        for query in ["*", "'; DROP TABLE history; --", "OR", "\" OR \""] {
            let expected = [b, a].filter { $0.text.localizedCaseInsensitiveContains(query) || $0.rawText.localizedCaseInsensitiveContains(query) }.map(\.id)
            XCTAssertEqual(try database.page(query: query).rows.map(\.id), expected, query)
        }
        try database.verifyIntegrity()
    }

    func testUnicodeCaseFoldCanonicalEquivalenceAndShortQueries() throws {
        let database = try HistoryDatabase(directory: directory())
        let original = record("Straße CAFÉ Ωμέγα 日本語 🙂 alpha\0omega")
        try database.upsert([original])
        for query in ["STRASSE", "cafe\u{301}", "ωΜΈ", "日本語", "日本", "🙂", "Ω", "\0", "alpha\0omega"] {
            XCTAssertEqual(try database.page(query: query).rows.map(\.id), [original.id], query)
        }
        XCTAssertTrue(try database.page(query: "cafe").rows.isEmpty) // No accent stripping.
        XCTAssertEqual(try XCTUnwrap(database.record(id: original.id)).text, original.text)
    }

    func testSummaryPageDoesNotDecodePayloadAndDetailErrorIsIsolated() throws {
        let path = try directory(), database = try HistoryDatabase(directory: path)
        let original = record(String(repeating: "large ", count: 300))
        try database.upsert([original])
        try sql("UPDATE history SET payload=x'00'", at: path)
        let row = try XCTUnwrap(database.page().rows.first)
        XCTAssertEqual(row.preview, String(original.text.prefix(480)))
        XCTAssertThrowsError(try database.record(id: original.id))
        XCTAssertEqual(try database.statistics().records, 1)
    }

    func testEditDeleteAndRetentionUpdateSearchStatisticsAndAudioReferences() throws {
        let database = try HistoryDatabase(directory: directory())
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var expired = record("expired sentinel"), boundary = record("boundary keep"), recent = record("new version")
        expired.date = now.addingTimeInterval(-31 * 86400); expired.audioFile = "old.wav"
        boundary.date = now.addingTimeInterval(-30 * 86400); boundary.audioFile = "boundary.wav"
        recent.date = now; recent.audioFile = "recent.wav"
        try database.upsert([expired, boundary, recent])
        XCTAssertEqual(try database.statistics(), HistoryStatistics(records: 3, words: 6))
        XCTAssertEqual(try database.prune(days: 30, now: now), ["old.wav"])
        XCTAssertTrue(try database.page(query: "expired").rows.isEmpty)
        recent.text = "edited five words right here"
        try database.upsert([recent])
        XCTAssertEqual(try database.statistics(), HistoryStatistics(records: 2, words: 7))
        XCTAssertEqual(try database.stripAudio(names: ["recent.wav"]), ["recent.wav"])
        XCTAssertNil(try database.record(id: recent.id)?.audioFile)
        XCTAssertEqual(try database.audioFiles(), ["boundary.wav"])
        XCTAssertEqual(try database.remove(ids: [boundary.id]), ["boundary.wav"])
        XCTAssertEqual(try database.statistics(), HistoryStatistics(records: 1, words: 5))
        XCTAssertTrue(try database.page(query: "boundary").rows.isEmpty)
        try database.verifyIntegrity()
    }

    func testFailedMultiRecordWriteRollsBackPayloadStatsAndSearch() throws {
        let database = try HistoryDatabase(directory: directory())
        let original = record("original sentinel")
        try database.upsert([original])
        var edited = original; edited.text = "uncommitted changed text"
        var invalid = record("invalid sentinel"); invalid.duration = .infinity
        XCTAssertThrowsError(try database.upsert([edited, invalid]))
        XCTAssertEqual(try database.record(id: original.id)?.text, original.text)
        XCTAssertEqual(try database.statistics(), HistoryStatistics(records: 1, words: 2))
        XCTAssertTrue(try database.page(query: "uncommitted").rows.isEmpty)
        XCTAssertEqual(try database.page(query: "original").rows.map(\.id), [original.id])
        try database.verifyIntegrity()
    }

    func testLegacyIntegrityMergeStillRejectsDivergentSearchContent() throws {
        let path = try directory(), database = try HistoryDatabase(directory: path)
        let original = record("Known content")
        try database.upsert([original])
        try database.verifyIntegrity(mergingForLegacyRuntime: true)
        // Remove only its index entry, retaining the actual payload/content.
        try sql("INSERT INTO history_search(history_search,rowid,text,raw) SELECT 'delete',position,text,raw FROM history", at: path)
        XCTAssertThrowsError(try database.verifyIntegrity(mergingForLegacyRuntime: true))
        XCTAssertEqual(try database.record(id: original.id)?.text, original.text)
    }

    func testBulkClearRollsBackTriggerContentAndIndexWhenLaterBatchEncodingFails() throws {
        let path = try directory(), database = try HistoryDatabase(directory: path)
        let original = record("Original before bulk clear")
        try database.upsert([original])
        let hash = try database.contentFingerprint()
        var invalid = record("Bad new row"); invalid.duration = .nan
        XCTAssertThrowsError(try database.apply(upserts: [invalid], clear: true))
        XCTAssertEqual(try database.contentFingerprint(), hash)
        XCTAssertEqual(try database.page(query: "Original").rows.map(\.id), [original.id])
        // A subsequent individual delete must still maintain counts and FTS.
        try database.remove(ids: [original.id])
        XCTAssertEqual(try database.statistics(), HistoryStatistics(records: 0, words: 0))
        XCTAssertTrue(try database.page(query: "Original").rows.isEmpty)
        try database.verifyIntegrity()
    }

    func testBulkClearRestoresDeleteMaintenanceBeforeNewRowsArrive() throws {
        let database = try HistoryDatabase(directory: directory())
        let original = record("Old archive"), fresh = record("Fresh after clear")
        try database.upsert([original])
        try database.apply(upserts: [fresh], clear: true)
        XCTAssertEqual(try database.statistics(), HistoryStatistics(records: 1, words: 3))
        XCTAssertTrue(try database.page(query: "Old archive").rows.isEmpty)
        XCTAssertEqual(try database.page(query: "Fresh").rows.map(\.id), [fresh.id])
        try database.remove(ids: [fresh.id])
        XCTAssertEqual(try database.statistics().records, 0)
        XCTAssertTrue(try database.page(query: "Fresh").rows.isEmpty)
        try database.verifyIntegrity()
    }

    func testClearRemovesSavedTextSearchStatsAndAudioLinks() throws {
        let path = try directory(), database = try HistoryDatabase(directory: path)
        let sentinel = "ZXQ_ONLY_PRIVATE_PAYLOAD_9281463720"
        var item = record(sentinel); item.audioFile = "record.wav"
        try database.upsert([item])
        XCTAssertEqual(try database.clear(), ["record.wav"])
        XCTAssertEqual(try database.statistics(), HistoryStatistics(records: 0, words: 0))
        XCTAssertTrue(try database.page().rows.isEmpty)
        XCTAssertTrue(try database.page(query: sentinel).rows.isEmpty)
        XCTAssertTrue(try database.audioFiles().isEmpty)
        let bytes = try Data(contentsOf: path.appendingPathComponent(HistoryDatabase.fileName))
        XCTAssertNil(bytes.range(of: Data(sentinel.utf8)))
        try database.verifyIntegrity()
    }

    func testPrivatePermissionsAndCorruptOrSymlinkFilesArePreserved() throws {
        let path = try directory()
        do { _ = try HistoryDatabase(directory: path) }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path.appendingPathComponent(HistoryDatabase.fileName).path)[.posixPermissions] as? Int, 0o600)
        let broken = try directory(), bytes = Data("not an sqlite database; keep this".utf8)
        let file = broken.appendingPathComponent(HistoryDatabase.fileName)
        try bytes.write(to: file)
        XCTAssertThrowsError(try HistoryDatabase(directory: broken))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let linked = try directory()
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent(HistoryDatabase.fileName), withDestinationURL: file)
        XCTAssertThrowsError(try HistoryDatabase(directory: linked))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testDeletionNeverSchedulesAudioStillReferencedByAnotherRecord() throws {
        let database = try HistoryDatabase(directory: directory())
        var first = record("First"), second = record("Second")
        first.audioFile = "shared.wav"; second.audioFile = "shared.wav"
        try database.upsert([first, second])
        XCTAssertTrue(try database.remove(ids: [first.id]).isEmpty)
        XCTAssertEqual(try database.audioFiles(), ["shared.wav"])
        XCTAssertEqual(try database.remove(ids: [second.id]), ["shared.wav"])
        first.date = Date(timeIntervalSinceReferenceDate: 1)
        second.date = Date()
        try database.upsert([first, second])
        XCTAssertTrue(try database.prune(days: 30).isEmpty)
        XCTAssertEqual(try database.audioFiles(), ["shared.wav"])
    }

    func testNewerSchemaVersionIsPreservedWithoutAttemptingMigration() throws {
        let path = try directory()
        try sql("PRAGMA user_version=99; CREATE TABLE future_data(value TEXT); INSERT INTO future_data VALUES('keep me');", at: path)
        let file = path.appendingPathComponent(HistoryDatabase.fileName)
        let bytes = try Data(contentsOf: file)
        XCTAssertThrowsError(try HistoryDatabase(directory: path))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testLegacySymlinksNeverReadOrRemoveTheirTargets() throws {
        for dangling in [false, true] {
            let path = try directory(), outside = try directory()
            let target = outside.appendingPathComponent("history.json")
            if !dangling { try writeLegacy([record("Outside archive")], to: outside) }
            let bytes = try? Data(contentsOf: target)
            let link = path.appendingPathComponent("history.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            XCTAssertThrowsError(try HistoryDatabase(directory: path))
            XCTAssertEqual(try? Data(contentsOf: target), bytes)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        }
    }

    func testLegacyWriteDuringCommitIsPreservedAlongsideCommittedDatabase() throws {
        let path = try directory(), original = record("Original source"), changed = record("New external version")
        try writeLegacy([original], to: path)
        XCTAssertThrowsError(try HistoryDatabase(directory: path, afterMigrationCommit: {
            try self.writeLegacy([changed], to: path)
        }))
        let preserved = try XCTUnwrap(LocalStore(directory: path).read([Transcript].self, name: "history.json"))
        XCTAssertEqual(preserved.map(\.id), [changed.id])
        let backup = path.appendingPathComponent("preserved-external.json")
        try FileManager.default.moveItem(at: path.appendingPathComponent("history.json"), to: backup)
        let committed = try HistoryDatabase(directory: path)
        XCTAssertEqual(try committed.page().rows.map(\.id), [original.id])
        XCTAssertEqual(try canonical(XCTUnwrap(committed.record(id: original.id))), try canonical(original))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testPreviewIsBoundedEvenForOneHugeCombiningGrapheme() throws {
        let database = try HistoryDatabase(directory: directory())
        let original = record("a" + String(repeating: "\u{301}", count: 20_000))
        try database.upsert([original])
        let row = try XCTUnwrap(database.page().rows.first)
        XCTAssertLessThanOrEqual(row.preview.unicodeScalars.count, 480)
        XCTAssertLessThanOrEqual(row.preview.utf8.count, 480 * 4)
        XCTAssertEqual(try database.record(id: original.id)?.text, original.text)
    }
}
