import XCTest
import AVFoundation
@testable import OSpr
@testable import OSprCore

final class MeetingAudioPipelineTests: XCTestCase {
    func testLatePreviewSourceDoesNotLoseOrStopEitherDurableTrack() throws {
        try withDirectory { directory in
            let pipeline = try MeetingAudioPipeline(directory: directory, includeMicrophone: true, preview: true)
            _ = try pipeline.ingest(buffer(count: 1600, value: 0.4), source: .microphone, timestamp: 1000)
            _ = try pipeline.ingest(buffer(count: 8000, value: 0.2), source: .system, timestamp: 1000)
            _ = try pipeline.ingest(buffer(count: 8000, value: 0.2), source: .system, timestamp: 1000.5)
            XCTAssertEqual(try pipeline.preview(incremental: true).count, 8000)
            // This packet is older than the preview watermark, but it is valid
            // continuous microphone audio and must still be admitted to disk.
            XCTAssertNoThrow(try pipeline.ingest(buffer(count: 1600, value: 0.4), source: .microphone, timestamp: 1000.1))
            XCTAssertThrowsError(try pipeline.preview(incremental: true))
            _ = try pipeline.ingest(buffer(count: 1600, value: 0.4), source: .microphone, timestamp: 1000.2)
            let tracks = try pipeline.finish()
            XCTAssertEqual(tracks.count, 2)
            XCTAssertEqual(try samples(directory.appendingPathComponent("system.wav")), [Float](repeating: 0.2, count: 16000))
            XCTAssertEqual(try samples(directory.appendingPathComponent("microphone.wav")), [Float](repeating: 0.4, count: 4800))
            XCTAssertThrowsError(try pipeline.ingest(buffer(count: 10, value: 1), source: .system, timestamp: 1001))
        }
    }
    func testPreviewPCMIsClockMixedPrivateFloat32WithFinalTailPreserved() throws {
        try withDirectory { directory in
            let pipeline = try MeetingAudioPipeline(directory: directory, includeMicrophone: true, preview: true)
            _ = try pipeline.ingest(buffer(count: 3200, value: 0.2), source: .system, timestamp: 1000)
            _ = try pipeline.ingest(buffer(count: 1600, value: 0.4), source: .microphone, timestamp: 1000.1)
            _ = try pipeline.finish()
            let mixed = try pipeline.preview(incremental: true)
            XCTAssertEqual(mixed.count, 3200)
            for value in mixed.prefix(1600) { XCTAssertEqual(value, 0.1, accuracy: 1e-7) }
            for value in mixed.suffix(1600) { XCTAssertEqual(value, 0.3, accuracy: 1e-7) }
            let path = try XCTUnwrap(MeetingAudioPipeline.exportPreview(mixed, directory: directory))
            XCTAssertEqual(try samples(path), mixed)
            let file = try AVAudioFile(forReading: path)
            XCTAssertEqual(file.processingFormat.sampleRate, 16000)
            XCTAssertEqual(file.processingFormat.channelCount, 1)
            let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
            XCTAssertTrue(try pipeline.preview(incremental: true).isEmpty)
            XCTAssertNil(try MeetingAudioPipeline.exportPreview([], directory: directory))
        }
    }
    func testDisabledPreviewAndPresentationGapPreserveOriginalSamples() throws {
        try withDirectory { directory in
            let pipeline = try MeetingAudioPipeline(directory: directory, includeMicrophone: false, preview: false)
            _ = try pipeline.ingest(buffer(count: 160, value: 0.2), source: .system, timestamp: 1000)
            _ = try pipeline.ingest(buffer(count: 160, value: 0.4), source: .system, timestamp: 1000.11)
            XCTAssertTrue(try pipeline.preview(incremental: true).isEmpty)
            _ = try pipeline.finish()
            let original = try samples(directory.appendingPathComponent("system.wav"))
            XCTAssertEqual(original.count, 1920)
            XCTAssertEqual(Array(original.prefix(160)), [Float](repeating: 0.2, count: 160))
            XCTAssertEqual(Array(original[160..<1760]), [Float](repeating: 0, count: 1600))
            XCTAssertEqual(Array(original.suffix(160)), [Float](repeating: 0.4, count: 160))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["system.wav"])
        }
    }
    func testUnexpectedMicrophoneAndInvalidPreviewExportsAreRejected() throws {
        try withDirectory { directory in
            let pipeline = try MeetingAudioPipeline(directory: directory, includeMicrophone: false, preview: true)
            XCTAssertThrowsError(try pipeline.ingest(buffer(count: 16, value: 0), source: .microphone, timestamp: 1000))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
            XCTAssertThrowsError(try MeetingAudioPipeline.exportPreview([.nan], directory: directory))
            XCTAssertThrowsError(try MeetingAudioPipeline.exportPreview([Float](repeating: 0, count: 192001), directory: directory))
        }
    }
    func testCaptureFormatFailureKeepsTheAdmittedPrefix() throws {
        try withDirectory { directory in
            let pipeline = try MeetingAudioPipeline(directory: directory, includeMicrophone: false, preview: true)
            _ = try pipeline.ingest(buffer(count: 160, value: 0.2), source: .system, timestamp: 1000)
            let changed = buffer(count: 480, value: 0.4, rate: 48000)
            XCTAssertThrowsError(try pipeline.ingest(changed, source: .system, timestamp: 1000.01))
            XCTAssertThrowsError(try pipeline.finish())
            XCTAssertEqual(try samples(directory.appendingPathComponent("system.wav")), [Float](repeating: 0.2, count: 160))
        }
    }
    private func buffer(count: Int, value: Float, rate: Double = 16000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        buffer.floatChannelData![0].update(repeating: value, count: count)
        return buffer
    }
    private func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!
        var result: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { throw OSprError.message("Unexpected zero-length fixture read") }
            result += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
        return result
    }
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-meeting-pipeline-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
