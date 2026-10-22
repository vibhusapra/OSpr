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
    func testAnonymousLocalTranscriptionOmitsAuthorization() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("RIFF-public-fixture".utf8).write(to: file)
        let result = try await ProviderClient.transcribe(file: file, base: base.replacingOccurrences(of: "/v1", with: "/anonymous"), model: "test", key: "", language: "en", vocabulary: "")
        XCTAssertEqual(result["text"] as? String, "A test recording.")
    }
    private func plan(in workspace: ProviderUploadWorkspace) throws -> ProviderUploadPlan {
        var parts: [[String: Any]] = []
        for index in 0..<2 {
            let file = workspace.url.appendingPathComponent(String(format: "part-%04d.wav", index))
            try Data("PART-\(index)".utf8).write(to: file)
            parts.append(["path": file.path, "start_frame": index * 16000, "frames": index == 0 ? 16000 : 8000])
        }
        return try ProviderUploadPlan(["sample_rate": 16000, "frames": 24000, "parts": parts], directory: workspace.url)
    }
    func testMultipartPlanPreservesRepetitionsAndOffsetsProviderTimes() async throws {
        let workspace = try ProviderUploadWorkspace(); defer { workspace.close() }
        let result = try await ProviderClient.transcribe(plan: plan(in: workspace), base: base.replacingOccurrences(of: "/v1", with: "/parts"), model: "test", key: "test-key", language: "en", vocabulary: "OSpr")
        XCTAssertEqual(result["text"] as? String, "Keep repeated phrase.\nKeep repeated phrase.")
        XCTAssertEqual(result["audio_seconds"] as? Double, 1.5)
        XCTAssertEqual(result["upload_parts"] as? Int, 2)
        let segments = try XCTUnwrap(result["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(try XCTUnwrap(segments[1]["start"] as? Double), 1.1, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(segments[1]["end"] as? Double), 1.4, accuracy: 0.00001)
        let words = try XCTUnwrap(result["words"] as? [[String: Any]])
        XCTAssertEqual(words[1]["text"] as? String, "Keep")
        XCTAssertEqual(try XCTUnwrap(words[1]["start"] as? Double), 1.1, accuracy: 0.00001)
    }
    func testInvalidProviderTimesUseCoarseBoundariesWithoutInventingWords() async throws {
        let workspace = try ProviderUploadWorkspace(); defer { workspace.close() }
        let result = try await ProviderClient.transcribe(plan: plan(in: workspace), base: base.replacingOccurrences(of: "/v1", with: "/parts-badtiming"), model: "test", key: "test-key", language: "en", vocabulary: "")
        let segments = try XCTUnwrap(result["segments"] as? [[String: Any]])
        XCTAssertEqual(segments[1]["start"] as? Double, 1)
        XCTAssertEqual(segments[1]["end"] as? Double, 1.5)
        XCTAssertNil(result["words"])
        XCTAssertEqual(result["timestamp_source"] as? String, "provider-or-coarse-upload-part")
    }
    func testSecondPartFailureDoesNotReturnPartialTranscriptOrProviderBody() async throws {
        let workspace = try ProviderUploadWorkspace(); defer { workspace.close() }
        do {
            _ = try await ProviderClient.transcribe(plan: plan(in: workspace), base: base.replacingOccurrences(of: "/v1", with: "/parts-fail"), model: "test", key: "test-key", language: "en", vocabulary: "")
            XCTFail("Failed part must prevent a completed result")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP 503"))
            XCTAssertFalse(error.localizedDescription.contains("PRIVATE INPUT"))
            XCTAssertFalse(error.localizedDescription.contains("Keep repeated phrase"))
        }
    }
    func testCancelDuringSecondPartStopsWaitingAndNeverReturnsPartialTranscript() async throws {
        let workspace = try ProviderUploadWorkspace(); defer { workspace.close() }
        let prepared = try plan(in: workspace), endpoint = base.replacingOccurrences(of: "/v1", with: "/parts-slow")
        let task = Task { try await ProviderClient.transcribe(plan: prepared, base: endpoint, model: "test", key: "test-key", language: "en", vocabulary: "") }
        try await Task.sleep(for: .milliseconds(100)); let started = ContinuousClock.now; task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled upload must throw") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
    }
    func testMultipartOverheadIsIncludedInTransportLimit() async throws {
        let workspace = try ProviderUploadWorkspace(); defer { workspace.close() }
        let file = workspace.url.appendingPathComponent("near-limit.wav")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(ProviderClient.maximumUploadBytes - 1)); try handle.close()
        do {
            _ = try await ProviderClient.transcribe(file: file, base: base, model: "test", key: "test-key", language: "en", vocabulary: "")
            XCTFail("Multipart framing must not take the request over its size limit")
        } catch { XCTAssertTrue(error.localizedDescription.contains("multipart request exceeds 25 MB")) }
    }
}
