import XCTest
import AVFoundation
@testable import OSprCore

final class StreamingSpeechResamplerTests: XCTestCase {
    func testContinuousConversionIsPartitionInvariantAtDeviceRates() throws {
        for rate in [8_000.0, 16_000, 44_100, 48_000, 96_000] {
            let input = (0..<Int(rate * 0.37)).map { Float(sin(Double($0) * 2 * .pi * 440 / rate)) * 0.2 }
            let whole = try convert(input, rate: rate, sizes: [8192])
            let fragmented = try convert(input, rate: rate, sizes: [1, 137, 1024, 3, 8191, 509])
            XCTAssertEqual(whole.count, fragmented.count, "\(rate)")
            XCTAssertEqual(whole, fragmented, "Resetting a converter at packet seams changes its signal")
            XCTAssertLessThanOrEqual(abs(whole.count - Int(Double(input.count) * 16000 / rate)), 1)
            XCTAssertTrue(whole.allSatisfy(\.isFinite))
            if rate == 16_000 { XCTAssertEqual(whole, input) }
        }
    }
    func testNoEndOfStreamFlushOccursBetweenLiveBlocks() throws {
        let stream = try StreamingSpeechResampler(sampleRate: 48_000)
        let first = buffer([Float](repeating: 0.1, count: 1024), rate: 48_000)
        var output = [Float]()
        try stream.process(first) { output += $0 }
        try stream.process(first) { output += $0 }
        try stream.finish { output += $0 }
        XCTAssertEqual(output.count, Int((2048.0 / 3).rounded(.up)))
        XCTAssertThrowsError(try stream.process(first) { _ in })
        XCTAssertThrowsError(try stream.finish { _ in })
    }
    func testInvalidRateFormatAndNonfiniteInputAreRejected() throws {
        for rate in [Double.nan, 0, 7999, 192001] {
            XCTAssertThrowsError(try StreamingSpeechResampler(sampleRate: rate))
        }
        let stream = try StreamingSpeechResampler(sampleRate: 16_000)
        XCTAssertThrowsError(try stream.process(buffer([1], rate: 48_000)) { _ in })
        XCTAssertThrowsError(try stream.process(buffer([.nan], rate: 16_000)) { _ in })
        XCTAssertThrowsError(try stream.process(buffer([.infinity], rate: 16_000)) { _ in })
    }
    private func convert(_ values: [Float], rate: Double, sizes: [Int]) throws -> [Float] {
        let stream = try StreamingSpeechResampler(sampleRate: rate)
        var position = 0, index = 0
        var output = [Float]()
        while position < values.count {
            let count = min(sizes[index % sizes.count], values.count - position)
            try stream.process(buffer(Array(values[position..<position + count]), rate: rate)) { output += $0 }
            position += count; index += 1
        }
        try stream.finish { output += $0 }
        return output
    }
    private func buffer(_ values: [Float], rate: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, values.count)))!
        buffer.frameLength = AVAudioFrameCount(values.count)
        values.withUnsafeBufferPointer { if !$0.isEmpty { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) } }
        return buffer
    }
}
