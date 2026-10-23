import XCTest
@testable import OSprCore

final class SpeechEndpointTests: XCTestCase {
    func testNeverFinishesBeforeSpeech() throws {
        var endpoint = SpeechEndpoint(configuration: try .init(silenceSeconds: 0.1))
        for index in 0..<200 {
            XCTAssertTrue(try endpoint.observe(probability: 0.05, startSample: index * 512, sampleCount: 512).isEmpty)
        }
        XCTAssertFalse(endpoint.hasSpeech); XCTAssertFalse(endpoint.finished)
    }
    func testShortNoiseBurstsDoNotArmEndpoint() throws {
        var endpoint = SpeechEndpoint(configuration: try .init(silenceSeconds: 0.1))
        for (index, p) in [0.9, 0.9, 0.1, 0.9, 0.1, 0.9, 0.9, 0.1].enumerated() {
            XCTAssertTrue(try endpoint.observe(probability: p, startSample: index * 512, sampleCount: 512).isEmpty)
        }
        XCTAssertFalse(endpoint.hasSpeech)
    }
    func testHysteresisAndAudioTimeFinishOnce() throws {
        var endpoint = SpeechEndpoint(configuration: try .init(silenceSeconds: 0.1))
        let probabilities = [0.6, 0.6, 0.6, 0.4, 0.35, 0.1, 0.1, 0.1, 0.1, 0.9]
        var events = [SpeechEndpoint.Event]()
        for (index, p) in probabilities.enumerated() {
            events += try endpoint.observe(probability: p, startSample: index * 512, sampleCount: 512)
        }
        XCTAssertEqual(events, [.init(kind: .speechStarted, boundarySample: 0, observedThroughSample: 1536),
                                .init(kind: .finished, boundarySample: 2560, observedThroughSample: 4608)])
        XCTAssertTrue(endpoint.finished)
    }
    func testSpeechResumptionRestartsSilenceBudget() throws {
        var endpoint = SpeechEndpoint(configuration: try .init(silenceSeconds: 0.1))
        let probabilities = [0.6, 0.6, 0.6, 0.0, 0.0, 0.4, 0.0, 0.0, 0.0, 0.0]
        var events = [SpeechEndpoint.Event]()
        for (index, p) in probabilities.enumerated() {
            events += try endpoint.observe(probability: p, startSample: index * 512, sampleCount: 512)
        }
        XCTAssertEqual(events.last, .init(kind: .finished, boundarySample: 3072, observedThroughSample: 5120))
    }
    func testTailPaddingCannotCountAsObservedSilence() throws {
        var endpoint = SpeechEndpoint(configuration: try .init(silenceSeconds: 0.1))
        _ = try endpoint.observe(probability: 0.9, startSample: 0, sampleCount: 4096)
        XCTAssertTrue(try endpoint.observe(probability: 0, startSample: 4096, sampleCount: 1599).isEmpty)
        let finish = try endpoint.observe(probability: 0, startSample: 5695, sampleCount: 1)
        XCTAssertEqual(finish, [.init(kind: .finished, boundarySample: 4096, observedThroughSample: 5696)])
    }
    func testGapOrDuplicatePoisonsStateUntilReset() throws {
        for badOffset in [0, 1024] {
            var endpoint = SpeechEndpoint(configuration: try .init())
            _ = try endpoint.observe(probability: 0.9, startSample: 0, sampleCount: 512)
            XCTAssertThrowsError(try endpoint.observe(probability: 0.9, startSample: badOffset, sampleCount: 512))
            XCTAssertTrue(endpoint.failed)
            XCTAssertThrowsError(try endpoint.observe(probability: 0.9, startSample: 512, sampleCount: 512))
            endpoint.reset()
            XCTAssertTrue(try endpoint.observe(probability: 0.9, startSample: 0, sampleCount: 512).isEmpty)
        }
    }
    func testInvalidFramesAndProbabilitiesFailClosed() throws {
        for p in [Double.nan, .infinity, -.infinity, -0.1, 1.1] {
            var endpoint = SpeechEndpoint(configuration: try .init())
            XCTAssertThrowsError(try endpoint.observe(probability: p, startSample: 0, sampleCount: 512))
            XCTAssertTrue(endpoint.failed)
        }
        for count in [0, -1, 4097, Int.max] {
            var endpoint = SpeechEndpoint(configuration: try .init())
            XCTAssertThrowsError(try endpoint.observe(probability: 0.5, startSample: 0, sampleCount: count))
            XCTAssertTrue(endpoint.failed)
        }
    }
    func testConfigurationRejectsInvalidValues() throws {
        XCTAssertThrowsError(try SpeechEndpoint.Configuration(sampleRate: 8000))
        XCTAssertThrowsError(try SpeechEndpoint.Configuration(startThreshold: .nan))
        XCTAssertThrowsError(try SpeechEndpoint.Configuration(continueThreshold: 0.9))
        XCTAssertThrowsError(try SpeechEndpoint.Configuration(minimumSpeechSeconds: 0))
        XCTAssertThrowsError(try SpeechEndpoint.Configuration(silenceSeconds: .infinity))
        XCTAssertThrowsError(try SpeechEndpoint.Configuration(silenceSeconds: 0))
    }
    func testResetDoesNotKeepFinishedSpeechState() throws {
        var endpoint = SpeechEndpoint(configuration: try .init(silenceSeconds: 0.1))
        _ = try endpoint.observe(probability: 1, startSample: 0, sampleCount: 4096)
        _ = try endpoint.observe(probability: 0, startSample: 4096, sampleCount: 4096)
        XCTAssertTrue(endpoint.finished)
        endpoint.reset()
        XCTAssertEqual(endpoint.observedSamples, 0); XCTAssertFalse(endpoint.finished); XCTAssertFalse(endpoint.hasSpeech)
        XCTAssertTrue(try endpoint.observe(probability: 0, startSample: 0, sampleCount: 4096).isEmpty)
    }
}
