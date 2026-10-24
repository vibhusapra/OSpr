import XCTest
import AVFoundation
@testable import OSprCore

final class NeuralCaptureTests: XCTestCase {
    func testPartialTailProbesDoNotCommitPaddingOrDuplicateAnySample() throws {
        let model = SampleModel()
        let processor = try NeuralCaptureProcessor(sampleRate: 16_000, model: model, silenceSeconds: 0.1)
        let input = (0..<15_031).map { Float($0 % 97) / 97 }
        var start = 0
        for count in [1, 1024, 7, 8192, 509, 5298] {
            let end = min(start + count, input.count)
            if start == end { continue }
            let result = try processor.process(buffer(Array(input[start..<end])))
            XCTAssertEqual(result.normalizedSamples, end)
            XCTAssertEqual(result.incompleteFrameSamples, end % 512)
            XCTAssertEqual(model.committed, Array(input.prefix(end / 512 * 512)))
            start = end
        }
        XCTAssertEqual(start, input.count)
        let result = try processor.finish()
        XCTAssertEqual(result.normalizedSamples, input.count)
        XCTAssertEqual(model.probes.last, Array(input.suffix(input.count % 512)))
    }
    func testNewSpeechInEvenOnePartialSampleRevokesTheQuietCandidate() throws {
        let processor = try NeuralCaptureProcessor(sampleRate: 16_000, model: SampleModel(), silenceSeconds: 0.1)
        _ = try processor.process(buffer([Float](repeating: 0.2, count: 1536)))
        let quiet = try processor.process(buffer([Float](repeating: 0, count: 6144)))
        XCTAssertNotNil(quiet.candidate)
        let resumed = try processor.process(buffer([0.2]))
        XCTAssertEqual(resumed.incompleteFrameSamples, 1)
        XCTAssertNil(resumed.candidate)
        XCTAssertTrue(resumed.hasSpeech)
    }
    func testQueuedNewerAudioPreventsClaimAndCanRevokeAnEarlierCandidate() throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let monitor = try NeuralCaptureMonitor(sampleRate: 16_000) { input in
            if input.floatChannelData![0][0] == 2 {
                entered.signal()
                guard release.wait(timeout: .now() + 5) == .success else { throw TestFailure.timeout }
                return observation(through: 1024, finish: false)
            }
            return observation(through: 512, finish: true)
        }
        defer { release.signal(); monitor.close(); monitor.synchronize() }
        enqueue([Float](repeating: 1, count: 512), monitor)
        monitor.synchronize()
        XCTAssertNotNil(monitor.snapshot().observation?.candidate)
        enqueue([Float](repeating: 2, count: 512), monitor)
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(monitor.claimFinish(expectedInputSamples: 512))
        XCTAssertFalse(monitor.claimFinish(expectedInputSamples: 1024))
        release.signal(); monitor.synchronize()
        XCTAssertNil(monitor.snapshot().observation?.candidate)
        XCTAssertFalse(monitor.claimFinish(expectedInputSamples: 1024))
    }
    func testCaughtUpClaimIsAtomicAndClosesAdmission() throws {
        let monitor = try NeuralCaptureMonitor(sampleRate: 16_000) { _ in observation(through: 512, finish: true) }
        XCTAssertFalse(monitor.claimFinish(expectedInputSamples: 0))
        enqueue([Float](repeating: 0, count: 512), monitor); monitor.synchronize()
        XCTAssertFalse(monitor.claimFinish(expectedInputSamples: 511))
        XCTAssertTrue(monitor.claimFinish(expectedInputSamples: 512))
        XCTAssertFalse(monitor.claimFinish(expectedInputSamples: 512))
        enqueue([1], monitor)
        XCTAssertEqual(monitor.snapshot().receivedInputSamples, 512)
        XCTAssertFalse(monitor.snapshot().accepting)
    }
    func testBufferOverflowDisablesOnlyMonitorAndCannotReviveAfterDrain() throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let monitor = try NeuralCaptureMonitor(sampleRate: 16_000, bufferCount: 1) { _ in
            entered.signal()
            guard release.wait(timeout: .now() + 5) == .success else { throw TestFailure.timeout }
            return observation(through: 512, finish: true)
        }
        defer { release.signal(); monitor.close(); monitor.synchronize() }
        enqueue([Float](repeating: 0, count: 512), monitor)
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        enqueue([1], monitor)
        XCTAssertNotNil(monitor.snapshot().warning)
        release.signal(); monitor.synchronize()
        XCTAssertNil(monitor.snapshot().observation)
        XCTAssertFalse(monitor.claimFinish(expectedInputSamples: 513))
    }
    func testAudioTimeBacklogLimitAppliesEvenWhenFreeSlotsRemain() throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let monitor = try NeuralCaptureMonitor(sampleRate: 16_000, maximumQueuedSeconds: 0.04) { _ in
            entered.signal()
            guard release.wait(timeout: .now() + 5) == .success else { throw TestFailure.timeout }
            return observation(through: 512, finish: true)
        }
        defer { release.signal(); monitor.close(); monitor.synchronize() }
        enqueue([Float](repeating: 0, count: 512), monitor)
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        enqueue([Float](repeating: 0, count: 129), monitor)
        XCTAssertNotNil(monitor.snapshot().warning)
        XCTAssertFalse(monitor.snapshot().accepting)
    }
    func testInferenceFailureAndCloseCannotPublishOrFinish() throws {
        let failing = try NeuralCaptureMonitor(sampleRate: 16_000) { _ in throw TestFailure.inference }
        enqueue([1], failing); failing.synchronize()
        XCTAssertNotNil(failing.snapshot().warning)
        XCTAssertFalse(failing.claimFinish(expectedInputSamples: 1))
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let closing = try NeuralCaptureMonitor(sampleRate: 16_000) { _ in
            entered.signal()
            guard release.wait(timeout: .now() + 5) == .success else { throw TestFailure.timeout }
            return observation(through: 512, finish: true)
        }
        defer { release.signal(); closing.close(); closing.synchronize() }
        enqueue([Float](repeating: 0, count: 512), closing)
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        closing.close(); release.signal(); closing.synchronize()
        XCTAssertNil(closing.snapshot().observation)
        XCTAssertFalse(closing.claimFinish(expectedInputSamples: 512))
    }
    func testMonitorOwnsItsAudioCopyAndRejectsInconsistentResults() throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let monitor = try NeuralCaptureMonitor(sampleRate: 16_000) { input in
            entered.signal()
            guard release.wait(timeout: .now() + 5) == .success else { throw TestFailure.timeout }
            XCTAssertEqual(input.floatChannelData![0][0], 0.25)
            return .init(normalizedSamples: 512, incompleteFrameSamples: 0, hasSpeech: true,
                         candidate: .init(kind: .finished, boundarySample: 0, observedThroughSample: 511))
        }
        defer { release.signal(); monitor.close(); monitor.synchronize() }
        var source = [Float](repeating: 0.25, count: 512)
        source.withUnsafeBufferPointer { monitor.enqueue($0) }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        source[0] = 1
        release.signal(); monitor.synchronize()
        XCTAssertNotNil(monitor.snapshot().warning)
        XCTAssertFalse(monitor.claimFinish(expectedInputSamples: 512))
    }
    func testInvalidConfigurationsAndFramesFailClosed() throws {
        for rate in [Double.nan, 0, 192001] {
            XCTAssertThrowsError(try NeuralCaptureMonitor(sampleRate: rate) { _ in observation(through: 0, finish: false) })
        }
        for count in [0, 17] {
            XCTAssertThrowsError(try NeuralCaptureMonitor(sampleRate: 16_000, bufferCount: count) { _ in observation(through: 0, finish: false) })
        }
        for samples in [[], [Float](repeating: 0, count: 8193)] {
            let monitor = try NeuralCaptureMonitor(sampleRate: 16_000) { _ in XCTFail("Invalid input reached inference"); throw TestFailure.inference }
            enqueue(samples, monitor)
            XCTAssertNotNil(monitor.snapshot().warning)
        }
    }
    private enum TestFailure: Error { case timeout, inference }
    private func buffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        return buffer
    }
    private func enqueue(_ samples: [Float], _ monitor: NeuralCaptureMonitor) { samples.withUnsafeBufferPointer { monitor.enqueue($0) } }
}

private func observation(through: Int, finish: Bool) -> LiveSpeechObservation {
    .init(normalizedSamples: through, incompleteFrameSamples: 0, hasSpeech: true,
          candidate: finish ? .init(kind: .finished, boundarySample: 0, observedThroughSample: through) : nil)
}

private final class SampleModel: SpeechProbabilityModel {
    let chunkSamples = 512
    var committed = [Float]()
    var probes = [[Float]]()
    func predict(_ samples: ArraySlice<Float>) throws -> Double { committed += samples; return value(samples) }
    func probe(_ samples: ArraySlice<Float>) throws -> Double { probes.append(Array(samples)); return value(samples) }
    private func value(_ samples: ArraySlice<Float>) -> Double { samples.contains(where: { abs($0) > 0.01 }) ? 0.9 : 0 }
}
