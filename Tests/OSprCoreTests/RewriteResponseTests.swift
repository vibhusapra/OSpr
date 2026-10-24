import XCTest
@testable import OSprCore

final class RewriteResponseTests: XCTestCase {
    private func message(content: [[String: Any]], stop: Any = "end_turn") -> [String: Any] {
        ["type": "message", "role": "assistant", "stop_reason": stop, "content": content]
    }
    func testCompleteAnthropicTextPreservesUnicodeWhitespaceAndExcludesThoughts() throws {
        let result = try RewriteResponse.anthropic(message(content: [
            ["type": "thinking", "thinking": "PRIVATE THOUGHT", "text": "PRIVATE THOUGHT", "signature": "opaque"],
            ["type": "text", "text": "  café\n"],
            ["type": "redacted_thinking", "data": "opaque"],
            ["type": "text", "text": "不要发布。\n"]]))
        XCTAssertEqual(result, "  café\n不要发布。\n")
    }
    func testAnthropicIncompleteRefusedPausedCustomStopAndUnexpectedMetadataFail() {
        for stop in ["max_tokens", "stop_sequence", "tool_use", "pause_turn", "refusal", "model_context_window_exceeded", "unknown", ""] {
            XCTAssertThrowsError(try RewriteResponse.anthropic(message(content: [["type": "text", "text": "Draft"]], stop: stop)))
        }
        var value = message(content: [["type": "text", "text": "Draft"]], stop: NSNull())
        XCTAssertThrowsError(try RewriteResponse.anthropic(value))
        value.removeValue(forKey: "stop_reason"); XCTAssertThrowsError(try RewriteResponse.anthropic(value))
        for field in ["stop_sequence", "stop_details"] {
            value = message(content: [["type": "text", "text": "Draft"]]); value[field] = "PRIVATE DETAIL"
            XCTAssertThrowsError(try RewriteResponse.anthropic(value)) { error in
                XCTAssertFalse(error.localizedDescription.contains("PRIVATE"))
            }
        }
        value = message(content: [["type": "text", "text": "Completed"]]); value["stop_sequence"] = NSNull(); value["stop_details"] = NSNull()
        XCTAssertNoThrow(try RewriteResponse.anthropic(value))
    }
    func testAnthropicNonTextBlocksNeverBecomeEditedPassageEvenWithEndTurn() {
        for type in ["tool_use", "server_tool_use", "tool_result", "refusal", "image", "compaction", "unknown"] {
            let value = message(content: [["type": "text", "text": "Draft"], ["type": type, "text": "PRIVATE CONTENT"]])
            XCTAssertThrowsError(try RewriteResponse.anthropic(value)) { error in
                XCTAssertFalse(error.localizedDescription.contains("PRIVATE"))
            }
        }
    }
    func testAnthropicMalformedEmptyOrThoughtOnlyContentFails() {
        for content: [[String: Any]] in [[], [["type": "text", "text": " \n"]], [["type": "text", "text": 12]], [["text": "missing type"]], [["type": "thinking", "thinking": "PRIVATE"]]] {
            XCTAssertThrowsError(try RewriteResponse.anthropic(message(content: content)))
        }
        for field in ["type", "role", "content"] {
            var value = message(content: [["type": "text", "text": "Completed"]]); value[field] = "wrong"
            XCTAssertThrowsError(try RewriteResponse.anthropic(value))
            value.removeValue(forKey: field); XCTAssertThrowsError(try RewriteResponse.anthropic(value))
        }
    }
}
