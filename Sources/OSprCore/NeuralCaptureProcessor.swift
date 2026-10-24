import AVFoundation

protocol SpeechProbabilityModel: AnyObject {
    var chunkSamples: Int { get }
    func predict(_ samples: ArraySlice<Float>) throws -> Double
    func probe(_ samples: ArraySlice<Float>) throws -> Double
}
extension CoreMLSpeechDetector: SpeechProbabilityModel {}

public struct LiveSpeechObservation: Equatable {
    public let normalizedSamples: Int
    public let incompleteFrameSamples: Int
    public let hasSpeech: Bool
    public let candidate: SpeechEndpoint.Event?
}

/// Serial inference state. Continuous resampling and complete 512-sample model
/// frames commit exactly once. A partial tail probes copies of recurrent,
/// scoring and endpoint state so the latest received block can be examined
/// without inserting artificial padding into the continuing stream.
final class NeuralCaptureProcessor {
    private let resampler: StreamingSpeechResampler
    private let model: any SpeechProbabilityModel
    private var score: CausalSpeechScore
    private var endpoint: LiveSpeechEndpoint
    private var frame = [Float](repeating: 0, count: 512)
    private var pending = 0
    private var committed = 0
    init(sampleRate: Double, model: any SpeechProbabilityModel, silenceSeconds: Double) throws {
        guard model.chunkSamples == 512 else { throw OSprError.message("Live speech detection requires the pinned 32 ms model.") }
        self.model = model; resampler = try StreamingSpeechResampler(sampleRate: sampleRate)
        score = try CausalSpeechScore(windowFrames: 8)
        endpoint = LiveSpeechEndpoint(configuration: try .init(silenceSeconds: silenceSeconds))
    }
    func process(_ input: AVAudioPCMBuffer) throws -> LiveSpeechObservation {
        try resampler.process(input) { try append($0) }
        return try observation()
    }
    func finish() throws -> LiveSpeechObservation {
        try resampler.finish { try append($0) }
        return try observation()
    }
    private func append(_ samples: UnsafeBufferPointer<Float>) throws {
        var offset = 0
        while offset < samples.count {
            let count = min(512 - pending, samples.count - offset)
            frame.withUnsafeMutableBufferPointer {
                $0.baseAddress!.advanced(by: pending).update(from: samples.baseAddress!.advanced(by: offset), count: count)
            }
            offset += count; pending += count
            if pending == 512 {
                let value = try score.consume(model.predict(frame[...]))
                try endpoint.observe(score: value, startSample: committed, sampleCount: 512)
                committed += 512; pending = 0
            }
        }
    }
    private func observation() throws -> LiveSpeechObservation {
        var probeEndpoint = endpoint
        if pending > 0 {
            var probeScore = score
            let value = try probeScore.consume(model.probe(frame[..<pending]))
            try probeEndpoint.observe(score: value, startSample: committed, sampleCount: pending)
        }
        return .init(normalizedSamples: committed + pending, incompleteFrameSamples: pending,
                     hasSpeech: probeEndpoint.hasSpeech, candidate: probeEndpoint.candidate)
    }
}
