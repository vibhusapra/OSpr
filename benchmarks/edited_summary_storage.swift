// Headless public-fixture storage / real-worker probe. Link with OSprCore objects.
import Foundation
import OSprCore

@main struct EditedSummaryStorageProbe {
    static let original = "Ship Friday. The price is $15.50."
    static let edited = "Do not ship Friday. The price is $12.50."
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3, ["fixtures", "read", "inference"].contains(args[1]),
              args[1] != "inference" || args.count == 4 else {
            throw OSprError.message("Usage: edited-summary-storage fixtures|read DIRECTORY, or inference DIRECTORY CHECKOUT")
        }
        let directory = URL(fileURLWithPath: args[2])
        if args[1] == "fixtures" {
            guard SummarySource.allCases.allSatisfy({ !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.rawValue).path) }) else {
                throw OSprError.message("Use a fresh disposable fixture directory.")
            }
            for kind in SummarySource.allCases {
                let path = directory.appendingPathComponent(kind.rawValue)
                var record = Transcript(rawText: original, text: edited, model: "public-fixture", mode: .clean, duration: 1, latencyMS: 1)
                let source = kind.text(in: record)
                record.summary = try MeetingSummary(source: source,
                    items: [.init(section: .overview, text: "Release plan.", sourceIDs: [0])],
                    excerpts: [.init(id: 0, text: source)], model: "fixture", chunks: 1, sourceKind: kind)
                if kind == .edited { record.text = "Later correction." }
                let db = try HistoryDatabase(directory: path)
                try db.upsert([record]); try db.verifyIntegrity()
            }
            print("public v3 original / v4 stale edited fixtures saved")
        } else if args[1] == "read" {
            let db = try HistoryDatabase(directory: directory)
            try db.verifyIntegrity()
            print("records=\(try db.statistics().records)")
        } else if args[1] == "inference" {
            guard !FileManager.default.fileExists(atPath: directory.path) else {
                throw OSprError.message("Use a fresh disposable inference directory.")
            }
            let worker = WorkerClient(root: args[3])
            let response = try await worker.request(["action": "summary", "text": edited], timeout: 3600)
            let summary = try MeetingSummary.fromWorker(response, source: edited, sourceKind: .edited)
            var record = Transcript(rawText: original, text: edited, model: "public-fixture", mode: .clean, duration: 1, latencyMS: 1)
            record.summary = summary
            let db = try HistoryDatabase(directory: directory)
            try db.upsert([record]); record.text = "A later correction."; try db.upsert([record])
            guard let saved = try db.record(id: record.id), let stored = saved.summary,
                  stored.validatesStoredSource(for: saved), !stored.sourceIsCurrent(in: saved),
                  stored.sourceSnapshot == edited, saved.rawText == original else {
                throw OSprError.message("Edited summary storage validation failed.")
            }
            var receipt = response
            receipt["source_kind"] = stored.sourceKind.rawValue
            receipt["source_snapshot"] = stored.sourceSnapshot
            receipt["current_edited_text"] = saved.text
            receipt["original_text"] = saved.rawText
            receipt["stored_source_valid"] = true
            receipt["source_current"] = false
            print(String(decoding: try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        } else { throw OSprError.message("Expected fixtures, read or inference.") }
    }
}
