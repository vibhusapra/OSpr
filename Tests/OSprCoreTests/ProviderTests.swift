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
    private func deepgramFixture() throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data("RIFF-public-fixture".utf8).write(to: file)
        return file
    }
    func testDeepgramBinaryAuthVocabularyAndExplicitLanguageContract() async throws {
        let file = try deepgramFixture(); defer { try? FileManager.default.removeItem(at: file) }
        let result = try await ProviderClient.transcribe(file: file, base: base.replacingOccurrences(of: "/v1", with: "/deepgram-hints"), model: "nova-3", key: "test-key", language: "en", vocabulary: "OSpr, C++\nR&D\nnaïve café", provider: "deepgram")
        XCTAssertEqual(result["text"] as? String, "Keep repeated phrase.")
        XCTAssertEqual(result["audio_seconds"] as? Double, 1)
        XCTAssertEqual(result["timestamp_source"] as? String, "provider-utterances")
        XCTAssertEqual((result["words"] as? [[String: Any]])?.first?["text"] as? String, "Keep")
    }
    func testDeepgramBlankLanguageUsesDetectionInsteadOfEnglishDefault() async throws {
        let file = try deepgramFixture(); defer { try? FileManager.default.removeItem(at: file) }
        let result = try await ProviderClient.transcribe(file: file, base: base.replacingOccurrences(of: "/v1", with: "/deepgram-auto"), model: "nova-3", key: "test-key", language: "", vocabulary: "", provider: "deepgram")
        XCTAssertEqual(result["language"] as? String, "en")
    }
    func testDeepgramPlanPreservesRepeatedTextAndOffsetsEveryWord() async throws {
        let workspace = try ProviderUploadWorkspace(); defer { workspace.close() }
        let result = try await ProviderClient.transcribe(plan: plan(in: workspace), base: base.replacingOccurrences(of: "/v1", with: "/deepgram"), model: "nova-3", key: "test-key", language: "en", vocabulary: "", provider: "deepgram")
        XCTAssertEqual(result["text"] as? String, "Keep repeated phrase.\nKeep repeated phrase.")
        XCTAssertEqual(result["audio_seconds"] as? Double, 1.5)
        let words = try XCTUnwrap(result["words"] as? [[String: Any]])
        XCTAssertEqual(words.count, 2)
        XCTAssertEqual(try XCTUnwrap(words[1]["start"] as? Double), 1.1, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(words[1]["end"] as? Double), 1.4, accuracy: 0.000001)
    }
    func testDeepgramBadTimesKeepTextWithExplicitCoarsePartTiming() async throws {
        let workspace = try ProviderUploadWorkspace(); defer { workspace.close() }
        let result = try await ProviderClient.transcribe(plan: plan(in: workspace), base: base.replacingOccurrences(of: "/v1", with: "/deepgram-coarse"), model: "nova-3", key: "test-key", language: "en", vocabulary: "", provider: "deepgram")
        XCTAssertEqual(result["timestamp_source"] as? String, "provider-or-coarse-upload-part")
        XCTAssertNil(result["words"])
        let segments = try XCTUnwrap(result["segments"] as? [[String: Any]])
        XCTAssertEqual(segments[1]["start"] as? Double, 1)
        XCTAssertEqual(segments[1]["end"] as? Double, 1.5)
    }
    func testDeepgramLaterFailureDoesNotReturnPartialTextOrProviderErrorBody() async throws {
        let workspace = try ProviderUploadWorkspace(); defer { workspace.close() }
        do {
            _ = try await ProviderClient.transcribe(plan: plan(in: workspace), base: base.replacingOccurrences(of: "/v1", with: "/deepgram-fail"), model: "nova-3", key: "test-key", language: "en", vocabulary: "", provider: "deepgram")
            XCTFail("A later failed part must fail the complete request")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP 503"))
            XCTAssertFalse(error.localizedDescription.contains("PRIVATE INPUT"))
            XCTAssertFalse(error.localizedDescription.contains("Keep repeated phrase"))
        }
    }
    func testDeepgramCancellationDuringLaterPartStopsPromptly() async throws {
        let workspace = try ProviderUploadWorkspace(); defer { workspace.close() }
        let prepared = try plan(in: workspace), endpoint = base.replacingOccurrences(of: "/v1", with: "/deepgram-slow")
        let task = Task { try await ProviderClient.transcribe(plan: prepared, base: endpoint, model: "nova-3", key: "test-key", language: "en", vocabulary: "", provider: "deepgram") }
        try await Task.sleep(for: .milliseconds(100)); let began = ContinuousClock.now; task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled upload must fail") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertLessThan(began.duration(to: .now), .seconds(2))
    }
    func testDeepgramRejectsStreamingModelsUnsupportedHintsAndOversizedVocabularyLocally() async throws {
        let file = try deepgramFixture(); defer { try? FileManager.default.removeItem(at: file) }
        for (model, hints, message) in [("flux-general-en", "", "streaming API"), ("nova-2", "OSpr", "Nova-3"),
            ("nova-3", Array(repeating: "hint", count: 101).joined(separator: "\n"), "100"),
            ("nova-3", String(repeating: "😀", count: 5000), "too long")] {
            do {
                _ = try await ProviderClient.transcribe(file: file, base: base, model: model, key: "test-key", language: "en", vocabulary: hints, provider: "deepgram")
                XCTFail("Expected local validation failure")
            } catch { XCTAssertTrue(error.localizedDescription.contains(message), error.localizedDescription) }
        }
    }
    func testNativeSpeechRoutesCannotFallThroughToCompatibleOrInsecureEndpoints() {
        XCTAssertEqual(try ProviderClient.speechEndpoint(base: "https://api.deepgram.com/v1", provider: "deepgram").absoluteString, "https://api.deepgram.com/v1/listen")
        XCTAssertThrowsError(try ProviderClient.speechEndpoint(base: "https://example.com/v1", provider: "unsupported"))
        for base in ["http://remote.example/v1", "https://key:secret@example.com/v1", "https://example.com/v1?callback=other"] {
            XCTAssertThrowsError(try ProviderClient.speechEndpoint(base: base, provider: "deepgram"))
        }
    }
    private func deepgramResponse(duration: Any = 1.0, words: Any = []) -> [String: Any] {
        ["metadata": ["duration": duration], "results": ["channels": [["alternatives": [["transcript": "A public phrase.", "words": words]]]]]]
    }
    func testDeepgramMalformedResponsesFailWithoutIncludingPayloadText() {
        for duration: Any in [-1.0, Double.infinity, true, "PRIVATE INPUT", 14401.0] {
            XCTAssertThrowsError(try DeepgramSpeech.normalized(deepgramResponse(duration: duration), requestedModel: "nova-3", language: "en")) { error in
                XCTAssertFalse(error.localizedDescription.contains("PRIVATE INPUT"))
            }
        }
        var multiple = deepgramResponse()
        multiple["results"] = ["channels": [["alternatives": []], ["alternatives": []]]]
        XCTAssertThrowsError(try DeepgramSpeech.normalized(multiple, requestedModel: "nova-3", language: "en"))
    }
    func testDeepgramMalformedWordTimesAreOmittedWithoutLosingTranscript() throws {
        for end: Any in [true, Double.nan, -1.0, 99.0] {
            let response = deepgramResponse(words: [["word": "phrase", "start": 0.0, "end": end]])
            let result = try DeepgramSpeech.normalized(response, requestedModel: "nova-3", language: "en")
            XCTAssertEqual(result["text"] as? String, "A public phrase.")
            XCTAssertNil(result["words"])
            XCTAssertEqual(result["timestamp_source"] as? String, "coarse-upload-part")
        }
    }
    func testDeepgramEmptyOutputDoesNotInventSilenceAndDiscardRecovery() throws {
        let response: [String: Any] = ["metadata": ["duration": 1.0], "results": ["channels": [["alternatives": [["transcript": "", "words": []]]]]]]
        let result = try DeepgramSpeech.normalized(response, requestedModel: "nova-3", language: "en")
        XCTAssertEqual(result["text"] as? String, "")
        XCTAssertNil(result["silence"])
        XCTAssertTrue((result["segments"] as? [[String: Any]])?.isEmpty == true)
    }
}
