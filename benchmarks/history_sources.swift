// Headless storage control; link with current OSprCore objects. No inference.
// `fixture DIRECTORY COUNT` writes a public JSON archive, without opening SQLite.
// Run a retained pre-schema-5 reader on it, then `verify DIRECTORY` on this build.
import CryptoKit
import Foundation
import OSprCore
import SQLite3

@main struct HistorySourcesProbe {
    struct Snapshot: Equatable {
        let fingerprint: String
        let records: Int64
        let words: Int64
        let version: Int64
    }
    static func snapshot(_ directory: URL) throws -> Snapshot {
        var db: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent(HistoryDatabase.fileName).path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw OSprError.message("Expected an existing disposable SQLite archive.")
        }
        defer { sqlite3_close(db) }
        func number(_ sql: String) throws -> Int64 {
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK else { throw OSprError.message("Cannot inspect fixture metadata.") }
            defer { sqlite3_finalize(query) }
            guard sqlite3_step(query) == SQLITE_ROW else { throw OSprError.message("Missing fixture metadata.") }
            return sqlite3_column_int64(query, 0)
        }
        guard sqlite3_prepare_v2(db, "SELECT payload FROM history ORDER BY position DESC", -1, &statement, nil) == SQLITE_OK else {
            throw OSprError.message("Cannot inspect fixture payloads.")
        }
        defer { sqlite3_finalize(statement) }
        var hash = SHA256()
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw OSprError.message("Fixture payload read failed.") }
            let count = Int(sqlite3_column_bytes(statement, 0)); var size = UInt64(count).bigEndian
            withUnsafeBytes(of: &size) { hash.update(bufferPointer: $0) }
            hash.update(bufferPointer: UnsafeRawBufferPointer(start: bytes, count: count))
        }
        return try Snapshot(fingerprint: hash.finalize().map { String(format: "%02x", $0) }.joined(),
            records: number("SELECT records FROM history_stats"), words: number("SELECT words FROM history_stats"), version: number("PRAGMA user_version"))
    }
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3, ["fixture", "verify"].contains(args[1]) else {
            throw OSprError.message("Usage: history-sources fixture DIRECTORY COUNT | verify DIRECTORY")
        }
        let directory = URL(fileURLWithPath: args[2])
        if args[1] == "fixture" {
            guard args.count == 4, let count = Int(args[3]), (1...100_000).contains(count),
                  !FileManager.default.fileExists(atPath: directory.path) else { throw OSprError.message("Use a fresh disposable directory and count from 1 to 100000.") }
            let records = (0..<count).map { n in
                Transcript(rawText: "Shared public speech \(n)", text: "Shared public speech \(n)", model: "fixture", mode: .verbatim,
                    duration: 1, latencyMS: 2, segments: [.init(start: 0, end: 1, text: "Shared public speech \(n)")],
                    source: "/unindexed-parent/FILENAME_ONLY_SENTINEL-Café-\(n).wav")
            }
            try LocalStore(directory: directory).write(records, name: "history.json")
            print("Public JSON fixture created: \(count) records.")
            return
        }
        guard args.count == 3 else { throw OSprError.message("Expected one disposable directory.") }
        let before = try snapshot(directory), started = Date()
        let db = try HistoryDatabase(directory: directory)
        let openMS = Date().timeIntervalSince(started) * 1000
        try db.verifyIntegrity()
        let after = try snapshot(directory)
        guard before.fingerprint == after.fingerprint, before.records == after.records, before.words == after.words, after.version == 5 else {
            throw OSprError.message("Migration did not preserve payloads, order and statistics.")
        }
        var cursor: Int64?, count = 0
        repeat {
            let page = try db.page(before: cursor, limit: 37)
            for row in page.rows {
                guard let record = try db.record(id: row.id), row.sourceName == record.sourceFilename else { throw OSprError.message("A source label differs from its payload.") }
                count += 1
            }
            cursor = page.next
        } while cursor != nil
        guard count == Int(before.records) else { throw OSprError.message("Pagination lost records.") }
        let queryStarted = Date(), hits = try db.page(query: "filename_only_sentinel", limit: 37)
        let queryMS = Date().timeIntervalSince(queryStarted) * 1000
        guard try db.page(query: "unindexed-parent").rows.isEmpty else { throw OSprError.message("A parent path entered filename search.") }
        let memory = try db.memoryCopy()
        guard try memory.contentFingerprint() == after.fingerprint else { throw OSprError.message("Memory copy differs.") }
        let receipt: [String: Any] = ["status": "passed", "schema_before": before.version, "schema_after": after.version,
            "records": count, "words": after.words, "payload_bytes_and_order_preserved": true, "source_labels_verified": count,
            "memory_snapshot_preserved": true, "parent_path_query_empty": true, "filename_first_page_count": hits.rows.count,
            "open_wall_ms": openMS, "filename_first_page_wall_ms": queryMS,
            "timing_boundary": "One nonisolated storage observation, not a latency distribution or ASR timing."]
        print(String(decoding: try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted]), as: UTF8.self))
    }
}
