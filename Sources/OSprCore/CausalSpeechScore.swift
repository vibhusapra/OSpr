import Foundation

/// Trailing noisy-OR aggregation of correlated detector outputs. This is an
/// activity score, not a calibrated probability. It reads no future frames.
public struct CausalSpeechScore {
    public let windowFrames: Int
    public private(set) var failed = false
    private var values: [Double]
    private var next = 0
    public init(windowFrames: Int = 8) throws {
        guard [1, 8].contains(windowFrames) else { throw OSprError.message("Speech score window must be 1 or 8 frames.") }
        self.windowFrames = windowFrames; values = [Double](repeating: 0, count: windowFrames)
    }
    public mutating func reset() {
        values.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: $0.count) }
        next = 0; failed = false
    }
    public mutating func consume(_ probability: Double) throws -> Double {
        guard !failed, probability.isFinite, (0...1).contains(probability) else {
            failed = true
            throw OSprError.message("Invalid speech score input. Reset before continuing.")
        }
        if windowFrames == 1 { return probability }
        values[next] = probability; next = (next + 1) % windowFrames
        var complement = 1.0
        // Chronological order matches the frozen development derivation, rather
        // than introducing roundoff changes as the physical ring rotates.
        for index in 0..<windowFrames { complement *= 1 - values[(next + index) % windowFrames] }
        return 1 - complement
    }
}
