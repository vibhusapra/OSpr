import Foundation

/// Retractable counterpart of the offline one-shot policy. A finish candidate
/// describes the current examined frontier; resumed activity revokes it. This
/// value never claims that the capture source has stopped producing newer audio.
public struct LiveSpeechEndpoint {
    public let configuration: SpeechEndpoint.Configuration
    public private(set) var observedSamples = 0
    public private(set) var hasSpeech = false
    public private(set) var failed = false
    public private(set) var lastSpeechEnd = 0
    private var pendingStart: Int?
    public init(configuration: SpeechEndpoint.Configuration) { self.configuration = configuration }
    public var candidate: SpeechEndpoint.Event? {
        guard !failed, hasSpeech,
              observedSamples - lastSpeechEnd >= Int(ceil(configuration.silenceSeconds * 16_000)) else { return nil }
        return .init(kind: .finished, boundarySample: lastSpeechEnd, observedThroughSample: observedSamples)
    }
    public mutating func observe(score: Double, startSample: Int, sampleCount: Int) throws {
        guard !failed, score.isFinite, (0...1).contains(score), startSample == observedSamples,
              sampleCount > 0, sampleCount <= 512, startSample <= Int.max - sampleCount else {
            failed = true
            throw OSprError.message("Live speech detection lost its contiguous audio timeline. Stop manually.")
        }
        observedSamples += sampleCount
        if hasSpeech {
            if score >= configuration.continueThreshold { lastSpeechEnd = observedSamples }
        } else if score >= configuration.startThreshold {
            if pendingStart == nil { pendingStart = startSample }
            if observedSamples - pendingStart! >= Int(ceil(configuration.minimumSpeechSeconds * 16_000)) {
                hasSpeech = true; lastSpeechEnd = observedSamples
            }
        } else { pendingStart = nil }
    }
}
