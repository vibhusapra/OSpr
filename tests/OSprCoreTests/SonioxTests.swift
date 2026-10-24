import XCTest
@testable import OSprCore

final class SonioxTests: XCTestCase {
    private var process: Process!
    private var origin: String!
    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", root.appendingPathComponent("backend/tests/soniox_stub.py").path]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        var line = Data()
        while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte[0] == 10 { break }; line.append(byte)
        }
        guard let port = String(data: line, encoding: .utf8), Int(port) != nil else { throw OSprError.message("Stub failed to start") }
        origin = "http://127.0.0.1:\(port)"
    }
    override func tearDown() { process?.terminate(); process?.waitUntilExit(); process = nil }
    private func audio() throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data("RIFF-public-Soniox-fixture".utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }; return file
    }
    private func stats(_ mode: String) async throws -> [String: Any] {
        try await ProviderClient.send(URLRequest(url: URL(string: origin + "/\(mode)/v1/stats")!))
    }
    private func requests(_ value: [String: Any]) -> [[String: Any]] { value["requests"] as? [[String: Any]] ?? [] }
    private func transcribe(_ mode: String, language: String = "", vocabulary: String = "", policy: SonioxSpeech.Policy = .init(pollInterval: .milliseconds(2))) async throws -> [String: Any] {
        try await SonioxSpeech.transcribe(file: audio(), base: origin + "/\(mode)/v1", model: "stt-async-v5", key: "test-key", language: language, vocabulary: vocabulary, policy: policy)
    }

    func testFilesJobsPollingTokenWordsHintsAnd204Cleanup() async throws {
        let result = try await transcribe("hints", language: "en,hi", vocabulary: "OSpr,C++\nnaïve café")
        XCTAssertEqual(result["text"] as? String, "Hello world.")
        XCTAssertEqual(result["audio_seconds"] as? Double, 1)
        XCTAssertEqual(result["language"] as? String, "en")
        XCTAssertEqual(result["timestamp_source"] as? String, "provider-token-grouped-words")
        let words = try XCTUnwrap(result["words"] as? [[String: Any]])
        XCTAssertEqual(words.map { $0["text"] as? String }, ["Hello", "world."])
        XCTAssertEqual(try XCTUnwrap(words[0]["start"] as? Double), 0.01, accuracy: 1e-8)
        let observed = try await stats("hints")
        XCTAssertTrue((observed["files"] as? [String: Any])?.isEmpty == true)
        XCTAssertTrue((observed["jobs"] as? [String: Any])?.isEmpty == true)
        XCTAssertEqual(requests(observed).filter { $0["method"] as? String == "DELETE" }.count, 2)
    }
    func testAutomaticLanguageOmitsHintsAndNonRequestedFeatures() async throws {
        let result = try await transcribe("auto")
        XCTAssertEqual(result["text"] as? String, "Hello world.")
        XCTAssertNil(result["warning"])
    }
    func testPublicProviderDispatchAndPartAssemblyKeepRepetitionsAndOffsets() async throws {
        let workspace = try ProviderUploadWorkspace(); defer { workspace.close() }
        var parts: [[String: Any]] = []
        for index in 0..<2 {
            let file = workspace.url.appendingPathComponent(String(format: "part-%04d.wav", index))
            try Data("RIFF-public-part".utf8).write(to: file)
            parts.append(["path": file.path, "start_frame": index * 16000, "frames": 16000])
        }
        let plan = try ProviderUploadPlan(["sample_rate": 16000, "frames": 32000, "parts": parts], directory: workspace.url)
        let result = try await ProviderClient.transcribe(plan: plan, base: origin + "/auto/v1", model: "stt-async-v5", key: "test-key", language: "", vocabulary: "", provider: "soniox")
        XCTAssertEqual(result["text"] as? String, "Hello world.\nHello world.")
        let words = try XCTUnwrap(result["words"] as? [[String: Any]])
        XCTAssertEqual(try XCTUnwrap(words[2]["start"] as? Double), 1.01, accuracy: 1e-8)
        let observed = try await stats("auto")
        XCTAssertTrue((observed["files"] as? [String: Any])?.isEmpty == true)
    }
    func testMalformedTimingUsesCoarseBoundsWithoutInventingWords() async throws {
        let result = try await transcribe("bad-timing")
        XCTAssertNil(result["words"])
        XCTAssertEqual(result["timestamp_source"] as? String, "coarse-upload-part")
        XCTAssertEqual(result["text"] as? String, "Hello world.")
    }
    func testRejectedCreationCleansUploadedFileAndSanitizesProviderBody() async throws {
        do { _ = try await transcribe("create-error"); XCTFail("Expected HTTP failure") }
        catch { XCTAssertFalse(error.localizedDescription.contains("PRIVATE INPUT")); XCTAssertTrue(error.localizedDescription.contains("422")) }
        let observed = try await stats("create-error")
        XCTAssertTrue((observed["files"] as? [String: Any])?.isEmpty == true)
    }
    func testJobErrorCleansBothResourcesAndNeverReturnsPartialText() async throws {
        do { _ = try await transcribe("job-error"); XCTFail("Expected failed job") }
        catch { XCTAssertFalse(error.localizedDescription.contains("PRIVATE INPUT")) }
        let observed = try await stats("job-error")
        XCTAssertTrue((observed["files"] as? [String: Any])?.isEmpty == true)
        XCTAssertTrue((observed["jobs"] as? [String: Any])?.isEmpty == true)
    }
    func testCleanupFailureKeepsCompleteTextAndReportsOwnedResourceIDs() async throws {
        let result = try await transcribe("cleanup-error")
        XCTAssertEqual(result["text"] as? String, "Hello world.")
        let warning = try XCTUnwrap(result["warning"] as? String)
        XCTAssertTrue(warning.contains("cleanup is incomplete")); XCTAssertFalse(warning.contains("PRIVATE INPUT"))
    }
    func testDeadlineDoesNotWaitIndefinitelyAndDisclosesPendingProcessingResources() async throws {
        do { _ = try await transcribe("pending", policy: .init(pollInterval: .milliseconds(2), deadline: .milliseconds(200))); XCTFail("Expected deadline") }
        catch { XCTAssertTrue(error.localizedDescription.contains("cleanup is incomplete")) }
        let observed = try await stats("pending")
        XCTAssertFalse((observed["files"] as? [String: Any])?.isEmpty == true)
        XCTAssertFalse(requests(observed).contains { $0["method"] as? String == "DELETE" && ($0["path"] as? String)?.contains("/files/") == true })
    }
    func testCancellationStopsSlowPollingAndDoesNotDeleteFileUnderProcessingJob() async throws {
        let task = Task { try await transcribe("slow") }
        for _ in 0..<100 {
            let observed = try await stats("slow")
            if requests(observed).contains(where: { $0["method"] as? String == "GET" && ($0["path"] as? String)?.contains("/transcriptions/") == true }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let began = ContinuousClock.now; task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(began.duration(to: .now), .seconds(3))
        let observed = try await stats("slow")
        XCTAssertFalse(requests(observed).contains { $0["method"] as? String == "DELETE" && ($0["path"] as? String)?.contains("/files/") == true })
    }
    func testInvalidRemoteIDsCannotBecomeDeletePathsAndRedirectDoesNotForwardKey() async throws {
        for mode in ["bad-id", "redirect"] {
            do { _ = try await transcribe(mode); XCTFail("Expected rejection") } catch {}
            let observed = try await stats(mode)
            XCTAssertFalse(requests(observed).contains { ($0["path"] as? String)?.contains("/trap/") == true || ($0["path"] as? String)?.contains("..") == true })
        }
    }
    func testModelAndMultipartBudgetsFailBeforeAnyUpload() async throws {
        let file = try audio()
        for model in ["", "stt-rt-v5", String(repeating: "stt-async-", count: 10)] {
            do { _ = try await SonioxSpeech.transcribe(file: file, base: origin + "/auto/v1", model: model, key: "test-key", language: "", vocabulary: ""); XCTFail("Expected model rejection") } catch {}
        }
        let handle = try FileHandle(forWritingTo: file); try handle.truncate(atOffset: UInt64(ProviderClient.maximumUploadBytes - 1)); try handle.close()
        do { _ = try await transcribeFile(file); XCTFail("Expected framing rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("multipart")) }
        let observed = try await stats("auto")
        XCTAssertFalse(requests(observed).contains { $0["method"] as? String == "POST" })
    }
    private func transcribeFile(_ file: URL) async throws -> [String: Any] {
        try await SonioxSpeech.transcribe(file: file, base: origin + "/auto/v1", model: "stt-async-v5", key: "test-key", language: "", vocabulary: "")
    }

    func testMissingKeyIsRejectedBeforeUploading() async throws {
        do {
            _ = try await SonioxSpeech.transcribe(file: audio(), base: origin + "/auto/v1", model: "stt-async-v5", key: "", language: "", vocabulary: "")
            XCTFail("Missing credential must fail before sending audio")
        } catch { XCTAssertTrue(error.localizedDescription.contains("API key")) }
        let observed = try await stats("auto")
        XCTAssertFalse(requests(observed).contains { $0["method"] as? String == "POST" })
    }

    func testMultiwordTokenAndReconstructionMismatchNeverInventWordAlignment() throws {
        let state: [String: Any] = ["audio_duration_ms": 1000]
        for (text, fragment) in [("Hello world.", "Hello world."), ("Hello world.", "Hello")] {
            let result = try SonioxSpeech.normalized(["text": text, "tokens": [["text": fragment, "start_ms": 0, "end_ms": 750, "confidence": 1.0]]], state: state, model: "stt-async-v5", language: "")
            XCTAssertEqual(result["text"] as? String, text)
            XCTAssertNil(result["words"])
        }
    }

    func testInvalidDurationsAreRejectedRatherThanCoerced() {
        for duration: Any in [true, -1, Double.infinity, 20_000_000, "1000"] {
            XCTAssertThrowsError(try SonioxSpeech.normalized(["text": "Hello", "tokens": []], state: ["audio_duration_ms": duration], model: "stt-async-v5", language: ""))
        }
    }

    func testMultilingualSubwordGroupingPreservesTextAndProviderBounds() throws {
        let text = "नमस्ते world."
        let result = try SonioxSpeech.normalized(["text": text, "tokens": [
            ["text": "नमस्ते", "start_ms": 10, "end_ms": 200, "confidence": 0.9, "language": "hi"],
            ["text": " ", "start_ms": 200, "end_ms": 210, "confidence": 1.0, "language": "hi"],
            ["text": "world.", "start_ms": 300, "end_ms": 800, "confidence": 0.9, "language": "en"]
        ]], state: ["audio_duration_ms": 1000], model: "stt-async-v5", language: "")
        XCTAssertEqual(result["text"] as? String, text)
        XCTAssertEqual(result["language"] as? String, "mul")
        let words = try XCTUnwrap(result["words"] as? [[String: Any]])
        XCTAssertEqual(words.map { $0["text"] as? String }, ["नमस्ते", "world."])
        XCTAssertEqual(words[1]["end"] as? Double, 0.8)
    }

    func testAmbiguousCreationFailurePreservesFileAndDisclosesCleanupState() async throws {
        do { _ = try await transcribe("create-server-error"); XCTFail("Expected server failure") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP 503"))
            XCTAssertTrue(error.localizedDescription.contains("cleanup is incomplete"))
            XCTAssertFalse(error.localizedDescription.contains("PRIVATE INPUT"))
        }
        let observed = try await stats("create-server-error")
        XCTAssertFalse((observed["files"] as? [String: Any])?.isEmpty == true)
        XCTAssertFalse(requests(observed).contains { $0["method"] as? String == "DELETE" })
    }

    func testPartAssemblyPreservesCleanupWarningsForEveryCompletedJob() async throws {
        let workspace = try ProviderUploadWorkspace(); defer { workspace.close() }
        let file = workspace.url.appendingPathComponent("part-0000.wav")
        try Data("RIFF-public-part".utf8).write(to: file)
        let plan = try ProviderUploadPlan(["sample_rate": 16000, "frames": 16000,
            "parts": [["path": file.path, "start_frame": 0, "frames": 16000]]], directory: workspace.url)
        let result = try await ProviderClient.transcribe(plan: plan, base: origin + "/cleanup-error/v1", model: "stt-async-v5", key: "test-key", language: "", vocabulary: "", provider: "soniox")
        XCTAssertEqual(result["text"] as? String, "Hello world.")
        XCTAssertTrue((result["warning"] as? String)?.contains("cleanup is incomplete") == true)
    }

    func testDeadlineRacingRapidPollingNeverCreatesTaskInClosedSession() async throws {
        for _ in 0..<12 {
            do {
                _ = try await transcribe("pending", policy: .init(pollInterval: .milliseconds(1), deadline: .milliseconds(12)))
                XCTFail("Expected deadline")
            } catch { XCTAssertFalse(error.localizedDescription.contains("PRIVATE INPUT")) }
        }
    }
}
