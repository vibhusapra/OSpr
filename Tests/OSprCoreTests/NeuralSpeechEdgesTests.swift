import XCTest
import AVFoundation
import CryptoKit
@testable import OSprCore

final class NeuralSpeechEdgesTests: XCTestCase {
    private func write(_ samples: [Float], rate: Double = 16_000, channels: AVAudioChannelCount = 1, pcm16: Bool = false) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        var settings = format.settings
        if pcm16 { settings[AVLinearPCMIsFloatKey] = false; settings[AVLinearPCMBitDepthKey] = 16 }
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if !samples.isEmpty {
            for channel in 0..<Int(channels) {
                samples.withUnsafeBufferPointer { buffer.floatChannelData![channel].update(from: $0.baseAddress!, count: $0.count) }
            }
            try file!.write(from: buffer)
        }
        file = nil; return url
    }
    func testFullStreamingTraversalPreservesFrameBoundariesBitsHashAndInteriorSilence() throws {
        var samples = (0..<230_913).map { Float(($0 % 1024) - 512) / 1024 }
        samples[0] = -Float.zero; samples[5] = Float.leastNonzeroMagnitude
        let url = try write(samples); defer { try? FileManager.default.removeItem(at: url) }
        var examined = [Float](), frameSizes = [Int](), probabilities = [Double]()
        let edges = try NeuralSpeechEdges.scan(audioURL: url) { frame in
            examined.append(contentsOf: frame); frameSizes.append(frame.count)
            let probability = [20, 300].contains(probabilities.count) ? 0.8 : 0.0
            probabilities.append(probability); return probability
        }
        XCTAssertEqual(examined.map(\.bitPattern), samples.map(\.bitPattern))
        XCTAssertEqual(frameSizes.dropLast().allSatisfy { $0 == 512 }, true)
        XCTAssertEqual(frameSizes.last, samples.count % 512)
        let expected = samples.withUnsafeBytes { SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(edges.pcm_sha256, expected); XCTAssertEqual(edges.audio_samples, samples.count)
        XCTAssertEqual(edges.start_sample, 20 * 512 - 2560)
        // The causal score persists seven more frames after the last peak.
        XCTAssertEqual(edges.end_sample, (300 + 8) * 512 + 2560)
        XCTAssertGreaterThan(edges.end_sample - edges.start_sample, 280 * 512)
    }
    func testFinalPartialAndOuterPaddingStayOnRealSampleTimeline() throws {
        let url = try write([Float](repeating: 0.01, count: 513)); defer { try? FileManager.default.removeItem(at: url) }
        var sizes = [Int]()
        let result = try NeuralSpeechEdges.scan(audioURL: url) { sizes.append($0.count); return 1 }
        XCTAssertEqual(sizes, [512, 1]); XCTAssertEqual(result.start_sample, 0); XCTAssertEqual(result.end_sample, 513)
    }
    func testWeakEvidenceNeverStartingSpeechReturnsExplicitAbstentionRange() throws {
        let url = try write([Float](repeating: 0.01, count: 20_000)); defer { try? FileManager.default.removeItem(at: url) }
        let result = try NeuralSpeechEdges.scan(audioURL: url) { _ in 0.05 }
        XCTAssertEqual(result.start_sample, 0); XCTAssertEqual(result.end_sample, 0)
        XCTAssertEqual(result.audio_samples, 20_000)
    }
    func testRejectsUnnormalizedFormatsAndSamplesInsteadOfConvertingThem() throws {
        let urls = try [write([0.1], rate: 48_000), write([0.1], channels: 2), write([0.1], pcm16: true),
                        write([]), write([.nan]), write([.infinity]), write([1.01])]
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        for url in urls { XCTAssertThrowsError(try NeuralSpeechEdges.scan(audioURL: url) { _ in XCTFail("Invalid input reached detector"); return 0 }) }
    }
    func testPredictionErrorAndInvalidProbabilityArePropagatedWithoutFallback() throws {
        let url = try write([Float](repeating: 0, count: 1024)); defer { try? FileManager.default.removeItem(at: url) }
        for score in [Double.nan, .infinity, -0.1, 1.1] {
            XCTAssertThrowsError(try NeuralSpeechEdges.scan(audioURL: url) { _ in score })
        }
        XCTAssertThrowsError(try NeuralSpeechEdges.scan(audioURL: url) { _ in throw OSprError.message("test prediction failure") })
    }
    func testStreamingAnalysisAcceptsLongerThanTheOldFiveMinuteReplayLimit() throws {
        let url = try write([Float](repeating: 0, count: 301 * 16_000 + 1)); defer { try? FileManager.default.removeItem(at: url) }
        var largest = 0, count = 0
        let result = try NeuralSpeechEdges.scan(audioURL: url) { largest = max(largest, $0.count); count += $0.count; return 0 }
        XCTAssertEqual(count, 301 * 16_000 + 1); XCTAssertEqual(largest, 512)
        XCTAssertEqual(result.audio_samples, count); XCTAssertEqual(result.end_sample, 0)
    }
    func testCancelledTaskStopsBeforePrediction() async throws {
        let url = try write([Float](repeating: 0, count: 1024)); defer { try? FileManager.default.removeItem(at: url) }
        try await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertThrowsError(try NeuralSpeechEdges.scan(audioURL: url) { _ in XCTFail("Cancelled scan reached inference"); return 0 }) {
                XCTAssertTrue($0 is CancellationError)
            }
        }.value
    }
    func testOrchestrationBindsExactAudioDisablesRMSAndCleansPrivateWorkspace() async throws {
        let source = try write([0.1, 0.2]); defer { try? FileManager.default.removeItem(at: source) }
        let original = try Data(contentsOf: source)
        var actions = [String](), temporary: URL?
        let result = try await NeuralEdgeTranscription.run(source: source, request: ["action": "transcribe", "model": "whisper-turbo", "trim": true], send: { body in
            let action = body["action"] as! String; actions.append(action)
            if action == "prepare_speech_detector" { return ["model_path": "/fixture/model", "complete": true] }
            if action == "prepare_review" {
                temporary = URL(fileURLWithPath: body["output"] as! String)
                try original.write(to: temporary!)
                return ["normalized_samples": 2, "pcm_sha256": "fixture-sha"]
            }
            XCTAssertEqual(body["trim"] as? Bool, false); XCTAssertEqual(body["model"] as? String, "whisper-turbo")
            XCTAssertEqual(body["path"] as? String, temporary?.path)
            let edges = body["speech_edges"] as! [String: Any]
            XCTAssertEqual(edges["pcm_sha256"] as? String, "fixture-sha")
            XCTAssertTrue(FileManager.default.fileExists(atPath: temporary!.path))
            return ["text": "fixture result"]
        }, analyze: { audio, _ in
            XCTAssertEqual(audio, temporary)
            return NeuralSpeechEdges(method: "silero-causal8-v1", sample_rate: 16000, audio_samples: 2,
                                     pcm_sha256: "fixture-sha", start_sample: 0, end_sample: 2)
        })
        XCTAssertEqual(actions, ["prepare_speech_detector", "prepare_review", "transcribe"])
        XCTAssertEqual(result["text"] as? String, "fixture result")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary!.deletingLastPathComponent().path))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testChangedNormalizedAudioNeverReachesRecognitionAndIsCleaned() async throws {
        var temporary: URL?, actions = [String]()
        do {
            _ = try await NeuralEdgeTranscription.run(source: URL(fileURLWithPath: "/fixture/source"), request: ["action": "meeting"], send: { body in
                let action = body["action"] as! String; actions.append(action)
                if action == "prepare_speech_detector" { return ["model_path": "/fixture/model", "complete": true] }
                XCTAssertEqual(action, "prepare_review")
                temporary = URL(fileURLWithPath: body["output"] as! String)
                try Data("owned transient fixture".utf8).write(to: temporary!)
                return ["normalized_samples": 2, "pcm_sha256": "expected"]
            }, analyze: { _, _ in .init(method: "silero-causal8-v1", sample_rate: 16000, audio_samples: 2,
                                         pcm_sha256: "changed", start_sample: 0, end_sample: 2) })
            XCTFail("Changed audio was accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        XCTAssertEqual(actions, ["prepare_speech_detector", "prepare_review"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary!.deletingLastPathComponent().path))
    }
    func testRecognitionFailureCleansTransientAudioAndDoesNotRetryAnotherRoute() async throws {
        var temporary: URL?, actions = [String]()
        do {
            _ = try await NeuralEdgeTranscription.run(source: URL(fileURLWithPath: "/fixture/source"), request: ["action": "transcribe"], send: { body in
                let action = body["action"] as! String; actions.append(action)
                if action == "prepare_speech_detector" { return ["model_path": "/fixture/model", "complete": true] }
                if action == "prepare_review" {
                    temporary = URL(fileURLWithPath: body["output"] as! String)
                    try Data("owned transient fixture".utf8).write(to: temporary!)
                    return ["normalized_samples": 1, "pcm_sha256": "fixture"]
                }
                throw OSprError.message("test recognizer failure")
            }, analyze: { _, _ in .init(method: "silero-causal8-v1", sample_rate: 16000, audio_samples: 1,
                                         pcm_sha256: "fixture", start_sample: 0, end_sample: 1) })
            XCTFail("Recognition error was hidden")
        } catch { XCTAssertTrue(error.localizedDescription.contains("recognizer failure")) }
        XCTAssertEqual(actions, ["prepare_speech_detector", "prepare_review", "transcribe"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary!.deletingLastPathComponent().path))
    }
    func testMissingModelAndCancellationStopBeforeAudioPreparation() async throws {
        var actions = [String]()
        do {
            _ = try await NeuralEdgeTranscription.run(source: URL(fileURLWithPath: "/fixture/source"), request: ["action": "transcribe"], send: { body in
                actions.append(body["action"] as! String)
                return ["complete": false]
            }, analyze: { _, _ in XCTFail("Missing model reached analysis"); throw CancellationError() })
            XCTFail("Missing model was accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Models")) }
        XCTAssertEqual(actions, ["prepare_speech_detector"])
        try await Task {
            var actions = [String]()
            do {
                _ = try await NeuralEdgeTranscription.run(source: URL(fileURLWithPath: "/fixture/source"), request: ["action": "transcribe"], send: { body in
                    actions.append(body["action"] as! String)
                    withUnsafeCurrentTask { $0?.cancel() }
                    return ["model_path": "/fixture/model", "complete": true]
                }, analyze: { _, _ in XCTFail("Cancelled request reached analysis"); throw CancellationError() })
                XCTFail("Cancellation was ignored")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(actions, ["prepare_speech_detector"])
        }.value
    }
}
