import CryptoKit
import Darwin
import Foundation
import OSprCore
import SQLite3

/// Synthetic storage-only benchmark. Every measurement runs in a new owned CLI
/// process so JSON decoding cannot contaminate the indexed process's peak RSS.
enum HistoryIndexBenchmark {
    static func run(rows requested: Int, repeats requestedRepeats: Int) throws -> [String: Any] {
        let count = min(100_000, max(1, requested)), repeats = min(10, max(1, requestedRepeats))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-history-index-bench-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("legacy"), indexed = root.appendingPathComponent("indexed")
        for directory in [legacy, indexed] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        let source = legacy.appendingPathComponent("history.json")
        let fixture = try writeFixture(rows: count, to: source)
        try FileManager.default.copyItem(at: source, to: indexed.appendingPathComponent("history.json"))
        let migration = try child(directory: indexed, mode: "migration", count: count)
        let expectedWords = count * (try require(fixture["text_words_per_record"] as? Int))
        var jobs = (0..<repeats).flatMap { repeatIndex in ["legacy", "indexed"].map { (repeatIndex, $0) } }
        var random = SeededRandom(seed: 20261022)
        jobs.shuffle(using: &random)
        var records: [[String: Any]] = []
        var reference: [String: [String]]?
        var detail: String?
        for (repeatIndex, mode) in jobs {
            var value = try child(directory: mode == "legacy" ? legacy : indexed, mode: mode, count: count)
            value["repeat"] = repeatIndex
            guard value["words"] as? Int == expectedWords,
                  migration["words"] as? Int == value["words"] as? Int else {
                throw OSprError.message("History word totals differ between paths.")
            }
            let found = try require(value["matches"] as? [String: [String]])
            if let reference, let detail {
                guard found == reference, value["first_record_sha256"] as? String == detail else {
                    throw OSprError.message("History benchmark changed matching IDs or detailed transcript data.")
                }
            } else { reference = found; detail = value["first_record_sha256"] as? String }
            records.append(value)
            FileHandle.standardError.write(Data("Verified history case \(records.count)/\(jobs.count) · \(mode)\n".utf8))
        }
        var summary: [String: Any] = [:]
        for mode in ["legacy", "indexed"] {
            let values = records.filter { $0["mode"] as? String == mode }
            summary[mode] = ["trials": values.count,
                "initial_data_p50_ms": median(values.compactMap { $0["initial_data_ms"] as? Double }),
                "initial_data_p95_ms": percentile(values.compactMap { $0["initial_data_ms"] as? Double }, 0.95),
                "peak_rss_p50_bytes": median(values.compactMap { ($0["peak_rss_bytes"] as? NSNumber)?.doubleValue }),
                "queries": Dictionary(uniqueKeysWithValues: queries(count).map { query in
                    let times = values.compactMap { ($0["query_ms"] as? [String: Double])?[query] }
                    return (query, ["p50_ms": median(times), "p95_ms": percentile(times, 0.95)])
                })]
        }
        var result: [String: Any] = ["status": "passed", "verified_at": ISO8601DateFormatter().string(from: Date()),
            "rows": count, "repeats": repeats, "seed": 20261022, "fixture": fixture,
            "platform": ProcessInfo.processInfo.operatingSystemVersionString,
            "sqlite_version": String(cString: sqlite3_libversion()), "migration": migration,
            "summary": summary, "records": records, "all_query_ids_and_first_detail_equal": true,
            "boundary": "New owned CLI process per mode/trial; timings start after command dispatch and exclude process spawn. Legacy decodes the complete JSON archive, computes all words and filters every record before taking 100 results. Indexed opens an already migrated database, obtains aggregate counts, loads 100 lightweight rows and decodes one selected detail. Eight literal queries include common, rare, missing, path, punctuation, Unicode and short cases. No SwiftUI, native app launch, typing cadence, real user archives or inference.",
            "limitations": ["Deterministic synthetic timing-rich transcripts, not naturally distributed history.",
                "Migration runs first; subsequent serial order is seeded-random. OS caches remain primed; no filesystem or thermal isolation.",
                "Peak RSS is each child process's lifetime Darwin ru_maxrss, not app UI memory or an isolated allocation delta.",
                "Storage engine remains work in progress until asynchronous app integration and native acceptance pass."]]
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        result["cli_sha256"] = digest(try Data(contentsOf: binary))
        #if DEBUG
        result["debug_build"] = true
        #else
        result["debug_build"] = false
        #endif
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sourcePaths = ["Sources/OSprCore/HistoryDatabase.swift", "Sources/OSprCore/HistoryJSONStream.swift", "Sources/OSprCore/Domain.swift", "Sources/OSprCLI/HistoryIndexBenchmark.swift", "Sources/OSprCLI/OSprCLI.swift", "Package.swift"]
        result["source_files_sha256"] = try Dictionary(uniqueKeysWithValues: sourcePaths.map { ($0, try digest(Data(contentsOf: sourceRoot.appendingPathComponent($0)))) })
        result["git_base_commit"] = git(["rev-parse", "HEAD"], at: sourceRoot)
        result["source_changes_at_run"] = !(git(["status", "--porcelain", "--", "Sources", "Package.swift"], at: sourceRoot) ?? "").isEmpty
        return result
    }

    static func measure(directory: URL, mode: String, count: Int) throws -> [String: Any] {
        guard ["legacy", "indexed", "migration"].contains(mode), directory.deletingLastPathComponent().lastPathComponent.hasPrefix("OSpr-history-index-bench-") else {
            throw OSprError.message("History benchmark cases require an owned synthetic fixture directory.")
        }
        let began = DispatchTime.now().uptimeNanoseconds
        var matches: [String: [String]] = [:], times: [String: Double] = [:]
        let initialMS: Double, firstHash: String, totalWords: Int
        if mode == "legacy" {
            let store = try LocalStore(directory: directory)
            let items = try require(store.read([Transcript].self, name: "history.json"))
            guard items.count == count else { throw OSprError.message("Synthetic legacy history count differs.") }
            totalWords = items.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
            firstHash = try canonicalDigest(require(items.first))
            initialMS = milliseconds(since: began)
            for query in queries(count) {
                let start = DispatchTime.now().uptimeNanoseconds
                let selected = items.filter { $0.text.localizedCaseInsensitiveContains(query) || $0.rawText.localizedCaseInsensitiveContains(query) }
                matches[query] = Array(selected.prefix(100)).map { $0.id.uuidString }
                times[query] = milliseconds(since: start)
            }
            withExtendedLifetime(items) {}
        } else {
            let database = try HistoryDatabase(directory: directory)
            let statistics = try database.statistics(), page = try database.page(limit: 100)
            guard statistics.records == count, let first = page.rows.first else { throw OSprError.message("Indexed fixture count differs.") }
            totalWords = statistics.words
            firstHash = try canonicalDigest(require(database.record(id: first.id)))
            initialMS = milliseconds(since: began)
            if mode == "migration" { try database.verifyIntegrity() }
            else {
                for query in queries(count) {
                    let start = DispatchTime.now().uptimeNanoseconds
                    matches[query] = try database.page(query: query, limit: 100).rows.map { $0.id.uuidString }
                    times[query] = milliseconds(since: start)
                }
            }
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let databaseBytes = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(HistoryDatabase.fileName).path)[.size] as? NSNumber)?.int64Value ?? 0
        return ["mode": mode, "initial_data_ms": initialMS, "peak_rss_bytes": usage.ru_maxrss, "database_bytes": databaseBytes,
                "query_ms": times, "matches": matches, "first_record_sha256": firstHash,
                "records": count, "words": totalWords]
    }

    private static func child(directory: URL, mode: String, count: Int) throws -> [String: Any] {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        process.arguments = ["_benchmark-history-index-case", directory.path, mode, String(count)]
        process.standardOutput = output; process.standardError = errors
        process.currentDirectoryURL = directory.deletingLastPathComponent()
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 180, execute: deadline)
        defer { deadline.cancel() }
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw OSprError.message("Synthetic history benchmark case failed: " + (String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown error"))
        }
        return try require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    private static func writeFixture(rows: Int, to url: URL) throws -> [String: Any] {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let sentence = "Project Ω: review the API in C++ on Monday; do not change the $12.50 price. Keep /Users/example/notes and 日本語 identifiers intact."
        let words = sentence.split(whereSeparator: \.isWhitespace).enumerated().map { Segment(start: Double($0.offset) * 0.2, end: Double($0.offset + 1) * 0.2, text: String($0.element), speaker: $0.offset % 2) }
        let epoch = Date(timeIntervalSince1970: 1_792_640_000)
        var buffer = Data("[\n".utf8), hash = SHA256(), bytes = 0
        func flush() throws { hash.update(data: buffer); bytes += buffer.count; try file.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
        for ordinal in 0..<rows {
            try autoreleasepool {
                let index = rows - ordinal - 1
                let marker = String(format: "needle-%07d", index)
                var item = Transcript(rawText: marker + ": " + sentence, text: marker + ": " + sentence,
                    model: "synthetic-fixture", mode: .clean, duration: 12, latencyMS: 50,
                    segments: [Segment(start: 0, end: 12, text: sentence)], words: words)
                item.id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", UInt32(index + 1)))!
                item.date = epoch.addingTimeInterval(Double(index))
                if ordinal > 0 { buffer.append(contentsOf: ",\n".utf8) }
                buffer.append(try encoder.encode(item))
                if buffer.count >= 1_048_576 { try flush() }
            }
        }
        buffer.append(contentsOf: "\n]\n".utf8); try flush()
        return ["sha256": hash.finalize().map { String(format: "%02x", $0) }.joined(), "bytes": bytes,
                "text_words_per_record": words.count + 1, "timed_words_per_record": words.count, "rows": rows]
    }
    private static func queries(_ count: Int) -> [String] {
        ["API", "do not", "C++", "日本語", "example/notes", String(format: "needle-%07d", count / 2), "Ω", "not-present-anywhere-49018"]
    }
    private static func canonicalDigest(_ record: Transcript) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try digest(encoder.encode(record))
    }
    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw OSprError.message("Synthetic history benchmark response is incomplete.") }; return value
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func milliseconds(since start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 }
    private static func median(_ values: [Double]) -> Double { percentile(values, 0.5) }
    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted(); return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }
    private static func git(_ arguments: [String], at directory: URL) -> String? {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return process.terminationStatus == 0 ? String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
    private struct SeededRandom: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9e3779b97f4a7c15
            var value = state; value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
            value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
            return value ^ (value >> 31)
        }
    }
}
