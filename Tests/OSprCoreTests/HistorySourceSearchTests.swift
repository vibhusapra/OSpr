import Foundation
import SQLite3
import XCTest
@testable import OSprCore

final class HistorySourceSearchTests: XCTestCase {
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-source-search-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }

    private func item(_ source: String, text: String = "Shared spoken words") -> Transcript {
        Transcript(rawText: text, text: text, model: "fixture", mode: .verbatim, duration: 1, latencyMS: 2,
                   segments: [Segment(start: 0, end: 1, text: text)], source: source)
    }

    private func sql(_ statement: String, at path: URL) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.appendingPathComponent(HistoryDatabase.fileName).path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let code = sqlite3_exec(db, statement, nil, nil, nil)
        XCTAssertEqual(code, SQLITE_OK, db.map { String(cString: sqlite3_errmsg($0)) } ?? "No database")
    }

    private func scalar(_ query: String, at path: URL) throws -> String {
        var db: OpaquePointer?, statement: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path.appendingPathComponent(HistoryDatabase.fileName).path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        XCTAssertEqual(sqlite3_prepare_v2(db, query, -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return String(cString: try XCTUnwrap(sqlite3_column_text(statement, 0)))
    }

    /// Install the actual pre-filename physical table and two-column FTS index.
    /// Seed secure-delete using the old normal triggers before closing SQLite.
    private func legacy(_ records: [Transcript], version: Int, at path: URL) throws -> String {
        let fingerprint: String
        do {
            let db = try HistoryDatabase(directory: path)
            try db.upsert(records); fingerprint = try db.contentFingerprint()
        }
        try sql("""
            DROP TRIGGER history_insert; DROP TRIGGER history_delete; DROP TRIGGER history_update;
            DROP TRIGGER history_search_before_update; DROP TRIGGER history_search_update;
            DROP TABLE history_search;
            ALTER TABLE history DROP COLUMN source_name; ALTER TABLE history DROP COLUMN source_search;
            CREATE VIRTUAL TABLE history_search USING fts5(text,raw,content='history',content_rowid='position',tokenize='trigram');
            INSERT INTO history_search(history_search,rank) VALUES('secure-delete',1);
            INSERT INTO history_search(rowid,text,raw) SELECT position,text,raw FROM history;
            CREATE TRIGGER history_insert AFTER INSERT ON history BEGIN
                INSERT INTO history_search(rowid,text,raw) VALUES(new.position,new.text,new.raw);
                UPDATE history_stats SET records=records+1,words=words+new.word_count WHERE singleton=1;
            END;
            CREATE TRIGGER history_delete BEFORE DELETE ON history BEGIN
                DELETE FROM history_search WHERE rowid=old.position;
                UPDATE history_stats SET records=records-1,words=words-old.word_count WHERE singleton=1;
            END;
            CREATE TRIGGER history_search_before_update BEFORE UPDATE OF text,raw ON history
            WHEN old.text IS NOT new.text OR old.raw IS NOT new.raw BEGIN
                DELETE FROM history_search WHERE rowid=old.position;
            END;
            CREATE TRIGGER history_search_update AFTER UPDATE OF text,raw ON history
            WHEN old.text IS NOT new.text OR old.raw IS NOT new.raw BEGIN
                INSERT INTO history_search(rowid,text,raw) VALUES(new.position,new.text,new.raw);
            END;
            CREATE TRIGGER history_update AFTER UPDATE OF word_count ON history
            WHEN old.word_count != new.word_count BEGIN
                UPDATE history_stats SET words=words-old.word_count+new.word_count WHERE singleton=1;
            END;
            INSERT INTO history(id,created,text,raw,preview,mode,model,app,duration,latency,audio,word_count,payload)
                VALUES('source-migration-test-probe',0,'format probe tokens','format probe tokens','','verbatim','','',0,0,NULL,0,x'00');
            DELETE FROM history WHERE id='source-migration-test-probe';
            PRAGMA user_version=\(version);
            """, at: path)
        return fingerprint
    }

    func testFilenameLiteralSearchUnicodeAndPathRedactionWithoutDecodingPayload() throws {
        let path = try directory(), db = try HistoryDatabase(directory: path)
        let filename = "Cafe\u{301} 日本語 C++ 100% [final] \"OR NOT\".wav"
        let record = item("/private-parent-never-index/" + filename)
        let other = item("C:\\different-parent\\other.wav")
        try db.upsert([record, other])
        // List and both search paths must work using lightweight metadata alone.
        try sql("UPDATE history SET payload=x'00'", at: path)
        for query in ["CAFÉ", "日本語", "日本", "C++", "++", "%", "[final]", "\"OR NOT\"", ".wav"] {
            let expected = query == ".wav" ? [other.id, record.id] : [record.id]
            XCTAssertEqual(try db.page(query: query).rows.map(\.id), expected, query)
        }
        XCTAssertEqual(try db.page(query: "CAFÉ").rows.first?.sourceName, filename)
        for query in ["private-parent", "different-parent", "cafe", "*", "\" OR \"", "\0"] {
            XCTAssertTrue(try db.page(query: query).rows.isEmpty, query)
        }
        XCTAssertThrowsError(try db.record(id: record.id))
        try db.verifyIntegrity()
    }

    func testNoGenericFilenameForMissingSourceAndNoCrossColumnPhraseMatch() throws {
        let db = try HistoryDatabase.inMemory()
        let empty = item(" \n\u{202e}"), whitespace = item(""), split = item("beta.wav", text: "alpha")
        try db.upsert([empty, whitespace, split])
        XCTAssertNil(try db.page().rows.first(where: { $0.id == empty.id })?.sourceName)
        XCTAssertTrue(try db.page(query: "Dictation").rows.isEmpty)
        XCTAssertTrue(try db.page(query: "alpha beta").rows.isEmpty)
        XCTAssertEqual(empty.sourceName, "Dictation")
        XCTAssertNil(empty.sourceFilename)
    }

    func testFilenameUpdatesDeleteRetentionAndClearMaintainIndexAndCounts() throws {
        let path = try directory(), db = try HistoryDatabase(directory: path)
        var row = item("old-name.wav"), expired = item("expired-source.wav")
        expired.date = Date(timeIntervalSinceReferenceDate: 0); expired.audioFile = "expired.wav"
        try db.upsert([row, expired]); let stats = try db.statistics()
        row.source = "NEW-name.wav"; try db.upsert([row])
        XCTAssertTrue(try db.page(query: "old-name").rows.isEmpty)
        XCTAssertEqual(try db.page(query: "new-name").rows.map(\.id), [row.id])
        row.source = "new-NAME.wav"; try db.upsert([row])
        XCTAssertEqual(try db.page(query: "NEW-NAME").rows.first?.sourceName, row.source)
        XCTAssertEqual(try db.statistics(), stats)
        XCTAssertEqual(try db.prune(days: 1), ["expired.wav"])
        XCTAssertTrue(try db.page(query: "expired-source").rows.isEmpty)
        try db.remove(ids: [row.id]); XCTAssertTrue(try db.page(query: "new-name").rows.isEmpty)
        try db.upsert([row]); try db.clear(); try db.upsert([item("fresh-name.wav")])
        XCTAssertTrue(try db.page(query: "new-name").rows.isEmpty)
        XCTAssertEqual(try db.page(query: "fresh-name").rows.count, 1)
        XCTAssertEqual(try db.statistics().records, 1); try db.verifyIntegrity()
        let observer = try HistoryDatabase(directory: path); try observer.verifyIntegrity()
    }

    func testFilenameKeysetPagesAndBulkExportQueryHaveTheSameMatches() throws {
        let db = try HistoryDatabase.inMemory()
        let records = (0..<241).map { item($0.isMultiple(of: 2) ? "series-\($0).wav" : "other-\($0).wav") }
        try db.upsert(records)
        let first = try db.page(query: "series-", limit: 37)
        let fresh = item("series-new.wav"); try db.upsert([fresh])
        var ids = first.rows.map(\.id), cursor = first.next
        while let position = cursor {
            let page = try db.page(query: "series-", before: position, limit: 37)
            ids += page.rows.map(\.id); cursor = page.next
        }
        XCTAssertEqual(ids, records.reversed().filter { $0.source.hasPrefix("series-") }.map(\.id))
        var exported: [UUID] = []
        try db.visitRecords(query: "series-") { exported.append($0.id) }
        XCTAssertEqual(exported, [fresh.id] + ids)
    }

    func testSchemaTwoThroughFourUpgradePreservesPayloadBytesOrderAndAudio() throws {
        for version in 2...4 {
            let path = try directory()
            var records = (0..<65).map { item("/not-indexed/episode-\($0).wav") }
            records[0].audioFile = "retained.wav"
            records[0].notes = try MeetingNotes(source: records[0].rawText,
                excerpts: [.init(id: 0, text: records[0].rawText)], model: "fixture")
            if version >= 3 {
                records[0].summary = try MeetingSummary(source: records[0].rawText,
                    items: [.init(section: .overview, text: "Shared spoken words", sourceIDs: [0])],
                    excerpts: [.init(id: 0, text: records[0].rawText)], model: "fixture", chunks: 1,
                    sourceKind: version == 4 ? .edited : .original)
            }
            let before = try legacy(records, version: version, at: path)
            let db = try HistoryDatabase(directory: path)
            XCTAssertEqual(try scalar("PRAGMA user_version", at: path), "5")
            XCTAssertEqual(try db.contentFingerprint(), before)
            XCTAssertEqual(try db.page().rows.map(\.id), records.reversed().map(\.id))
            XCTAssertEqual(try db.page(query: "episode-0").rows.map(\.id), [records[0].id])
            XCTAssertTrue(try db.page(query: "not-indexed").rows.isEmpty)
            XCTAssertEqual(try db.audioFiles(), ["retained.wav"])
            XCTAssertEqual(try db.statistics(), .init(records: 65, words: 195))
            try db.verifyIntegrity()
            let reopened = try HistoryDatabase(directory: path)
            XCTAssertEqual(try reopened.contentFingerprint(), before)
            XCTAssertEqual(try reopened.record(id: records[0].id)?.notes?.model, "fixture")
            XCTAssertEqual(try reopened.record(id: records[0].id)?.summary, records[0].summary)
        }
    }

    func testEmptyLegacyUpgradeAndFirstDeleteKeepSecureFormatCommitted() throws {
        let path = try directory(); _ = try legacy([], version: 4, at: path)
        let db = try HistoryDatabase(directory: path)
        XCTAssertEqual(try db.statistics().records, 0)
        XCTAssertEqual(try scalar("PRAGMA user_version", at: path), "5")
        XCTAssertGreaterThanOrEqual(Int(try scalar("SELECT v FROM history_search_config WHERE k='version'", at: path)) ?? 0, 5)
        let row = item("first.wav"); try db.upsert([row]); try db.remove(ids: [row.id])
        let observer = try HistoryDatabase(directory: path); try observer.verifyIntegrity()
    }

    func testFailedBackfillRollsBackSchemaAndPreservesAllExistingBytes() throws {
        let path = try directory(); _ = try legacy([item("keep.wav"), item("later.wav")], version: 4, at: path)
        try sql("UPDATE history SET payload=x'00' WHERE position=(SELECT max(position) FROM history)", at: path)
        let url = path.appendingPathComponent(HistoryDatabase.fileName), before = try Data(contentsOf: url)
        XCTAssertThrowsError(try HistoryDatabase(directory: path))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try scalar("PRAGMA user_version", at: path), "4")
        XCTAssertEqual(try scalar("SELECT count(*) FROM pragma_table_info('history') WHERE name='source_name'", at: path), "0")
    }

    func testSourceMigrationRefusesToHideDamagedOldFTS() throws {
        let path = try directory(); _ = try legacy([item("keep.wav")], version: 4, at: path)
        try sql("DELETE FROM history_search", at: path)
        let url = path.appendingPathComponent(HistoryDatabase.fileName), before = try Data(contentsOf: url)
        XCTAssertThrowsError(try HistoryDatabase(directory: path))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testFilenameFailureRollsBackClearAndAnEarlierRename() throws {
        let db = try HistoryDatabase.inMemory(); var row = item("original.wav"), invalid = item("broken.wav")
        try db.upsert([row]); row.source = "renamed.wav"; invalid.duration = .nan
        XCTAssertThrowsError(try db.apply(upserts: [row, invalid], clear: true))
        XCTAssertEqual(try db.page(query: "original.wav").rows.map(\.id), [row.id])
        XCTAssertTrue(try db.page(query: "renamed.wav").rows.isEmpty)
        try db.verifyIntegrity()
    }

    func testSourceFilenameBytesAreRemovedByDeleteAndClear() throws {
        let path = try directory(), db = try HistoryDatabase(directory: path)
        let sentinel = "ZXQ_FILENAME_ONLY_PRIVATE_SENTINEL_906432817"
        let row = item(sentinel + ".wav")
        for clear in [false, true] {
            try db.upsert([row])
            XCTAssertEqual(try db.page(query: sentinel).rows.count, 1)
            if clear { try db.clear() } else { try db.remove(ids: [row.id]) }
            XCTAssertTrue(try db.page(query: sentinel).rows.isEmpty)
            let bytes = try Data(contentsOf: path.appendingPathComponent(HistoryDatabase.fileName))
            XCTAssertNil(bytes.range(of: Data(sentinel.utf8)))
            XCTAssertNil(bytes.range(of: Data(sentinel.lowercased().utf8)))
            try db.verifyIntegrity()
        }
    }

    func testFilenameMetadataSurvivesMemorySnapshotAndDurableTransfer() throws {
        let path = try directory(), db = try HistoryDatabase.inMemory(), row = item("/private/Memory Café.wav")
        try db.upsert([row]); let copy = try db.memoryCopy()
        try db.clear()
        let target = try HistoryDatabase(directory: path); try copy.copyContents(to: target)
        XCTAssertEqual(try target.page(query: "cafe\u{301}").rows.first?.sourceName, "Memory Café.wav")
        XCTAssertEqual(try target.record(id: row.id)?.source, row.source)
        XCTAssertTrue(try target.page(query: "private").rows.isEmpty)
        try target.verifyIntegrity()
    }

    func testRepositoryFilenameExportIncludesPendingEditsAndSessionOnlyMatches() async throws {
        let root = try directory(), data = root.appendingPathComponent("data")
        let repository = HistoryRepository(directory: data, saveHistory: false)
        let records = (0..<205).map { item($0.isMultiple(of: 2) ? "match-\($0).wav" : "other-\($0).wav") }
        for record in records { repository.submit(record, delay: 60) }
        repository.updateText(id: records[0].id, text: "Pending last correction", delay: 60)
        let destination = root.appendingPathComponent("export")
        let result = try await repository.export(to: destination, format: .json, query: "MATCH-")
        XCTAssertEqual(result.count, 103)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(Transcript.self, from: Data(contentsOf: destination.appendingPathComponent(TranscriptExport.filename(records[0], format: .json))))
        XCTAssertEqual(saved.text, "Pending last correction"); XCTAssertEqual(saved.rawText, records[0].rawText)
        XCTAssertFalse(try HistoryDatabase.storageExists(directory: data))
        repository.setSaving(true); try await repository.flushAsync()
        repository.setSaving(false); try await repository.flushAsync()
        let matches = try await repository.page(query: "match-", limit: 200)
        XCTAssertEqual(matches.rows.count, 103)
        XCTAssertEqual(try HistoryDatabase(directory: data).statistics().records, 0)
    }
}
