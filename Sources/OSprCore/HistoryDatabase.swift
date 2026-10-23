import CryptoKit
import Darwin
import Foundation
import SQLite3

/// Lightweight list data. Detailed timing, original text and notes are decoded
/// only when a record is opened; a page never materializes Transcript payloads.
public struct HistoryRow: Identifiable, Sendable {
    public let id: UUID
    public let position: Int64
    public let date: Date
    public let preview: String
    public let mode: WritingMode
    public let model: String
    public let app: String
    public let duration: Double
    public let latencyMS: Double
    public let audioFile: String?
}

public struct HistoryPage: Sendable {
    public let rows: [HistoryRow]
    public let next: Int64?
}

public struct HistoryStatistics: Sendable, Equatable {
    public let records: Int
    public let words: Int
    public init(records: Int, words: Int) { self.records = records; self.words = words }
}

public enum HistoryAudioRemoval: Sendable {
    case all
    case names(Set<String>)
}

/// Thread-confined SQLite storage. The owner must serialize access and keep all
/// filesystem/query work off the UI executor. No live app uses this until the
/// asynchronous repository integration passes its own acceptance gates.
/// App-data migration also requires the existing AppInstanceLock; callers must
/// not race a separate GUI writer against migration/removal of history.json.
public final class HistoryDatabase {
    public static let fileName = "history.sqlite3"
    private var database: OpaquePointer?
    private let directory: URL
    private let afterMigrationCommit: () throws -> Void
    private let encoder: JSONEncoder = {
        let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]; return value
    }()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public convenience init(directory: URL) throws {
        try self.init(directory: directory, afterMigrationCommit: {})
    }

    /// A pure :memory: database, never an empty-name temporary disk database.
    /// `temp_store=MEMORY` also keeps SQLite's temporary SQL work off disk.
    public static func inMemory() throws -> HistoryDatabase { try HistoryDatabase(memoryPageSize: 4096) }

    // Optional nondefault VFS is used by the no-disk-IO regression probe.
    init(memoryPageSize: Int64, vfs: String? = nil) throws {
        directory = URL(fileURLWithPath: "/") // No file operations use this for an in-memory instance.
        afterMigrationCommit = {}
        guard sqlite3_libversion_number() >= 3_042_000, sqlite3_compileoption_used("TEMP_STORE=0") == 0 else {
            throw OSprError.message("This SQLite runtime cannot provide session-only history storage.")
        }
        // MEMORY is inherited by VACUUM's internal ATTACH as well. PRIVATECACHE
        // keeps this connection isolated even if another client enables sharing.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_MEMORY | SQLITE_OPEN_PRIVATECACHE
        let code = vfs.map { name in name.withCString { sqlite3_open_v2(":memory:", &database, flags, $0) } }
            ?? sqlite3_open_v2(":memory:", &database, flags, nil)
        guard code == SQLITE_OK else {
            throw OSprError.message("Cannot create session-only history storage.")
        }
        try execute("PRAGMA page_size=\(memoryPageSize); PRAGMA secure_delete=ON; PRAGMA temp_store=MEMORY; PRAGMA cache_size=-4096;")
        try createSchema()
        try setMetadata("ready", value: "1")
    }

    /// Snapshot all pages without materializing transcript arrays. SQLite's
    /// backup API holds the destination write transaction until completion.
    /// https://www.sqlite.org/backup.html
    public func memoryCopy() throws -> HistoryDatabase {
        let memory = try HistoryDatabase(memoryPageSize: integer("PRAGMA page_size"))
        try copyContents(to: memory)
        try memory.reclaimUnusedPages()
        return memory
    }

    /// Full clearing should release disk space, and a sparse disk archive should
    /// not retain its entire historical file size in a session snapshot. This
    /// maintenance runs after a data commit; callers retain cleanup receipts if
    /// it fails. Memory-store VACUUM never writes a transcript copy to disk.
    public func reclaimUnusedPages() throws {
        let free = try integer("PRAGMA freelist_count")
        guard free > 0 else { return }
        let empty = try integer("SELECT records FROM history_stats WHERE singleton=1") == 0
        let pages = try integer("PRAGMA page_count")
        if empty || (free > 1024 && free > pages / 4) { try execute("VACUUM") }
    }

    public func copyContents(to destination: HistoryDatabase) throws {
        guard self !== destination, let source = database, let target = destination.database,
              let backup = sqlite3_backup_init(target, "main", source, "main") else {
            throw OSprError.message("Cannot prepare history transfer. Both stores were preserved.")
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else {
            throw OSprError.message("History transfer failed (SQLite \(step)). Both stores were preserved; retry the storage preference.")
        }
    }

    /// Inspect without creating a disk store or following a dangling symlink.
    public static func storageExists(directory: URL) throws -> Bool {
        for name in [fileName, "history.json"] {
            var attributes = stat()
            if lstat(directory.appendingPathComponent(name).path, &attributes) == 0 { return true }
            if errno != ENOENT { throw OSprError.message("Cannot inspect saved history. Existing files were preserved.") }
        }
        return false
    }

    // Filesystem handoff boundary for interrupted/external-write regression tests.
    init(directory: URL, afterMigrationCommit: @escaping () throws -> Void) throws {
        self.afterMigrationCommit = afterMigrationCommit
        guard sqlite3_libversion_number() >= 3_042_000 else {
            throw OSprError.message("Indexed history requires SQLite 3.42 or newer. The original archive was preserved.")
        }
        _ = try LocalStore(directory: directory)
        // NOFOLLOW also rejects symlink ancestors such as macOS /var ->
        // /private/var. Foundation shortens that path back to /var on macOS,
        // so use POSIX realpath for the parent, never for the database itself.
        guard let resolved = Darwin.realpath(directory.path, nil) else {
            throw OSprError.message("Cannot resolve private history storage.")
        }
        let canonicalDirectory = URL(fileURLWithPath: String(cString: resolved))
        free(resolved)
        self.directory = canonicalDirectory
        let path = canonicalDirectory.appendingPathComponent(Self.fileName)
        // Precreate at 0600 so even the first transaction's rollback journal
        // inherits private permissions. Never follow a database symlink.
        let descriptor = Darwin.open(path.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if descriptor >= 0 { Darwin.close(descriptor) }
        else if errno != EEXIST { throw OSprError.message("Cannot create private history storage.") }
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw OSprError.message("History database must be a regular file.")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(path.path, &database, flags, nil) == SQLITE_OK else {
            throw OSprError.message("Cannot open history database. Existing files were preserved.")
        }
        sqlite3_busy_timeout(database, 2_000)
        let version = try integer("PRAGMA user_version")
        guard version == 0 || version == 1 else {
            throw OSprError.message("This history database needs a newer OSpr version. Existing files were preserved.")
        }
        try execute("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA secure_delete=ON; PRAGMA temp_store=MEMORY; PRAGMA cache_size=-4096;")
        if version == 0 { try createSchema() }
        try migrateLegacyIfNeeded()
    }

    deinit { close() }

    // Repository teardown closes on its queue before releasing the GUI lease.
    func close() { sqlite3_close(database); database = nil }

    private func createSchema() throws {
        try transaction {
            try execute("""
                CREATE TABLE history (
                    position INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE,
                    created REAL NOT NULL, text TEXT NOT NULL, raw TEXT NOT NULL,
                    preview TEXT NOT NULL, mode TEXT NOT NULL, model TEXT NOT NULL,
                    app TEXT NOT NULL, duration REAL NOT NULL, latency REAL NOT NULL,
                    audio TEXT, word_count INTEGER NOT NULL, payload BLOB NOT NULL
                );
                CREATE INDEX history_created ON history(created);
                CREATE INDEX history_audio ON history(audio) WHERE audio IS NOT NULL;
                CREATE TABLE history_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE history_stats (singleton INTEGER PRIMARY KEY CHECK(singleton=1), records INTEGER NOT NULL, words INTEGER NOT NULL);
                INSERT INTO history_stats VALUES(1,0,0);
                CREATE VIRTUAL TABLE history_search USING fts5(text,raw,content='history',content_rowid='position',tokenize='trigram');
                INSERT INTO history_search(history_search,rank) VALUES('secure-delete',1);
                CREATE TRIGGER history_insert AFTER INSERT ON history BEGIN
                    INSERT INTO history_search(rowid,text,raw) VALUES(new.position,new.text,new.raw);
                    UPDATE history_stats SET records=records+1,words=words+new.word_count WHERE singleton=1;
                END;
                CREATE TRIGGER history_delete AFTER DELETE ON history BEGIN
                    INSERT INTO history_search(history_search,rowid,text,raw) VALUES('delete',old.position,old.text,old.raw);
                    UPDATE history_stats SET records=records-1,words=words-old.word_count WHERE singleton=1;
                END;
                CREATE TRIGGER history_update AFTER UPDATE ON history BEGIN
                    INSERT INTO history_search(history_search,rowid,text,raw) VALUES('delete',old.position,old.text,old.raw);
                    INSERT INTO history_search(rowid,text,raw) VALUES(new.position,new.text,new.raw);
                    UPDATE history_stats SET words=words-old.word_count+new.word_count WHERE singleton=1;
                END;
                PRAGMA user_version=1;
                """)
        }
    }

    private func migrateLegacyIfNeeded() throws {
        let legacy = directory.appendingPathComponent("history.json")
        var attributes = stat()
        let exists: Bool
        if lstat(legacy.path, &attributes) == 0 {
            guard attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw OSprError.message("Legacy history must be a regular file. Existing files were preserved.")
            }
            exists = true
        } else if errno == ENOENT { exists = false }
        else { throw OSprError.message("Cannot inspect legacy history. Existing files were preserved.") }
        if try metadata("ready") == "1" {
            if exists {
                guard let expected = try metadata("legacy_sha256"), try fileDigest(legacy) == expected else {
                    throw OSprError.message("Legacy history changed after migration. Both stores were preserved; export or resolve the extra archive before continuing.")
                }
                try FileManager.default.removeItem(at: legacy)
            }
            return
        }
        var sourceDigest: String?
        try transaction {
            guard try integer("SELECT count(*) FROM history") == 0 else {
                throw OSprError.message("Incomplete history migration needs recovery. Existing files were preserved.")
            }
            var expected = SHA256(), count = 0
            if exists {
                let stream = try HistoryJSONStream(url: legacy)
                defer { stream.close() }
                while let data = try stream.next() {
                    try autoreleasepool {
                    try validateLegacyFields(JSONSerialization.jsonObject(with: data))
                    let record = try decoder.decode(Transcript.self, from: data)
                    let canonical = try encoder.encode(record)
                    // A source row must survive decoding its actual persisted
                    // representation, including all words, notes and audio links.
                    guard try encoder.encode(decoder.decode(Transcript.self, from: canonical)) == canonical else {
                        throw OSprError.message("History migration could not preserve a record.")
                    }
                    try put(record, position: -Int64(count), allowUpdate: false)
                    digest(canonical, into: &expected)
                    count += 1
                    }
                }
                sourceDigest = stream.sha256
                guard try fileDigest(legacy) == sourceDigest else {
                    throw OSprError.message("History changed during migration. Existing files were preserved.")
                }
            }
            var observed = SHA256(), observedCount = 0
            try rows("SELECT payload FROM history ORDER BY position DESC") { statement in
                digest(blob(statement, 0), into: &observed); observedCount += 1
            }
            guard count == observedCount && expected.finalize() == observed.finalize() else {
                throw OSprError.message("History migration verification failed. The original archive was preserved.")
            }
            if let sourceDigest { try setMetadata("legacy_sha256", value: sourceDigest) }
            try setMetadata("ready", value: "1")
        }
        // Commit precedes removal. An interrupted removal is recognized by its
        // exact source hash next launch; an independently edited archive is kept.
        if exists {
            try afterMigrationCommit()
            guard try fileDigest(legacy) == sourceDigest else {
                throw OSprError.message("Legacy history changed after migration. Both stores were preserved.")
            }
            try FileManager.default.removeItem(at: legacy)
        }
    }

    public func upsert(_ records: [Transcript]) throws {
        try transaction { for record in records { try put(record) } }
    }

    /// One commit for incremental edits, tombstones and complete-archive policy.
    /// A failed batch changes neither payloads, search, counts nor audio links.
    @discardableResult public func apply(upserts: [Transcript] = [], removing: [UUID] = [],
        clear: Bool = false, stripAudio: HistoryAudioRemoval? = nil,
        retentionDays: Int = 0, now: Date = Date()) throws -> Set<String> {
        var candidates: Set<String> = []
        try transaction {
            if clear {
                candidates.formUnion(try audioFiles())
                try execute("DELETE FROM history")
                try execute("INSERT INTO history_search(history_search) VALUES('rebuild')")
                try execute("DELETE FROM history_meta WHERE key='legacy_sha256'")
            }
            for id in removing {
                try rows("SELECT audio FROM history WHERE id=? AND audio IS NOT NULL", [.text(id.uuidString)]) { candidates.insert(text($0, 0)) }
                try execute("DELETE FROM history WHERE id=?", [.text(id.uuidString)])
            }
            for record in upserts {
                try rows("SELECT audio FROM history WHERE id=? AND audio IS NOT NULL", [.text(record.id.uuidString)]) { candidates.insert(text($0, 0)) }
                try put(record)
            }
            if let stripAudio {
                let names: Set<String>?
                switch stripAudio { case .all: names = nil; case .names(let value): names = value }
                candidates.formUnion(try stripAudioRows(names: names))
            }
            if retentionDays > 0 {
                let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400).timeIntervalSinceReferenceDate
                try rows("SELECT audio FROM history WHERE created<? AND audio IS NOT NULL", [.real(cutoff)]) { candidates.insert(text($0, 0)) }
                try execute("DELETE FROM history WHERE created<?", [.real(cutoff)])
            }
            candidates = try orphanedAudio(candidates)
        }
        return candidates
    }

    /// Only an explicit Delete all history request may reset unreadable storage.
    /// The GUI owner must hold AppInstanceLock and release its connection first.
    public static func reset(directory: URL) throws -> HistoryDatabase {
        _ = try LocalStore(directory: directory)
        let files = [fileName, fileName + "-journal", fileName + "-wal", fileName + "-shm", "history.json"].map { directory.appendingPathComponent($0) }
        for file in files {
            var attributes = stat()
            if lstat(file.path, &attributes) == 0 {
                guard attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                    throw OSprError.message("History reset requires regular files. Existing files were preserved.")
                }
            } else if errno != ENOENT { throw OSprError.message("Cannot inspect history for reset. Existing files were preserved.") }
        }
        for file in files where FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        return try HistoryDatabase(directory: directory)
    }

    /// JSONDecoder intentionally ignores unknown keys, including nested ones.
    /// Migration must instead preserve archives made by a newer writer intact.
    private func validateLegacyFields(_ value: Any) throws {
        func object(_ value: Any, keys: Set<String>) throws -> [String: Any] {
            guard let dictionary = value as? [String: Any], Set(dictionary.keys).isSubset(of: keys) else {
                throw OSprError.message("Legacy history has unknown fields. Existing files were preserved.")
            }
            return dictionary
        }
        let record = try object(value, keys: ["id", "date", "rawText", "text", "model", "mode", "app", "duration", "latencyMS", "segments", "words", "warning", "notes", "audioFile", "source"])
        for field in ["segments", "words"] {
            if let values = record[field] as? [Any] {
                for value in values { _ = try object(value, keys: ["start", "end", "text", "speaker", "overlapSpeakers"]) }
            }
        }
        if let value = record["notes"], !(value is NSNull) {
            let notes = try object(value, keys: ["excerpts", "sourceSHA256", "model", "created"])
            if let excerpts = notes["excerpts"] as? [Any] {
                for excerpt in excerpts { _ = try object(excerpt, keys: ["id", "text"]) }
            }
        }
        // JSONDecoder below validates missing fields, scalar/array types and nulls.
    }

    public func record(id: UUID) throws -> Transcript? {
        var value: Transcript?
        try rows("SELECT payload FROM history WHERE id=?", [.text(id.uuidString)]) { statement in
            value = try decoder.decode(Transcript.self, from: blob(statement, 0))
        }
        return value
    }

    public func statistics() throws -> HistoryStatistics {
        var value = HistoryStatistics(records: 0, words: 0)
        try rows("SELECT records,words FROM history_stats WHERE singleton=1") { statement in
            value = HistoryStatistics(records: Int(sqlite3_column_int64(statement, 0)), words: Int(sqlite3_column_int64(statement, 1)))
        }
        return value
    }

    /// Explicit validation/export tooling only, never a render-time aggregate.
    /// Hash every complete payload in list order without retaining the archive.
    public func contentFingerprint() throws -> String {
        var hash = SHA256()
        try rows("SELECT payload FROM history ORDER BY position DESC") { statement in
            autoreleasepool { digest(blob(statement, 0), into: &hash) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func page(query: String = "", before: Int64? = nil, limit: Int = 100) throws -> HistoryPage {
        let limit = min(200, max(1, limit))
        let query = Self.searchFold(query)
        let columns = "h.id,h.position,h.created,h.preview,h.mode,h.model,h.app,h.duration,h.latency,h.audio"
        var parameters: [Value] = [], predicates: [String] = []
        if let before { predicates.append("h.position<?"); parameters.append(.integer(before)) }
        // Quote the entire literal, including operators, punctuation and quotes.
        // Short queries scan text columns only, never the large payload blobs.
        let indexed = query.unicodeScalars.count >= 3 && !query.contains("\0")
        if indexed {
            predicates.append("h.position IN (SELECT rowid FROM history_search WHERE history_search MATCH ?)")
            parameters.append(.text("\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""))
        }
        let filter = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
        let short = !query.isEmpty && !indexed
        let sql = "SELECT " + columns + (short ? ",h.text,h.raw" : "") + " FROM history h" + filter + " ORDER BY h.position DESC" + (short ? "" : " LIMIT \(limit + 1)")
        var found: [HistoryRow] = []
        try rows(sql, parameters, stop: { found.count > limit }) { statement in
            if short && !text(statement, 10).contains(query) && !text(statement, 11).contains(query) { return }
            guard let id = UUID(uuidString: text(statement, 0)), let mode = WritingMode(rawValue: text(statement, 4)) else {
                throw OSprError.message("History row is damaged. Existing files were preserved.")
            }
            found.append(HistoryRow(id: id, position: sqlite3_column_int64(statement, 1),
                date: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2)), preview: text(statement, 3),
                mode: mode, model: text(statement, 5), app: text(statement, 6),
                duration: sqlite3_column_double(statement, 7), latencyMS: sqlite3_column_double(statement, 8),
                audioFile: sqlite3_column_type(statement, 9) == SQLITE_NULL ? nil : text(statement, 9)))
        }
        let more = found.count > limit
        if more { found.removeLast() }
        return HistoryPage(rows: found, next: more ? found.last?.position : nil)
    }

    @discardableResult public func remove(ids: [UUID]) throws -> Set<String> {
        var audio: Set<String> = []
        try transaction {
            for id in ids {
                try rows("SELECT audio FROM history WHERE id=? AND audio IS NOT NULL", [.text(id.uuidString)]) { audio.insert(text($0, 0)) }
                try execute("DELETE FROM history WHERE id=?", [.text(id.uuidString)])
            }
            audio = try orphanedAudio(audio)
        }
        return audio
    }

    @discardableResult public func prune(days: Int, now: Date = Date()) throws -> Set<String> {
        guard days > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86400).timeIntervalSinceReferenceDate
        var audio: Set<String> = []
        try transaction {
            try rows("SELECT audio FROM history WHERE created<? AND audio IS NOT NULL", [.real(cutoff)]) { audio.insert(text($0, 0)) }
            try execute("DELETE FROM history WHERE created<?", [.real(cutoff)])
            audio = try orphanedAudio(audio)
        }
        return audio
    }

    public func audioFiles() throws -> Set<String> {
        var audio: Set<String> = []
        try rows("SELECT audio FROM history WHERE audio IS NOT NULL") { audio.insert(text($0, 0)) }
        return audio
    }

    private func orphanedAudio(_ candidates: Set<String>) throws -> Set<String> {
        // Ordinary edits/deletes touch very few names. Use the audio index
        // rather than materializing every archive reference for each keystroke.
        if candidates.count > 128 { return candidates.subtracting(try audioFiles()) }
        var orphaned = candidates
        for name in candidates {
            try rows("SELECT 1 FROM history WHERE audio=? LIMIT 1", [.text(name)]) { _ in orphaned.remove(name) }
        }
        return orphaned
    }

    /// Update one payload at a time; do not retain the archive's timing arrays.
    @discardableResult public func stripAudio(names: Set<String>? = nil) throws -> Set<String> {
        var removed: Set<String> = []
        try transaction { removed = try stripAudioRows(names: names) }
        return removed
    }

    private func stripAudioRows(names: Set<String>?) throws -> Set<String> {
        var removed: Set<String> = []
        var cursor: Int64?
        while true {
            var batch: [Int64] = []
            let suffix = cursor == nil ? "" : " AND position>?"
            try rows("SELECT position FROM history WHERE audio IS NOT NULL" + suffix + " ORDER BY position LIMIT 32", cursor.map { [.integer($0)] } ?? []) {
                batch.append(sqlite3_column_int64($0, 0))
            }
            guard !batch.isEmpty else { break }
            for position in batch {
                try autoreleasepool {
                    var payload: Data?
                    try rows("SELECT payload FROM history WHERE position=?", [.integer(position)]) { payload = blob($0, 0) }
                    guard let data = payload else { return }
                    var record = try decoder.decode(Transcript.self, from: data)
                    if let name = record.audioFile, names == nil || names!.contains(name) {
                        removed.insert(name); record.audioFile = nil; try put(record)
                    }
                }
                cursor = position
            }
        }
        return removed
    }

    @discardableResult public func clear() throws -> Set<String> {
        let audio = try audioFiles()
        try transaction {
            try execute("DELETE FROM history")
            try execute("INSERT INTO history_search(history_search) VALUES('rebuild')")
            try execute("DELETE FROM history_meta WHERE key='legacy_sha256'")
        }
        return audio
    }

    public func verifyIntegrity() throws {
        try verifyIntegrity(mergingForLegacyRuntime: sqlite3_libversion_number() < 3_046_001)
    }

    // SQLite 3.46.1 fixed false corruption reports after FTS5 secure deletion.
    // Merge the existing index on older runtimes before checking it; do not
    // rebuild from content, which could hide a genuinely divergent index.
    // https://www.sqlite.org/releaselog/3_46_1.html
    func verifyIntegrity(mergingForLegacyRuntime: Bool) throws {
        if mergingForLegacyRuntime { try execute("INSERT INTO history_search(history_search) VALUES('optimize')") }
        var checks: [String] = []
        try rows("PRAGMA quick_check") { checks.append(text($0, 0)) }
        guard checks == ["ok"] else { throw OSprError.message("History database integrity check failed.") }
        try execute("INSERT INTO history_search(history_search,rank) VALUES('integrity-check',1)")
    }

    private func put(_ record: Transcript, position: Int64? = nil, allowUpdate: Bool = true) throws {
        let payload = try encoder.encode(record)
        let sql = """
            INSERT INTO history(position,id,created,text,raw,preview,mode,model,app,duration,latency,audio,word_count,payload)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """ + (allowUpdate ? " ON CONFLICT(id) DO UPDATE SET created=excluded.created,text=excluded.text,raw=excluded.raw,preview=excluded.preview,mode=excluded.mode,model=excluded.model,app=excluded.app,duration=excluded.duration,latency=excluded.latency,audio=excluded.audio,word_count=excluded.word_count,payload=excluded.payload" : "")
        try execute(sql, [position.map(Value.integer) ?? .null, .text(record.id.uuidString),
            .real(record.date.timeIntervalSinceReferenceDate), .text(Self.searchFold(record.text)), .text(Self.searchFold(record.rawText)),
            .text(String(String.UnicodeScalarView(record.text.unicodeScalars.prefix(480)))), .text(record.mode.rawValue), .text(record.model), .text(record.app),
            .real(record.duration), .real(record.latencyMS), record.audioFile.map(Value.text) ?? .null,
            .integer(Int64(record.text.split(whereSeparator: \.isWhitespace).count)), .blob(payload)])
    }

    private func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try work(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private static func searchFold(_ value: String) -> String {
        value.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
    }
    private func digest(_ data: Data, into hash: inout SHA256) {
        var size = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &size) { hash.update(bufferPointer: $0) }; hash.update(data: data)
    }
    private func fileDigest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let data = try autoreleasepool(invoking: { try file.read(upToCount: 65536) }), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func metadata(_ key: String) throws -> String? {
        var value: String?
        try rows("SELECT value FROM history_meta WHERE key=?", [.text(key)]) { value = text($0, 0) }
        return value
    }
    private func setMetadata(_ key: String, value: String) throws {
        try execute("INSERT INTO history_meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(value)])
    }
    private enum Value { case text(String), integer(Int64), real(Double), blob(Data), null }
    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        do {
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1), code: Int32
                switch value {
                case .text(let string): code = string.withCString { sqlite3_bind_text64(statement, index, $0, UInt64(string.utf8.count), transient, UInt8(SQLITE_UTF8)) }
                case .integer(let number): code = sqlite3_bind_int64(statement, index, number)
                case .real(let number): code = sqlite3_bind_double(statement, index, number)
                case .blob(let bytes): code = bytes.withUnsafeBytes { sqlite3_bind_blob64(statement, index, $0.baseAddress, UInt64(bytes.count), transient) }
                case .null: code = sqlite3_bind_null(statement, index)
                }
                guard code == SQLITE_OK else { throw failure() }
            }
            return statement
        } catch { sqlite3_finalize(statement); throw error }
    }
    private func execute(_ sql: String, _ values: [Value] = []) throws {
        if values.isEmpty {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
        } else {
            let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        }
    }
    private func rows(_ sql: String, _ values: [Value] = [], stop: () -> Bool = { false }, _ row: (OpaquePointer) throws -> Void) throws {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        while !stop() {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return }
            guard code == SQLITE_ROW else { throw failure() }
            try row(statement)
        }
    }
    private func integer(_ sql: String) throws -> Int64 {
        var value: Int64 = 0; try rows(sql) { value = sqlite3_column_int64($0, 0) }; return value
    }
    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, index) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
    }
    private func blob(_ statement: OpaquePointer, _ index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }
    private func failure() -> OSprError {
        // SQLite messages may contain a supplied search expression or source
        // text. Report the numeric category, without echoing private content.
        OSprError.message("History storage failed (SQLite \(sqlite3_errcode(database))). Existing data was preserved; retry or export your current transcript.")
    }
}
