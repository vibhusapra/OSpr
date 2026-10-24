import Foundation
import CryptoKit
import OSprCore

/// Deliberate output-limit sentinel, not a quality or latency benchmark.
/// Reads only the supplied audio; no recording, insertion, history or providers.
enum LocalCompletionCheck {
    static func run(source: URL, worker: WorkerClient, missingLargerWeights: Bool = false) async throws -> [String: Any] {
        let input = try Data(contentsOf: source)
        let request: [String: Any] = ["action": "transcribe", "path": source.path, "model": "parakeet-v3", "language": "en"]
        let original = try await worker.request(request)
        guard let text = original["text"] as? String, !text.isEmpty else {
            throw OSprError.message("Supply a short public speech fixture with a nonempty transcript.")
        }
        let before = try await worker.request(["action": "ping"])
        var rejection = ""
        do {
            // Existing production budget for one character is 130 tokens.
            // This instruction deliberately asks for far more output.
            let request: [String: Any] = missingLargerWeights ? LocalRefinementModel.larger.request(text: "Public fixture.", instruction: "Clean.") : ["action": "rewrite", "task": "edit-selection", "text": "x",
                "instruction": "Replace the selection with the word orange repeated exactly 2000 times, separated by spaces. Output all 2000 repetitions, with no explanation or abbreviation."]
            _ = try await worker.request(request)
        } catch { rejection = error.localizedDescription }
        let expected = missingLargerWeights ? "LocalModelNotPrepared: Prepare the 9B text model" : "LocalCompletionError: Local text completion was not acknowledged"
        guard rejection.hasPrefix(expected) else {
            throw OSprError.message("The deliberate output-limit sentinel did not reject as expected.")
        }
        let after = try await worker.request(["action": "ping"])
        let status = try await worker.request(["action": "model_status"])
        let repeated = try await worker.request(request)
        guard let pid = before["pid"] as? Int, after["pid"] as? Int == pid,
              (status["resident"] as? [String])?.contains("parakeet-v3") == true,
              repeated["warm"] as? Bool == true, repeated["text"] as? String == text else {
            throw OSprError.message("Output-limit rejection lost warm ASR or changed recognition.")
        }
        guard try Data(contentsOf: source) == input else { throw OSprError.message("Speech fixture changed.") }
        return ["status": "passed", "timestamp": ISO8601DateFormatter().string(from: Date()),
                "source_sha256": SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined(),
                "same_worker_pid": true, "asr_resident_after_rejection": true,
                "warm_asr_text_unchanged": true, "partial_text_delivered": false,
                "sentinel_max_tokens": missingLargerWeights ? NSNull() : 130, "text": text, "rejection": rejection,
                "expected_failure": missingLargerWeights ? "text-model-not-prepared" : "text-output-limit",
                "rewrite_model": status["rewrite_resident"] ?? NSNull(),
                "boundary": "Swift CLI and shared WorkerClient → expected local text rejection → same owned worker and warm Parakeet recognition. No microphone, UI, insertion, history, provider or comparative timing/quality claim."]
    }
}
