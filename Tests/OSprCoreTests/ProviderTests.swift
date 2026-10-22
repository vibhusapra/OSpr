import XCTest
@testable import OSprCore

final class ProviderTests: XCTestCase {
    private var process: Process!
    private var base: String!
    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", root.appendingPathComponent("backend/tests/provider_stub.py").path]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        var line = Data()
        while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte[0] == 10 { break }; line.append(byte)
        }
        guard let port = String(data: line, encoding: .utf8), Int(port) != nil else { throw OSprError.message("Stub failed to start") }
        base = "http://127.0.0.1:\(port)/v1"
    }
    override func tearDown() { process?.terminate(); process?.waitUntilExit(); process = nil }
    func testCompatibleRewriteContract() async throws {
        let text = try await ProviderClient.rewrite(text: "test passage", instruction: "Clean up.", provider: "compatible", base: base, model: "test-model", key: "test-key")
        XCTAssertEqual(text, "Edited passage.")
    }
    func testCancellingProviderTaskStopsWaitingForSlowResponse() async throws {
        let endpoint = base.replacingOccurrences(of: "/v1", with: "/slow")
        let task = Task { try await ProviderClient.rewrite(text: "test passage", instruction: "Clean up.", provider: "compatible", base: endpoint, model: "test-model", key: "test-key") }
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled provider request must fail") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
    }
    func testAnthropicRewriteContract() async throws {
        let text = try await ProviderClient.rewrite(text: "test passage", instruction: "Clean up.", provider: "anthropic", base: base, model: "test-model", key: "test-key")
        XCTAssertEqual(text, "Edited passage.")
    }
    func testTranscriptionMultipartAndCurrentOpenAILanguageContract() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("RIFF-test-fixture".utf8).write(to: file)
        for model in ["whisper-large-v3-turbo", "gpt-transcribe"] {
            let result = try await ProviderClient.transcribe(file: file, base: base, model: model, key: "test-key", language: "en", vocabulary: "OSpr")
            XCTAssertEqual(result["text"] as? String, "A test recording.")
        }
    }
    func testProviderErrorsDoNotLeakInputAndRedirectsDoNotForwardKeys() async {
        for route in ["error", "redirect"] {
            do {
                _ = try await ProviderClient.rewrite(text: "test passage", instruction: "Clean up.", provider: "compatible", base: base.replacingOccurrences(of: "/v1", with: "/\(route)"), model: "test", key: "test-key")
                XCTFail("Expected error for \(route)")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("PRIVATE INPUT"))
                XCTAssertTrue(error.localizedDescription.contains("HTTP"))
            }
        }
    }
}
