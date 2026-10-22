import XCTest
import AVFoundation
@testable import OSpr

final class CapturePipelineTests: XCTestCase {
    func testTapStateKeepsSpeechTimingAndIncrementalMonoWithoutMainActorWork() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 2)!
        let sink = try AudioSink(url: url, format: format)
        let pipe = CapturePipeline(sink: sink, format: format, threshold: 0.01, now: 100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        for i in 0..<160 { buffer.floatChannelData![0][i] = 0.2; buffer.floatChannelData![1][i] = 0 }
        pipe.ingest(buffer, now: 100.1)
        XCTAssertEqual(pipe.telemetry().rms, 0.1, accuracy: 0.00001)
        XCTAssertEqual(pipe.telemetry().voiceAt, 100.1)
        XCTAssertTrue(pipe.telemetry().hasVoice)
        let first = try pipe.snapshot(incremental: true)
        XCTAssertEqual(first.count, 160); XCTAssertEqual(first.last!, 0.1, accuracy: 0.00001)
        XCTAssertTrue(try pipe.snapshot(incremental: true).isEmpty)
        for channel in 0..<2 { for i in 0..<160 { buffer.floatChannelData![channel][i] = 0 } }
        pipe.ingest(buffer, now: 100.2)
        XCTAssertEqual(pipe.telemetry().voiceAt, 100.1)
        XCTAssertEqual(pipe.telemetry().receivedAt, 100.2)
        try pipe.finish()
        pipe.ingest(buffer, now: 101)
        XCTAssertEqual(try pipe.snapshot(incremental: false).count, 320)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 320)
    }
    func testNonfiniteInputNeverReachesTheVisualMeter() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let pipe = CapturePipeline(sink: try AudioSink(url: url, format: format), format: format, threshold: 0.01)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        buffer.frameLength = 1; buffer.floatChannelData![0][0] = .nan
        pipe.ingest(buffer)
        XCTAssertNotNil(pipe.error); XCTAssertTrue(pipe.telemetry().rms.isFinite)
        XCTAssertThrowsError(try pipe.finish())
    }
}
