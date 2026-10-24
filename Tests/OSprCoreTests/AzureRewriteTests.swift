import XCTest
@testable import OSprCore

final class AzureRewriteTests: XCTestCase {
    private func response(text: String = "Edited passage.", finish: String = "stop", messageFields: [String: Any] = [:], choiceFields: [String: Any] = [:]) -> [String: Any] {
        let message = ["role": "assistant", "content": text].merging(messageFields) { _, new in new }
        let choice: [String: Any] = ["index": 0, "finish_reason": finish, "message": message]
        return ["choices": [choice.merging(choiceFields) { _, new in new }]]
    }
    func testResourceRootAndV1BaseNormalizeWithoutDatedQueries() throws {
        for base in ["https://resource.openai.azure.com", "https://resource.openai.azure.com/", "https://resource.openai.azure.com/openai/v1", "https://resource.openai.azure.com/openai/v1/"] {
            XCTAssertEqual(try AzureRewrite.endpoint(base: base).absoluteString, "https://resource.openai.azure.com/openai/v1/chat/completions")
        }
        XCTAssertEqual(try AzureRewrite.endpoint(base: "http://127.0.0.1:1234/test/openai/v1").path, "/test/openai/v1/chat/completions")
        for base in ["https://resource.openai.azure.com/openai/deployments/old", "https://resource.openai.azure.com/v1", "https://resource.openai.azure.com/openai/v1?api-version=2024-10-21", "http://remote.example.org/openai/v1", "https://user:key@resource.openai.azure.com/openai/v1", "https://resource.openai.azure.com/#fragment"] {
            XCTAssertThrowsError(try AzureRewrite.endpoint(base: base))
        }
    }
    func testRequestKeepsDeploymentInJSONAndKeyOnlyInHeader() throws {
        let request = try AzureRewrite.request(text: "Do not ship.\n€12.50", instruction: "Clean up.", base: "https://resource.openai.azure.com", deployment: "my-deployment", key: "synthetic-key")
        XCTAssertEqual(request.url?.path, "/openai/v1/chat/completions"); XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "synthetic-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-api-key"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "my-deployment"); XCTAssertEqual(body["max_completion_tokens"] as? Int, 4096)
        XCTAssertEqual(body["n"] as? Int, 1); XCTAssertEqual(body["store"] as? Bool, false); XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertNil(body["temperature"]); XCTAssertNil(body["tools"]); XCTAssertNil(body["max_tokens"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 2); XCTAssertEqual(messages[1], ["role": "user", "content": "Do not ship.\n€12.50"])
        XCTAssertEqual(messages[0]["role"], "system"); XCTAssertTrue(messages[0]["content"]?.hasSuffix("Clean up.") == true)
        // Deployment names are data, never interpolated into the URL.
        let unusual = try AzureRewrite.request(text: "public", instruction: "Clean", base: "https://resource.openai.azure.com", deployment: "custom/name?query", key: "test-key")
        XCTAssertEqual(unusual.url, request.url)
    }
    func testInvalidDeploymentOrHeaderCredentialCannotBuildRequest() {
        for deployment in ["", " ", " name", "name\n", "name\r\n", "name\0value", String(repeating: "x", count: 201)] {
            XCTAssertThrowsError(try AzureRewrite.request(text: "public", instruction: "Clean", base: "https://resource.openai.azure.com", deployment: deployment, key: "test-key"))
        }
        for key in ["", "test key", "test\tkey", "key\r\nInjected: header", "ékey"] {
            XCTAssertThrowsError(try AzureRewrite.request(text: "public", instruction: "Clean", base: "https://resource.openai.azure.com", deployment: "test-deployment", key: key))
        }
    }
    func testCompleteAssistantTextPreservesUnicodeAndWhitespace() throws {
        XCTAssertEqual(try AzureRewrite.text(from: response(text: "  café\n不要发布。\n", messageFields: ["refusal": NSNull(), "tool_calls": [], "reasoning_content": "PRIVATE THOUGHT"])), "  café\n不要发布。\n")
    }
    func testIncompleteAmbiguousWrongRoleAndMissingTextAreNotDelivered() {
        for reason in ["length", "content_filter", "tool_calls", "function_call", "", "unknown"] {
            XCTAssertThrowsError(try AzureRewrite.text(from: response(finish: reason)))
        }
        for fields: [String: Any] in [["role": "system"], ["content": NSNull()], ["content": " \n"], ["content": [["type": "text", "text": "partial"]]]] {
            XCTAssertThrowsError(try AzureRewrite.text(from: response(messageFields: fields)))
        }
        for fields: [String: Any] in [["index": 1], ["index": NSNull()], ["finish_reason": NSNull()]] {
            XCTAssertThrowsError(try AzureRewrite.text(from: response(choiceFields: fields)))
        }
        for malformed: [String: Any] in [[:], ["choices": []], ["choices": [["finish_reason": "stop"]]], ["choices": [["index": 0], ["index": 1]]]] {
            XCTAssertThrowsError(try AzureRewrite.text(from: malformed))
        }
    }
    func testRefusalToolFunctionAndAudioResponsesCannotReplaceOriginal() {
        let cases: [[String: Any]] = [["refusal": "PRIVATE REFUSAL"], ["tool_calls": [["function": ["name": "fake"]]]], ["function_call": ["name": "fake"]], ["audio": ["data": "fake"]]]
        for fields in cases {
            XCTAssertThrowsError(try AzureRewrite.text(from: response(messageFields: fields))) { error in
                XCTAssertFalse(error.localizedDescription.contains("PRIVATE"))
            }
        }
    }
    func testPromptOrCandidateFilteredContentIsRejectedEvenWithStop() throws {
        var prompt = response(); prompt["prompt_filter_results"] = [["prompt_index": 0, "content_filter_results": ["hate": ["filtered": true, "severity": "high"]]]]
        XCTAssertThrowsError(try AzureRewrite.text(from: prompt))
        let candidate = response(choiceFields: ["content_filter_results": ["nested": [["filtered": true]]]])
        XCTAssertThrowsError(try AzureRewrite.text(from: candidate))
        XCTAssertEqual(try AzureRewrite.text(from: response(choiceFields: ["content_filter_results": ["hate": ["filtered": false, "severity": "safe"]]])), "Edited passage.")
    }
    func testSettingsAndCredentialScopeSupportResourceRootAndDeployment() throws {
        var settings = OSprSettings(); XCTAssertEqual(settings.rewriteProvider, "none")
        settings.rewriteProvider = "azure"; settings.rewriteURL = "https://resource.openai.azure.com"; settings.rewriteModel = "deployment-name"
        XCTAssertEqual(try JSONDecoder().decode(OSprSettings.self, from: JSONEncoder().encode(settings)), settings)
        let scope = ProviderCredentialScope(kind: .rewrite, base: settings.rewriteURL)
        XCTAssertEqual(scope, ProviderCredentialScope(kind: .rewrite, base: settings.rewriteURL + "/openai/v1"))
        XCTAssertThrowsError(try ProviderCredentialScope.checkedKey("test-key", boundTo: scope, kind: .rewrite, base: "https://other.openai.azure.com"))
        XCTAssertThrowsError(try ProviderCredentialScope.checkedKey("test-key", boundTo: scope, kind: .transcription, base: settings.rewriteURL))
    }
}
