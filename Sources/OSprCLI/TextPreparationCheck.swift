import Foundation
import CryptoKit
import OSprCore

/// One fresh worker per invocation; owned public fixtures only. Timers measure
/// this shared Mac, not physical capture, insertion, battery or consumer latency.
enum TextPreparationCheck {
    static func run(source: URL, choice: LocalRefinementModel, prepare: Bool, worker: WorkerClient) async throws -> [String: Any] {
        let bytes = try Data(contentsOf: source)
        let speech: [String: Any] = ["action": "transcribe", "path": source.path, "model": "parakeet-v3", "language": "en"]
        let beforeSpeech = try await worker.request(speech)
        guard let originalSpeech = beforeSpeech["text"] as? String, !originalSpeech.isEmpty else { throw OSprError.message("Supply a short public speech fixture.") }
        let before = try await worker.request(["action": "ping"])
        var preparation: [String: Any] = [:]
        var preparationWall = 0.0
        if prepare {
            let started = Date()
            preparation = try await worker.request(choice.preparationRequest)
            try choice.validatePreparation(preparation)
            preparationWall = Date().timeIntervalSince(started) * 1000
        }
        let text = "Um, please send the revised estimate to Zoë Saldaña, not the other team. The price is 125 dollars, and we have not approved the change."
        let instruction = WritingMode.clean.instruction(custom: "", language: "en")
        let started = Date()
        let rewritten = try await worker.request(choice.request(text: text, instruction: instruction))
        let raw = try choice.completedText(rewritten)
        let firstWall = Date().timeIntervalSince(started) * 1000
        let rejection = RewriteGuard.rejection(original: text, rewritten: raw, mode: .clean)
        var repeated: [String: Any] = [:]
        if prepare {
            repeated = try await worker.request(choice.preparationRequest)
            try choice.validatePreparation(repeated)
            guard repeated["already_prepared"] as? Bool == true else { throw OSprError.message("Resident text model repeated synthetic inference.") }
        }
        let status = try await worker.request(["action": "model_status"])
        let afterSpeech = try await worker.request(speech)
        let after = try await worker.request(["action": "ping"])
        guard let pid = before["pid"] as? Int, after["pid"] as? Int == pid,
              (status["resident"] as? [String])?.contains("parakeet-v3") == true,
              status["rewrite_resident"] as? String == choice.workerModel,
              (status["rewrite_primed"] as? String == choice.workerModel) == prepare,
              afterSpeech["warm"] as? Bool == true, afterSpeech["text"] as? String == originalSpeech,
              try Data(contentsOf: source) == bytes else {
            throw OSprError.message("Text preparation changed speech residency, recognition, selected model or the public fixture.")
        }
        return ["status": "passed", "model": choice.workerModel, "repository": choice.repository,
            "prepared": prepare, "preparation": preparation, "repeated_preparation": repeated,
            "preparation_wall_ms": preparationWall, "first_real_rewrite_wall_ms": firstWall,
            "preparation_plus_first_rewrite_ms": preparationWall + firstWall,
            "original": text, "raw_text": raw, "text": rejection == nil ? raw : text,
            "rewrite_accepted": rejection == nil, "warning": rejection ?? "", "completion": rewritten,
            "same_worker_pid": true, "asr_resident": true, "warm_asr_text_unchanged": true,
            "speech_text": originalSpeech, "source_sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            "boundary": "Fresh Swift CLI/shared WorkerClient; Parakeet resident before text preparation. Synthetic output discarded, both real texts checked. Timers include IPC/decoding on a shared Mac; preparation shifts work earlier. No native capture, Settings, insertion, energy, representative quality or product ranking claim."]
    }
    static func missingCache(source: URL, worker: WorkerClient) async throws -> [String: Any] {
        let bytes = try Data(contentsOf: source)
        let request: [String: Any] = ["action": "transcribe", "path": source.path, "model": "parakeet-v3", "language": "en"]
        let original = try await worker.request(request)
        guard let text = original["text"] as? String, !text.isEmpty else { throw OSprError.message("Supply a public speech fixture.") }
        let before = try await worker.request(["action": "ping"])
        var rejections: [String] = []
        for choice in LocalRefinementModel.allCases {
            do { _ = try await worker.request(choice.preparationRequest); throw OSprError.message("Missing text weights did not reject preparation.") }
            catch {
                guard WorkerClient.retainsTextModels(after: error, action: "warm_text"), error.localizedDescription.hasPrefix("LocalModelNotPrepared:") else { throw error }
                rejections.append(choice.workerModel)
            }
        }
        let after = try await worker.request(["action": "ping"])
        let state = try await worker.request(["action": "model_status"])
        let repeated = try await worker.request(request)
        guard let pid = before["pid"] as? Int, after["pid"] as? Int == pid,
              (state["resident"] as? [String])?.contains("parakeet-v3") == true,
              state["rewrite_resident"] as? String == nil, state["rewrite_primed"] as? String == nil,
              repeated["warm"] as? Bool == true, repeated["text"] as? String == text,
              try Data(contentsOf: source) == bytes else { throw OSprError.message("Preparation rejection lost warm speech recognition or changed the fixture.") }
        return ["status": "passed", "rejected_models": rejections, "same_worker_pid": true,
                "asr_resident_after_rejection": true, "warm_asr_text_unchanged": true,
                "text": text, "source_sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                "boundary": "Actual Swift WorkerClient and production Engine with isolated Parakeet-only cache; both missing text preparations reject while warm speech remains. No native UI/microphone/insertion, provider or comparative latency claim."]
    }

}
