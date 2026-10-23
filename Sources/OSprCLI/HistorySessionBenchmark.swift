import Darwin
import Foundation
import OSprCore
import SQLite3

/// One exploratory transition round trip in a fresh child, after a separate
/// migration child. The fixture is shared with the JSON/indexed storage controls.
enum HistorySessionBenchmark {
    static func run(rows requested: Int) throws -> [String: Any] {
        let count = min(100_000, max(1, requested))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-history-index-bench-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("indexed")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let fixture = try HistoryIndexBenchmark.writeFixture(rows: count, to: directory.appendingPathComponent("history.json"))
        let migration = try HistoryIndexBenchmark.child(directory: directory, mode: "migration", count: count)
        FileHandle.standardError.write(Data("Migration verified; measuring session transitions\n".utf8))
        let measured = try HistoryIndexBenchmark.child(directory: directory, mode: "session", count: count)
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = FileManager.default.enumerator(at: sourceRoot.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        let paths = ["Package.swift"] + files.map { String($0.path.dropFirst(sourceRoot.path.count + 1)) }.sorted()
        var result: [String: Any] = ["status": "passed", "verified_at": ISO8601DateFormatter().string(from: Date()),
            "rows": count, "fixture": fixture, "migration": migration, "transition": measured,
            "platform": ProcessInfo.processInfo.operatingSystemVersionString,
            "sqlite_version": String(cString: sqlite3_libversion()),
            "cli_sha256": try HistoryIndexBenchmark.digest(Data(contentsOf: binary)),
            "source_files_sha256": try Dictionary(uniqueKeysWithValues: paths.map { ($0, try HistoryIndexBenchmark.digest(Data(contentsOf: sourceRoot.appendingPathComponent($0)))) }),
            "git_base_commit": HistoryIndexBenchmark.git(["rev-parse", "HEAD"], at: sourceRoot) ?? "unavailable",
            "source_changes_at_run": !(HistoryIndexBenchmark.git(["status", "--porcelain", "--", "Sources", "Package.swift"], at: sourceRoot) ?? "").isEmpty,
            "boundary": "One fresh child measures serial asynchronous repository disable/enable flush barriers on an already migrated synthetic archive. Entire ordered payload fingerprints, counts, selected detail and empty disk history are verified between timed transitions. Timings exclude migration, CLI spawn, fingerprint verification, GUI and audio cleanup. Peak RSS is the child's full lifetime, including session snapshot and verification; it is not steady-state UI memory.",
            "limitations": ["One exploratory round trip, no percentiles or latency SLA.", "Primed OS caches on a shared Mac; no cache/thermal isolation.", "Session-only mode retains a full in-memory database to preserve every previously visible record; its memory cost is higher than normal paged disk history.", "No actual user history, GUI setting interaction, inference or filesystem fault injection."]]
        #if DEBUG
        result["debug_build"] = true
        #else
        result["debug_build"] = false
        #endif
        return result
    }

    static func measure(directory: URL, count: Int) async throws -> [String: Any] {
        guard 1...100_000 ~= count, directory.deletingLastPathComponent().lastPathComponent.hasPrefix("OSpr-history-index-bench-") else {
            throw OSprError.message("History session control requires an owned fixture.")
        }
        func bytes() throws -> Int64 {
            (try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(HistoryDatabase.fileName).path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        let repository = HistoryRepository(directory: directory)
        let initial = try await repository.statistics(), initialHash = try await repository.contentFingerprint()
        guard initial.records == count, let first = try await repository.page().rows.first,
              let detail = try await repository.record(id: first.id) else { throw OSprError.message("Session fixture count differs.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let detailHash = try HistoryIndexBenchmark.digest(encoder.encode(detail)), originalBytes = try bytes()
        var start = DispatchTime.now().uptimeNanoseconds
        repository.setSaving(false); try await repository.flushAsync()
        let disableMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        let session = try await repository.statistics(), sessionHash = try await repository.contentFingerprint()
        let clearedBytes = try bytes()
        let cleared = try HistoryDatabase(directory: directory)
        guard try cleared.statistics() == HistoryStatistics(records: 0, words: 0), try cleared.page(query: "API").rows.isEmpty else {
            throw OSprError.message("Session transition did not clear disk content and search.")
        }
        try cleared.verifyIntegrity()
        let clearedEmpty = try cleared.statistics().records == 0
        // Explicitly scope the extra read connection before the next transfer.
        withExtendedLifetime(cleared) {}
        start = DispatchTime.now().uptimeNanoseconds
        repository.setSaving(true); try await repository.flushAsync()
        let enableMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        let restored = try await repository.statistics(), restoredHash = try await repository.contentFingerprint()
        guard initial == session, initial == restored, initialHash == sessionHash, initialHash == restoredHash,
              let restoredDetail = try await repository.record(id: first.id),
              try HistoryIndexBenchmark.digest(encoder.encode(restoredDetail)) == detailHash else {
            throw OSprError.message("Session transition changed transcript payloads or counts.")
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return ["disable_flush_ms": disableMS, "enable_flush_ms": enableMS, "records": count, "words": initial.words,
            "initial_payloads_sha256": initialHash, "session_payloads_sha256": sessionHash, "restored_payloads_sha256": restoredHash,
            "first_detail_sha256": detailHash, "all_payloads_and_counts_equal": true, "disk_content_and_search_empty_while_off": clearedEmpty,
            "original_database_bytes": originalBytes, "cleared_database_bytes": clearedBytes, "restored_database_bytes": try bytes(),
            "peak_rss_bytes": usage.ru_maxrss]
    }
}
