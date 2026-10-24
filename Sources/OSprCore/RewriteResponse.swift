import Foundation

/// A successful HTTP response is not necessarily a completed rewrite. Reject
/// partial/tool/refusal turns before the caller's separate semantic tripwires.
enum RewriteResponse {
    private static func absent(_ value: Any?) -> Bool { value == nil || value is NSNull }
    private static func noRefusal(_ value: Any?) -> Bool {
        absent(value) || (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
    }
    private static func filtered(_ value: Any?) -> Bool {
        if let object = value as? [String: Any] {
            return object["filtered"] as? Bool == true || object.values.contains(where: { filtered($0) })
        }
        if let array = value as? [Any] { return array.contains(where: { filtered($0) }) }
        return false
    }
    static func chat(_ response: [String: Any], providerName: String = "Provider") throws -> String {
        guard !filtered(response["prompt_filter_results"]),
              let choices = response["choices"] as? [[String: Any]], choices.count == 1,
              let choice = choices.first, choice["index"] as? Int == 0, choice["finish_reason"] as? String == "stop",
              !filtered(choice["content_filter_results"]),
              let message = choice["message"] as? [String: Any], message["role"] as? String == "assistant",
              noRefusal(message["refusal"]), absent(message["function_call"]), absent(message["audio"]),
              absent(message["tool_calls"]) || (message["tool_calls"] as? [Any])?.isEmpty == true,
              let text = message["content"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OSprError.message("\(providerName) did not return a complete text rewrite. Original text is retained; check the model, output limit and provider settings.")
        }
        return text
    }
    static func anthropic(_ response: [String: Any]) throws -> String {
        guard response["type"] as? String == "message", response["role"] as? String == "assistant",
              response["stop_reason"] as? String == "end_turn",
              absent(response["stop_sequence"]), absent(response["stop_details"]),
              let content = response["content"] as? [[String: Any]], !content.isEmpty else {
            throw OSprError.message("Anthropic did not return a complete text rewrite. Original text is retained; check the model, output limit and provider settings.")
        }
        var text = ""
        for block in content {
            switch block["type"] as? String {
            case "text":
                guard let value = block["text"] as? String else {
                    throw OSprError.message("Anthropic returned content other than edited text. Original text is retained.")
                }
                text += value
            case "thinking", "redacted_thinking": continue
            default:
                throw OSprError.message("Anthropic returned content other than edited text. Original text is retained.")
            }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OSprError.message("Anthropic returned no rewritten text. Original text is retained.")
        }
        return text
    }
}
