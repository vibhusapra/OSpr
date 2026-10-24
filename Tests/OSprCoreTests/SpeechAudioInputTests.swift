import XCTest
import AVFoundation
@testable import OSprCore

final class SpeechAudioInputTests: XCTestCase {
    private func write(_ samples: [Float], rate: Double = 16_000, channels: AVAudioChannelCount = 1) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if !samples.isEmpty {
            for channel in 0..<Int(channels) {
                samples.withUnsafeBufferPointer { buffer.floatChannelData![channel].update(from: $0.baseAddress!, count: $0.count) }
            }
            try file!.write(from: buffer)
        }
        file = nil
        return url
    }
    func testPreservesEverySampleAcrossShortReadsAndAnUnevenTail() throws {
        let samples = (0..<230_913).map { Float(($0 % 1024) - 512) / 1024 }
        let url = try write(samples); defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try SpeechAudioInput.read(url), samples)
    }
    func testRejectsWrongRateAndStereoWithoutImplicitConversion() throws {
        for (rate, channels) in [(44_100.0, AVAudioChannelCount(1)), (16_000.0, AVAudioChannelCount(2))] {
            let url = try write([Float](repeating: 0.1, count: 512), rate: rate, channels: channels)
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertThrowsError(try SpeechAudioInput.read(url))
        }
    }
    func testRejectsNonFiniteAndEmptyInput() throws {
        for samples in [[Float.nan], []] {
            let url = try write(samples); defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertThrowsError(try SpeechAudioInput.read(url))
        }
    }
}
