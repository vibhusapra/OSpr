import Foundation
import AVFoundation

/// Bounded native input for offline detector replay. AVAudioFile can return
/// fewer frames than requested before EOF; drain it rather than losing a tail.
public enum SpeechAudioInput {
    public static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let expected = file.length
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              expected > 0, expected <= 300 * 16_000,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else {
            throw OSprError.message("Speech analysis accepts 16 kHz mono audio of at most five minutes.")
        }
        var samples = [Float](); samples.reserveCapacity(Int(expected))
        while samples.count < expected {
            let remaining = min(8192, Int(expected) - samples.count)
            try file.read(into: buffer, frameCount: AVAudioFrameCount(remaining))
            guard buffer.frameLength > 0, buffer.frameLength <= remaining,
                  let data = buffer.floatChannelData else {
                throw OSprError.message("Speech input ended before all declared audio frames were read.")
            }
            let block = UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))
            guard block.allSatisfy(\.isFinite) else { throw OSprError.message("Speech input contains non-finite samples.") }
            samples.append(contentsOf: block)
        }
        return samples
    }
}
