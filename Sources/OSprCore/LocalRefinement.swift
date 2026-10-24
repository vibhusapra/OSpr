import Foundation

/// Provider tags also make older apps reject an unsupported local model before
/// network transport, rather than silently substituting the smaller model.
public enum LocalRefinementModel: String, CaseIterable, Sendable {
    case standard = "local"
    case larger = "local-9b"
    public var workerModel: String { self == .standard ? "rewrite-quality" : "meeting-quality" }
    public var repository: String { self == .standard ? "mlx-community/Qwen3-4B-Instruct-2507-4bit" : "mlx-community/Qwen3.5-9B-4bit" }
    public var title: String { self == .standard ? "Local MLX · Qwen3 4B Instruct 4-bit" : "Local MLX · Qwen3.5 9B 4-bit · experimental" }
    public func request(text: String, instruction: String, editingSelection: Bool = false) -> [String: Any] {
        ["action": "rewrite", "model": workerModel, "text": text, "instruction": instruction,
         "task": editingSelection ? "edit-selection" : "transcript"]
    }
    public func completedText(_ result: [String: Any]) throws -> String {
        struct Completion: Decodable {
            let text: String
            let model: String
            let finish_reason: String
            let generation_tokens: Int
        }
        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let completion = try? JSONDecoder().decode(Completion.self, from: data),
              completion.model == repository, completion.finish_reason == "stop",
              (1...4096).contains(completion.generation_tokens),
              !completion.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OSprError.message("The local engine did not acknowledge the selected text model and completed output. Update the engine and retry. Original text is retained.")
        }
        return completion.text
    }
}

extension OSprSettings {
    public var localRefinementModel: LocalRefinementModel? { LocalRefinementModel(rawValue: rewriteProvider) }
}
