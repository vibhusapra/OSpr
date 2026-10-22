import XCTest
import AVFoundation
import CoreMedia
@testable import OSpr

final class MeetingCaptureTests: XCTestCase {
    func testClockGapsAreBoundedBeforeFrameConversion() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Desktop capture requires macOS 15") }
        XCTAssertEqual(try MeetingCapture.gapFrames(timestamp: 10.25, previousEnd: 10, rate: 48000), 12000)
        XCTAssertEqual(try MeetingCapture.gapFrames(timestamp: 10.00001, previousEnd: 10, rate: 48000), 0)
        for timestamp in [Double.nan, Double.infinity, -1, 4000, 1e100] {
            XCTAssertThrowsError(try MeetingCapture.gapFrames(timestamp: timestamp, previousEnd: 10, rate: 48000))
        }
        XCTAssertThrowsError(try MeetingCapture.gapFrames(timestamp: 9, previousEnd: 10, rate: 48000))
    }
    func testScreenCapturePCMConversionPreservesInterleavedStereoSamples() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Desktop capture requires macOS 15") }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true)!
        let samples = (0..<128).flatMap { _ in [Float(0.25), Float(-0.75)] }
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description), noErr)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: samples.count * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: samples.count * 4, flags: 0, blockBufferOut: &block), noErr)
        XCTAssertEqual(samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: $0.count) }, noErr)
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: CMTime(value: 1000, timescale: 1), decodeTimeStamp: .invalid)
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: description, sampleCount: 128, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
        let pcm = try MeetingCapture.pcm(sample!)
        XCTAssertEqual(pcm.frameLength, 128); XCTAssertTrue(pcm.format.isInterleaved)
        XCTAssertEqual(pcm.floatChannelData![0][0], 0.25)
        XCTAssertEqual(pcm.floatChannelData![0][255], -0.75)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioSink(url: url, format: pcm.format)
        writer.enqueue(pcm); try writer.finish()
        let file = try AVAudioFile(forReading: url)
        let decoded = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 128)!
        try file.read(into: decoded)
        XCTAssertEqual(decoded.frameLength, 128)
        XCTAssertEqual(decoded.floatChannelData![0][127], 0.25)
        XCTAssertEqual(decoded.floatChannelData![1][127], -0.75)
    }
    func testPresentationClockSilenceDoesNotExhaustRecordingPoolOrLoseTail() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioSink(url: url, format: format)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80)!
        pcm.frameLength = 80
        for i in 0..<80 { pcm.floatChannelData![0][i] = 0.25 }
        writer.enqueue(pcm); writer.silence(frames: 160000); writer.enqueue(pcm); try writer.finish()
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 160160)
        let decoded = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!
        var samples: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: decoded)
            guard decoded.frameLength > 0 else { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: decoded.floatChannelData![0], count: Int(decoded.frameLength)))
        }
        XCTAssertEqual(samples.count, 160160)
        XCTAssertEqual(samples[0], 0.25)
        XCTAssertEqual(samples[10000], 0)
        XCTAssertEqual(samples.last, 0.25)
    }
}
