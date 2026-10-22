import XCTest
import AVFoundation
@testable import OSpr

final class AudioSinkTests: XCTestCase {
    func testNativeWriterDrainsAndFinalizesStereoWAVWithoutLosingFrames() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let sink = try AudioSink(url: url, format: format)
        for index in 0..<10 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
            buffer.frameLength = 1024
            for frame in 0..<1024 {
                buffer.floatChannelData![0][frame] = Float(index) / 20
                buffer.floatChannelData![1][frame] = -Float(index) / 20
            }
            sink.enqueue(buffer)
        }
        try sink.finish()
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 10240)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
        let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 10240)!
        try file.read(into: output)
        XCTAssertEqual(output.floatChannelData![0][9500], 0.45, accuracy: 0.00001)
        XCTAssertEqual(output.floatChannelData![1][9500], -0.45, accuracy: 0.00001)
    }
    func testOversizedCallbackFailsVisibly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let sink = try AudioSink(url: url, format: format)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9000)!
        buffer.frameLength = 9000
        sink.enqueue(buffer)
        XCTAssertNotNil(sink.error)
        XCTAssertThrowsError(try sink.finish())
    }
    @MainActor func testSecureFieldInsertionDoesNotTouchClipboard() async {
        let target = InsertionTarget(app: nil, element: nil, selectedText: "", secure: true)
        do { try await target.paste("test", restoreClipboard: true); XCTFail("Expected secure field rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("password")) }
    }
}
