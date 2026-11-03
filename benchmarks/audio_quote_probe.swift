// Headless public-fixture probe; link with the built OSprCore objects.
// Does not launch the app, play audio or touch the normal profile.
import Foundation
import CryptoKit
import OSprCore

@main struct AudioQuoteProbe {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func emit(_ value: [String: Any]) throws {
        print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
    static func verify(_ record: Transcript) throws -> [[String: Any]] {
        guard let summary = record.summary, let notes = record.notes,
              summary.validatesStoredSource(for: record), notes.matches(record.rawText) else { throw OSprError.message("Invalid stored quotes") }
        return try [("summary", summary.excerpts, AudioQuoteRequest(record: record, summary: summary)),
                    ("notes", notes.excerpts, AudioQuoteRequest(record: record, notes: notes))].map { name, quotes, request in
            let timeline = AudioQuoteTimeline(request)
            guard !quotes.isEmpty, timeline.timings.count == quotes.count else { throw OSprError.message("Incomplete real-fixture quote alignment: " + name) }
            let rows: [[String: Any]] = try quotes.map { quote in
                guard let time = timeline.timings[quote.id],
                      AudioQuotePlayback.startTime(timeline, sourceID: quote.id, current: record, loadedAudioFile: record.audioFile,
                                                   playbackDuration: record.duration, ready: true, blocked: false) == time.start else {
                    throw OSprError.message("Playback precondition failed")
                }
                return ["id": quote.id, "start": time.start, "end": time.end, "precision": time.precision.rawValue]
            }
            return ["kind": name, "quotes": quotes.count, "timings": rows]
        }
    }
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 2 else { throw OSprError.message("Expected benchmark, verify RECORD, or inference CHECKOUT AUDIO SHA256") }
        if args[1] == "benchmark" {
            var rows: [[String: Any]] = []
            for count in [10_000, 100_000] {
                let text = String(repeating: "word ", count: count)
                var record = Transcript(rawText: text, text: text, model: "synthetic", mode: .verbatim, duration: Double(count), latencyMS: 0,
                    segments: (0..<count).map { .init(start: Double($0), end: Double($0 + 1), text: "word") })
                record.audioFile = record.id.uuidString + ".wav"
                let quotes = (0..<120).map { index -> NoteExcerpt in
                    let unit = index * (count - 1) / 119
                    return .init(id: index, text: "word", sourceStartUTF8: unit * 5, sourceEndUTF8: unit * 5 + 4)
                }
                let request = AudioQuoteRequest(record: record, source: text, excerpts: quotes)
                var timings: [Double] = []
                for _ in 0..<31 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let result = AudioQuoteTimeline(request)
                    timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                    guard result.timings.count == quotes.count, result.timings[119]?.start == Double(count - 1) else { throw OSprError.message("Synthetic late-occurrence check failed") }
                }
                let sorted = timings.sorted()
                rows.append(["units": count, "quotes": quotes.count, "source_utf8_bytes": text.utf8.count, "trials_ms": timings,
                             "p50_ms": sorted[15], "p95_ms": sorted[29]])
            }
            try emit(["status": "passed-synthetic-quote-index", "records": rows,
                      "boundary": "Single-machine headless index construction, debug core objects; no model, UI, audio transport, energy or competitor measurement."])
        } else if args[1] == "verify", (3...4).contains(args.count) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let record = try decoder.decode(Transcript.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
            if args.count == 4 {
                let directory = URL(fileURLWithPath: args[3])
                guard !FileManager.default.fileExists(atPath: directory.path) else { throw OSprError.message("Choose a new disposable store") }
                let db = try HistoryDatabase(directory: directory); try db.upsert([record]); try db.verifyIntegrity()
                guard let saved = try db.record(id: record.id), saved.notes?.excerpts == record.notes?.excerpts,
                      saved.summary == record.summary else { throw OSprError.message("Quote storage differs") }
            }
            try emit(["status": "passed-stored-quote-alignment", "coverage": try verify(record)])
        } else if args[1] == "inference", args.count == 5 {
            let input = URL(fileURLWithPath: args[3]), original = try Data(contentsOf: input)
            guard digest(original) == args[4] else { throw OSprError.message("Fixture hash differs") }
            let worker = WorkerClient(root: args[2]); defer { worker.shutdown() }
            let speech = try await worker.request(["action": "transcribe", "path": input.path, "model": "parakeet-v3", "language": "en"], timeout: 3600)
            guard let text = speech["text"] as? String, !text.isEmpty, let duration = speech["audio_seconds"] as? Double else { throw OSprError.message("Missing speech output") }
            let decoder = JSONDecoder()
            let segments = try decoder.decode([Segment].self, from: JSONSerialization.data(withJSONObject: speech["segments"] ?? []))
            let words = try decoder.decode([Segment].self, from: JSONSerialization.data(withJSONObject: speech["words"] ?? []))
            var record = Transcript(rawText: text, text: text, model: "parakeet-v3", mode: .verbatim, duration: duration,
                latencyMS: speech["total_ms"] as? Double ?? 0, segments: segments, words: words, source: input.lastPathComponent)
            record.audioFile = record.id.uuidString + ".wav" // Name only; this probe does not retain or play audio.
            record.summary = try MeetingSummary.fromWorker(try await worker.request(["action": "summary", "text": text], timeout: 3600), source: text)
            record.notes = try MeetingNotes.fromWorker(try await worker.request(["action": "notes", "text": text], timeout: 3600), source: text)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-quote-probe-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let database = try HistoryDatabase(directory: directory); try database.upsert([record]); try database.verifyIntegrity()
            let reopened = try HistoryDatabase(directory: directory)
            guard let saved = try reopened.record(id: record.id), try Data(contentsOf: input) == original else { throw OSprError.message("Persistence/input changed") }
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let stored = try JSONSerialization.jsonObject(with: encoder.encode(saved))
            try emit(["status": "passed-local-speech-summary-notes-alignment", "source_sha256": digest(original), "record": stored,
                      "coverage": try verify(saved), "segments": segments.count, "words": words.count,
                      "input_unchanged": true, "sqlite_roundtrip": true,
                      "boundary": "One public AMI 180-second file; actual local Metal recognition/summary/selection and Swift validation/storage/indexing. Audio filename is synthetic, no retention or playback. No timestamp-accuracy, semantic-completeness, native UI, acoustic or ranking acceptance."])
        } else { throw OSprError.message("Invalid quote-probe arguments") }
    }
}
