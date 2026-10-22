import Foundation
import CryptoKit
import OSprCore

enum HistoryBenchmark {
    static func run(rows: Int, edits: Int) async throws -> [String: Any] {
        let rows = min(25_000, max(1, rows)), edits = min(200, max(1, edits))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-history-benchmark-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = try LocalStore(directory: root.appendingPathComponent("legacy"))
        let current = try LocalStore(directory: root.appendingPathComponent("current"))
        let sentence = "Project Ω: review the API on Monday; do not change the $12.50 price. Keep /Users/example/notes and 日本語 identifiers intact."
        let epoch = Date(timeIntervalSince1970: 1_792_640_000)
        let now = epoch.addingTimeInterval(Double(rows) + 86400)
        let initial = (0..<rows).map { index in
            var record = Transcript(rawText: "\(index): \(sentence)", text: "\(index): \(sentence)", model: "synthetic-fixture", mode: .clean,
                                    duration: 12, latencyMS: 50, segments: [Segment(start: 0, end: 12, text: sentence)])
            record.id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", UInt32(index + 1)))!
            record.date = epoch.addingTimeInterval(Double(index))
            return record
        }
        try legacy.write(initial, name: "history.json"); try current.write(initial, name: "history.json")
        var oldRows = initial
        var oldTimes: [Double] = []
        let oldStart = DispatchTime.now().uptimeNanoseconds
        for index in 0..<edits {
            let start = DispatchTime.now().uptimeNanoseconds
            oldRows[0].text = sentence + " edit \(index)"
            oldRows = LocalStore.retained(oldRows, days: 30, now: now)
            try legacy.write(oldRows, name: "history.json")
            oldTimes.append(milliseconds(since: start))
        }
        let oldTotal = milliseconds(since: oldStart)
        var newRows = initial
        var newTimes: [Double] = []
        let writer = try HistoryPersistence(directory: current.directory)
        let newStart = DispatchTime.now().uptimeNanoseconds
        for index in 0..<edits {
            let start = DispatchTime.now().uptimeNanoseconds
            newRows[0].text = sentence + " edit \(index)"
            newRows = LocalStore.retained(newRows, days: 30, now: now)
            writer.submit(newRows, delay: 0.3)
            newTimes.append(milliseconds(since: start))
        }
        let flushStart = DispatchTime.now().uptimeNanoseconds
        try await writer.flushAsync()
        let flush = milliseconds(since: flushStart), newTotal = milliseconds(since: newStart)
        let oldData = try Data(contentsOf: legacy.directory.appendingPathComponent("history.json"))
        let newData = try Data(contentsOf: current.directory.appendingPathComponent("history.json"))
        guard oldData == newData else { throw OSprError.message("Final persisted histories differ.") }
        let counts = writer.statistics()
        var result: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date()), "rows": rows, "edits": edits,
                "platform": ProcessInfo.processInfo.operatingSystemVersionString, "archive_bytes": newData.count,
                "final_files_identical": true, "final_sha256": SHA256.hash(data: newData).map { String(format: "%02x", $0) }.joined(),
                "legacy": ["edit_p50_ms": percentile(oldTimes, 0.5), "edit_p95_ms": percentile(oldTimes, 0.95), "total_ms": oldTotal, "writes": edits],
                "coalescing": ["edit_p50_ms": percentile(newTimes, 0.5), "edit_p95_ms": percentile(newTimes, 0.95), "flush_ms": flush, "total_ms": newTotal, "writes": counts.committed, "failed_writes": counts.failed],
                "boundary": "Deterministic synthetic archive, sequential rapid edits, full-array mutation, 30-day retention filtering and persistence admission. Legacy encodes/writes synchronously per edit; new path admits snapshots to a serial background writer with 300 ms debounce and awaits one final flush. No SwiftUI rendering or human typing cadence.",
                "limitations": ["Fixed legacy-first order; no filesystem cache/thermal isolation.", "Single Mac and synthetic short transcripts; does not measure UI frame timing, launch indexing or crash recovery."]]
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        result["cli_executable_sha256"] = digest(try Data(contentsOf: executable))
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if let enumerator = FileManager.default.enumerator(at: sourceRoot.appendingPathComponent("Sources"), includingPropertiesForKeys: nil),
           let files = enumerator.allObjects as? [URL] {
            var hash = SHA256()
            for file in (files.filter { $0.pathExtension == "swift" } + [sourceRoot.appendingPathComponent("Package.swift")]).sorted(by: { $0.path < $1.path }) {
                hash.update(data: Data((file.path.replacingOccurrences(of: sourceRoot.path + "/", with: "") + "\0").utf8))
                hash.update(data: try Data(contentsOf: file))
            }
            result["source_files_at_run_sha256"] = hash.finalize().map { String(format: "%02x", $0) }.joined()
            result["git_commit_at_run"] = git(["rev-parse", "HEAD"], root: sourceRoot)
            result["source_changes_at_run"] = !(git(["status", "--porcelain", "--untracked-files=normal", "--", "Sources", "Package.swift"], root: sourceRoot) ?? "").isEmpty
        }
        return result
    }
    private static func git(_ arguments: [String], root: URL) -> String? {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func milliseconds(since start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 }
    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }
}
