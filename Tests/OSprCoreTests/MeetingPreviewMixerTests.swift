import XCTest
import AVFoundation
@testable import OSprCore

final class MeetingPreviewMixerTests: XCTestCase {
    func testSingleSourceKeepsEverySampleAndFlushesFinalTail() throws {
        let mixer = try MeetingPreviewMixer(includeMicrophone: false)
        let input = (0..<24000).map { Float(sin(Double($0) * 0.02)) * 0.2 }
        var output: [Float] = []
        for offset in stride(from: 0, to: input.count, by: 1024) {
            let block = Array(input[offset..<min(input.count, offset + 1024)])
            try append(block, to: mixer, source: .system, rate: 16000, time: 1000 + Double(offset) / 16000)
            output += try mixer.snapshot(incremental: true)
        }
        mixer.finish(); output += try drain(mixer)
        XCTAssertEqual(output, input)
        XCTAssertEqual(mixer.startTime, 1000)
        XCTAssertEqual(mixer.emittedSamples, input.count)
        XCTAssertEqual(mixer.bufferedInputSamples, 0)
        XCTAssertTrue(try mixer.snapshot(incremental: true).isEmpty)
        XCTAssertThrowsError(try append([0], to: mixer, source: .system, rate: 16000, time: 1002))
    }
    func testClockAlignmentDoesNotDependOnWhichSourceArrivesFirst() throws {
        let mixer = try MeetingPreviewMixer(includeMicrophone: true)
        try append([Float](repeating: 0.4, count: 1600), to: mixer, source: .microphone, rate: 16000, time: 1000.2)
        XCTAssertTrue(try mixer.snapshot(incremental: true).isEmpty)
        try append([Float](repeating: 0.2, count: 4800), to: mixer, source: .system, rate: 16000, time: 1000)
        mixer.finish()
        let mixed = try drain(mixer)
        XCTAssertEqual(mixer.startTime, 1000)
        XCTAssertEqual(mixed.count, 4800)
        XCTAssertEqual(Array(mixed.prefix(3200)), [Float](repeating: 0.1, count: 3200))
        for sample in mixed.suffix(1600) { XCTAssertEqual(sample, 0.3, accuracy: 1e-7) }
    }
    func testSparseThirtySecondGapDoesNotAllocateOrOverwriteUnreadSpeech() throws {
        let mixer = try MeetingPreviewMixer(includeMicrophone: false)
        try append([Float](repeating: 0.2, count: 800), to: mixer, source: .system, rate: 16000, time: 1000)
        let capacity = mixer.allocatedSampleCapacity
        // Keep the first packet unread while a much later packet arrives.
        try append([Float](repeating: 0.4, count: 800), to: mixer, source: .system, rate: 16000, time: 1030.05)
        XCTAssertEqual(mixer.bufferedInputSamples, 1600)
        XCTAssertEqual(mixer.allocatedSampleCapacity, capacity)
        mixer.finish(); let output = try drain(mixer)
        XCTAssertEqual(output.count, 481600)
        XCTAssertEqual(Array(output.prefix(800)), [Float](repeating: 0.2, count: 800))
        XCTAssertEqual(Array(output[800..<480800]), [Float](repeating: 0, count: 480000))
        XCTAssertEqual(Array(output.suffix(800)), [Float](repeating: 0.4, count: 800))
    }
    func testContinuousDuplexResamplingMatchesIndependentWholeTracksAcrossPartitions() throws {
        let rates = [44100.0, 48000.0]
        let values = rates.map { rate in (0..<Int(rate * 2.31)).map { Float(sin(Double($0) * 2 * .pi * 321 / rate)) * 0.2 } }
        let expectedSystem = try resample(values[0], rate: rates[0])
        let expectedMic = try resample(values[1], rate: rates[1])
        let delay = 2000
        var expected = [Float](repeating: 0, count: max(expectedSystem.count, expectedMic.count + delay))
        for i in expectedSystem.indices { expected[i] += expectedSystem[i] * 0.5 }
        for i in expectedMic.indices { expected[i + delay] += expectedMic[i] * 0.5 }
        for sizes in [[1024], [1, 137, 2047, 509, 3]] {
            let mixer = try MeetingPreviewMixer(includeMicrophone: true)
            var events: [(time: Double, source: Int, offset: Int, length: Int)] = []
            for source in 0..<2 {
                var offset = 0, index = 0
                while offset < values[source].count {
                    let length = min(sizes[index % sizes.count], values[source].count - offset)
                    events.append((Double(offset + length) / rates[source] + (source == 1 ? 0.125 + 0.04 : 0), source, offset, length))
                    offset += length; index += 1
                }
            }
            events.sort { $0.time < $1.time }
            var output: [Float] = []
            for event in events {
                let source = event.source
                let block = Array(values[source][event.offset..<event.offset + event.length])
                try append(block, to: mixer, source: source == 0 ? .system : .microphone, rate: rates[source],
                           time: 1000 + (source == 1 ? 0.125 : 0) + Double(event.offset) / rates[source])
                output += try mixer.snapshot(incremental: true)
            }
            mixer.finish(); output += try drain(mixer)
            XCTAssertEqual(output.count, expected.count)
            XCTAssertEqual(output, expected, "Packets must not reset filters or change the mixed waveform")
        }
    }
    func testAbsentPeerIsSilentAndLatePeerCannotRewriteCommittedPreview() throws {
        let mixer = try MeetingPreviewMixer(includeMicrophone: true)
        try append([Float](repeating: 0.2, count: 8192), to: mixer, source: .system, rate: 16000, time: 1000)
        try append([Float](repeating: 0.2, count: 7808), to: mixer, source: .system, rate: 16000, time: 1000.512)
        let first = try mixer.snapshot(incremental: true)
        XCTAssertEqual(first, [Float](repeating: 0.1, count: 8000))
        XCTAssertThrowsError(try append([0.3], to: mixer, source: .microphone, rate: 16000, time: 1000.1))
        XCTAssertThrowsError(try mixer.snapshot(incremental: true), "A failed preview is terminal, never silently rewound")
    }
    func testLateKnownTrackAndConsumerOverflowFailVisiblyWithFixedCapacity() throws {
        let mixer = try MeetingPreviewMixer(includeMicrophone: true)
        try append([Float](repeating: 0.1, count: 1600), to: mixer, source: .microphone, rate: 16000, time: 1000)
        try append([Float](repeating: 0.2, count: 8000), to: mixer, source: .system, rate: 16000, time: 1000)
        try append([Float](repeating: 0.2, count: 8000), to: mixer, source: .system, rate: 16000, time: 1000.5)
        _ = try mixer.snapshot(incremental: true)
        XCTAssertThrowsError(try append([0.3], to: mixer, source: .microphone, rate: 16000, time: 1000.1))
        let small = try MeetingPreviewMixer(includeMicrophone: false, bufferSeconds: 1)
        try append([Float](repeating: 0, count: 8000), to: small, source: .system, rate: 16000, time: 1000)
        try append([Float](repeating: 0, count: 8000), to: small, source: .system, rate: 16000, time: 1000.5)
        let capacity = small.allocatedSampleCapacity
        XCTAssertThrowsError(try append([0], to: small, source: .system, rate: 16000, time: 1001))
        XCTAssertEqual(small.allocatedSampleCapacity, capacity)
    }
    func testRollingDraftIsBoundedWhileIncrementalTimelineKeepsGrowing() throws {
        let mixer = try MeetingPreviewMixer(includeMicrophone: false, bufferSeconds: 1, reorderSeconds: 0)
        let block = [Float](repeating: 0.2, count: 8000)
        for index in 0..<12 {
            try append(block, to: mixer, source: .system, rate: 16000, time: 1000 + Double(index) * 0.5)
            XCTAssertEqual(try mixer.snapshot(incremental: false).count, min(16000, (index + 1) * 8000))
        }
        XCTAssertEqual(mixer.emittedSamples, 96000)
        XCTAssertTrue(try mixer.snapshot(incremental: false).isEmpty)
    }
    func testInvalidValuesRatesClocksAndUnexpectedSourcesAreRejected() throws {
        for values in [[Float.nan], [.infinity]] {
            let mixer = try MeetingPreviewMixer(includeMicrophone: false)
            XCTAssertThrowsError(try append(values, to: mixer, source: .system, rate: 16000, time: 1000))
        }
        for rate in [Double.nan, 0, 7999, 192001, 44100.5] {
            let mixer = try MeetingPreviewMixer(includeMicrophone: false)
            XCTAssertThrowsError(try append([0], to: mixer, source: .system, rate: rate, time: 1000))
        }
        for time in [Double.nan, .infinity, -1, 1e100] {
            let mixer = try MeetingPreviewMixer(includeMicrophone: false)
            XCTAssertThrowsError(try append([0], to: mixer, source: .system, rate: 16000, time: time))
        }
        let mixer = try MeetingPreviewMixer(includeMicrophone: false)
        XCTAssertThrowsError(try append([0], to: mixer, source: .microphone, rate: 16000, time: 1000))
    }
    private func append(_ values: [Float], to mixer: MeetingPreviewMixer, source: MeetingPreviewSource,
                        rate: Double, time: Double) throws {
        try values.withUnsafeBufferPointer { try mixer.append($0, source: source, sampleRate: rate, timestamp: time) }
    }
    private func drain(_ mixer: MeetingPreviewMixer) throws -> [Float] {
        var output: [Float] = []
        for _ in 0..<100 {
            let packet = try mixer.snapshot(incremental: true)
            if packet.isEmpty { return output }
            output += packet
        }
        throw OSprError.message("Mixer failed to finish")
    }
    private func resample(_ values: [Float], rate: Double) throws -> [Float] {
        let converter = try StreamingSpeechResampler(sampleRate: rate)
        var output: [Float] = []
        for offset in stride(from: 0, to: values.count, by: 8192) {
            let count = min(8192, values.count - offset)
            let buffer = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count { buffer.floatChannelData![0][i] = values[offset + i] }
            try converter.process(buffer) { output += $0 }
        }
        try converter.finish { output += $0 }
        return output
    }
}
