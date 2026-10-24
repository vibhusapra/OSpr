import Foundation
import OSprCore

enum NeuralEdgeCheck {
    struct Item: Decodable { let id: String; let path: String; let language: String }
    /// Public-fixture acceptance harness: one owned resident ASR worker per
    /// model, both complete-audio and actual app edge orchestration. The order
    /// is fixed and is not suitable for a comparative latency claim.
    static func run(manifest: URL, model: String, worker: WorkerClient) async throws -> [String: Any] {
        let handle = try FileHandle(forReadingFrom: manifest); defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 1024 * 1024 + 1) ?? Data()
        guard bytes.count <= 1024 * 1024 else { throw OSprError.message("Neural edge fixture manifest exceeds 1 MiB.") }
        let items = try JSONDecoder().decode([Item].self, from: bytes)
        guard !items.isEmpty, items.count <= 200, Set(items.map(\.id)).count == items.count,
              items.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 200 && $0.path.hasPrefix("/") && $0.language.count <= 16 }) else {
            throw OSprError.message("Neural edge acceptance requires 1–200 unique absolute local fixtures.")
        }
        var records = [[String: Any]]()
        for item in items {
            try Task.checkCancellation()
            let body: [String: Any] = ["action": "transcribe", "path": item.path, "model": model, "language": item.language, "trim": false]
            let full = try await worker.request(body)
            let edges = try await NeuralEdgeTranscription.run(source: URL(fileURLWithPath: item.path), request: body, worker: worker)
            records.append(["id": item.id, "full": full, "neural_edges": edges])
            FileHandle.standardError.write(Data("Neural edges · \(model) · \(records.count)/\(items.count) · \(item.id)\n".utf8))
        }
        return ["model": model, "records": records,
                "boundary": "Real CLI/worker normalization, pinned native CPU edge analysis, full PCM hash verification and local Metal ASR. One resident worker per model. Full then edge order is fixed; timing is diagnostic and not a latency comparison. Public local files only; no microphone, UI or insertion."]
    }
}
