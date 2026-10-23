import Foundation

/// One-shot endpointing driven by contiguous audio time, never wall-clock delay.
/// A slow detector therefore cannot turn queued, unexamined speech into silence.
public struct SpeechEndpoint {
    public struct Configuration: Encodable, Equatable {
        public let sampleRate: Int
        public let startThreshold: Double
        public let continueThreshold: Double
        public let minimumSpeechSeconds: Double
        public let silenceSeconds: Double
        public init(sampleRate: Int = 16_000, startThreshold: Double = 0.5,
                    continueThreshold: Double = 0.35, minimumSpeechSeconds: Double = 0.096,
                    silenceSeconds: Double = 1.2) throws {
            guard sampleRate == 16_000, startThreshold.isFinite, continueThreshold.isFinite,
                  0 < continueThreshold, continueThreshold <= startThreshold, startThreshold <= 1,
                  minimumSpeechSeconds.isFinite, (0.032...1).contains(minimumSpeechSeconds),
                  silenceSeconds.isFinite, (0.1...30).contains(silenceSeconds) else {
                throw OSprError.message("Invalid speech endpoint configuration.")
            }
            self.sampleRate = sampleRate; self.startThreshold = startThreshold
            self.continueThreshold = continueThreshold; self.minimumSpeechSeconds = minimumSpeechSeconds
            self.silenceSeconds = silenceSeconds
        }
    }
    public struct Event: Codable, Equatable {
        public enum Kind: String, Codable { case speechStarted, finished }
        public let kind: Kind
        /// Boundary on the original audio timeline, before trailing silence.
        public let boundarySample: Int
        /// Audio examined before the decision could be made.
        public let observedThroughSample: Int
    }
    public let configuration: Configuration
    public private(set) var observedSamples = 0
    public private(set) var hasSpeech = false
    public private(set) var finished = false
    public private(set) var failed = false
    private var pendingStart: Int?
    private var lastSpeechEnd = 0
    public init(configuration: Configuration) { self.configuration = configuration }
    public mutating func reset() {
        observedSamples = 0; hasSpeech = false; finished = false; failed = false
        pendingStart = nil; lastSpeechEnd = 0
    }
    public mutating func observe(probability: Double, startSample: Int, sampleCount: Int) throws -> [Event] {
        guard !failed, probability.isFinite, (0...1).contains(probability),
              startSample == observedSamples, sampleCount > 0, sampleCount <= 4096,
              startSample <= Int.max - sampleCount else {
            failed = true
            throw OSprError.message("Speech detection lost its contiguous audio timeline. Reset the detector before continuing.")
        }
        observedSamples += sampleCount
        guard !finished else { return [] }
        if !hasSpeech {
            if probability >= configuration.startThreshold {
                if pendingStart == nil { pendingStart = startSample }
                if observedSamples - pendingStart! >= Int(ceil(configuration.minimumSpeechSeconds * Double(configuration.sampleRate))) {
                    hasSpeech = true; lastSpeechEnd = observedSamples
                    return [Event(kind: .speechStarted, boundarySample: pendingStart!, observedThroughSample: observedSamples)]
                }
            } else { pendingStart = nil }
        } else if probability >= configuration.continueThreshold {
            lastSpeechEnd = observedSamples
        } else if observedSamples - lastSpeechEnd >= Int(ceil(configuration.silenceSeconds * Double(configuration.sampleRate))) {
            finished = true
            return [Event(kind: .finished, boundarySample: lastSpeechEnd, observedThroughSample: observedSamples)]
        }
        return []
    }
}
