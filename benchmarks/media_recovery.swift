// Real WorkerClient / cached-ASR recovery probe. No microphone or UI automation.
import CryptoKit
import Foundation

@main struct MediaRecovery {
    static func main() async throws {
        guard CommandLine.arguments.count == 6 else {
            throw OSprError.message("Usage: media-recovery <engine-root> <public-audio> <invalid-local-file> <model> <output.json>")
        }
        let args = CommandLine.arguments, worker = WorkerClient(root: args[1])
        defer { worker.shutdown() }
        let model = args[4], source = URL(fileURLWithPath: args[2]), invalid = URL(fileURLWithPath: args[3])
        _ = try await worker.request(["action": "warm", "model": model])
        let request: [String: Any] = ["action": "transcribe", "path": source.path, "model": model, "language": "", "trim": false]
        let before = try await worker.request(request)
        let pid = try await worker.request(["action": "ping"])
        var bad = request; bad["path"] = invalid.path
        var rejection = ""
        do { _ = try await worker.request(bad); throw OSprError.message("Invalid media was accepted") }
        catch { rejection = error.localizedDescription }
        guard rejection.contains("could not be read as audio"), !rejection.contains("Command"), !rejection.contains(invalid.path) else {
            throw OSprError.message("Expected a sanitized media-read rejection")
        }
        let nextPID = try await worker.request(["action": "ping"])
        let after = try await worker.request(request)
        guard let originalPID = pid["pid"] as? Int, nextPID["pid"] as? Int == originalPID,
              before["warm"] as? Bool == true, after["warm"] as? Bool == true,
              let text = before["text"] as? String, !text.isEmpty, text == after["text"] as? String else {
            throw OSprError.message("Worker/model/text was not retained across the media rejection")
        }
        func digest(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
        let result: [String: Any] = ["schema_version": 1, "status": "passed-real-media-rejection-recovery", "model": model,
            "input_sha256": try digest(source), "invalid_sha256": try digest(invalid),
            "same_worker_pid": true, "warm_before": true, "warm_after": true,
            "before_text": text, "after_text": after["text"] as? String ?? "", "rejection": rejection,
            "boundary": "One cached local public-speech control. Same PID, warm ASR and exact text; no comparative timing or acoustic acceptance."]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: args[5]))
        print("Passed real media rejection recovery: \(model)")
    }
}
