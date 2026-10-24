import Foundation
import AVFoundation
import CryptoKit

/// A single outer range on the exact normalized ASR timeline. Interior pauses
/// are retained. Empty means detector abstention, not proof of absent speech.
public struct NeuralSpeechEdges: Codable, Sendable, Equatable {
    public let method: String
    public let sample_rate: Int
    public let audio_samples: Int
    public let pcm_sha256: String
    public let start_sample: Int
    public let end_sample: Int
    public var dictionary: [String: Any] {
        ["method": method, "sample_rate": sample_rate, "audio_samples": audio_samples,
         "pcm_sha256": pcm_sha256, "start_sample": start_sample, "end_sample": end_sample]
    }

    /// Cache-only model validation and bounded streaming file analysis. No
    /// resampling: ranges must describe the worker's float32 array exactly.
    public static func analyze(audioURL: URL, modelURL: URL) throws -> Self {
        try Task.checkCancellation()
        try NativeSpeechAsset.validate(modelURL)
        let detector = try CoreMLSpeechDetector(modelURL: modelURL, computeUnits: .cpuOnly)
        guard detector.chunkSamples == 512 else { throw OSprError.message("Neural edges require the pinned 32 ms detector.") }
        return try scan(audioURL: audioURL) { try detector.predict($0) }
    }

    /// Injectable prediction lets tests exercise actual file traversal, frame
    /// boundaries, hashes and cancellation without synthetic model weights.
    static func scan(audioURL: URL, predict: (ArraySlice<Float>) throws -> Double) throws -> Self {
        let file = try AVAudioFile(forReading: audioURL)
        let format = file.fileFormat
        let total = Int(file.length)
        guard format.sampleRate == 16_000, format.channelCount == 1,
              format.commonFormat == .pcmFormatFloat32, total > 0, total <= 4 * 3600 * 16_000,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else {
            throw OSprError.message("Neural edges require a normalized 16 kHz mono float32 WAV of at most four hours.")
        }
        var digest = SHA256()
        var scoring = try CausalSpeechScore()
        var frame = [Float](); frame.reserveCapacity(512)
        var consumed = 0, observed = 0
        var first: Int?, last: Int?
        func observe() throws {
            try Task.checkCancellation()
            let score = try scoring.consume(predict(frame[...]))
            if score >= 0.5 && first == nil { first = observed }
            if score >= 0.35 { last = observed + frame.count }
            observed += frame.count
            frame.removeAll(keepingCapacity: true)
        }
        while consumed < total {
            try Task.checkCancellation()
            let requested = min(8192, total - consumed)
            try file.read(into: buffer, frameCount: AVAudioFrameCount(requested))
            guard buffer.frameLength > 0, buffer.frameLength <= requested, let channel = buffer.floatChannelData else {
                throw OSprError.message("Neural edge input ended before its declared sample count.")
            }
            let values = UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength))
            guard values.allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else {
                throw OSprError.message("Neural edge input contains non-normalized samples.")
            }
            // Supported Macs are little endian. Hash the float bits including
            // signed zero, matching NumPy's explicit <f4 byte contract.
            digest.update(bufferPointer: UnsafeRawBufferPointer(values))
            for value in values {
                frame.append(value)
                if frame.count == 512 { try observe() }
            }
            consumed += values.count
        }
        if !frame.isEmpty { try observe() }
        guard observed == total else { throw OSprError.message("Neural edges did not examine the complete input.") }
        let start = first.map { max(0, $0 - 2560) } ?? 0
        let end = first == nil ? 0 : min(total, (last ?? total) + 2560)
        return Self(method: "silero-causal8-v1", sample_rate: 16_000, audio_samples: total,
                    pcm_sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
                    start_sample: start, end_sample: end)
    }
}

/// Shared app/CLI path. Normalize once into private storage, analyze those exact
/// samples natively, then require the worker to verify them before recognition.
public enum NeuralEdgeTranscription {
    public static func run(source: URL, request: [String: Any], worker: WorkerClient) async throws -> [String: Any] {
        try await run(source: source, request: request, send: { try await worker.request($0) }, analyze: { audio, model in
            let task = Task.detached(priority: .userInitiated) { try NeuralSpeechEdges.analyze(audioURL: audio, modelURL: model) }
            return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        })
    }
    static func run(source: URL, request: [String: Any],
                    send: ([String: Any]) async throws -> [String: Any],
                    analyze: (URL, URL) async throws -> NeuralSpeechEdges) async throws -> [String: Any] {
        guard ["transcribe", "meeting"].contains(request["action"] as? String ?? "") else {
            throw OSprError.message("Neural edge analysis supports only local recognition.")
        }
        let workspace = try ProviderUploadWorkspace()
        defer { workspace.close() }
        try Task.checkCancellation()
        let prepared = try await send(["action": "prepare_speech_detector"])
        guard let model = prepared["model_path"] as? String, model.hasPrefix("/"), prepared["complete"] as? Bool == true else {
            throw OSprError.message("Prepare the speech detector in Models before using neural edge trimming.")
        }
        try Task.checkCancellation()
        let normalized = workspace.url.appendingPathComponent("normalized.wav")
        let normalization = try await send(["action": "prepare_review", "path": source.path,
                                            "output": normalized.path, "limit_bytes": 8 * 1024 * 1024 * 1024])
        try Task.checkCancellation()
        let edges = try await analyze(normalized, URL(fileURLWithPath: model))
        guard normalization["normalized_samples"] as? Int == edges.audio_samples,
              normalization["pcm_sha256"] as? String == edges.pcm_sha256 else {
            throw OSprError.message("Normalized audio changed during neural edge analysis. The source is kept for retry.")
        }
        try Task.checkCancellation()
        var body = request
        body["path"] = normalized.path; body["trim"] = false; body["speech_edges"] = edges.dictionary
        return try await send(body)
    }
}
