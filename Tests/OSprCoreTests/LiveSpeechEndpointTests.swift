import XCTest
@testable import OSprCore

final class LiveSpeechEndpointTests: XCTestCase {
    func testCandidateTracksCurrentExaminedFrontierAndResumedSpeechRevokesIt() throws {
        var gate = LiveSpeechEndpoint(configuration: try .init(silenceSeconds: 0.1))
        for i in 0..<3 { try gate.observe(score: 0.8, startSample: i * 512, sampleCount: 512) }
        for i in 3..<7 { try gate.observe(score: 0, startSample: i * 512, sampleCount: 512) }
        XCTAssertEqual(gate.candidate, .init(kind: .finished, boundarySample: 1536, observedThroughSample: 3584))
        try gate.observe(score: 0, startSample: 3584, sampleCount: 11)
        XCTAssertEqual(gate.candidate?.observedThroughSample, 3595)
        try gate.observe(score: 0.35, startSample: 3595, sampleCount: 1)
        XCTAssertNil(gate.candidate)
        XCTAssertEqual(gate.lastSpeechEnd, 3596)
        for i in 0..<4 { try gate.observe(score: 0, startSample: 3596 + i * 512, sampleCount: 512) }
        XCTAssertEqual(gate.candidate?.boundarySample, 3596)
    }
    func testInitialSilenceAndShortBurstsNeverBecomeFinishable() throws {
        var gate = LiveSpeechEndpoint(configuration: try .init(silenceSeconds: 0.1))
        for i in 0..<100 {
            try gate.observe(score: i % 3 == 0 ? 1 : 0, startSample: i * 512, sampleCount: 512)
            XCTAssertNil(gate.candidate)
        }
        XCTAssertFalse(gate.hasSpeech)
    }
    func testFirstFinishMatchesTheFrozenOneShotPolicyIncludingPartialSamples() throws {
        let config = try SpeechEndpoint.Configuration(silenceSeconds: 0.1)
        for count in [1, 160, 511, 512] {
            var old = SpeechEndpoint(configuration: config)
            var live = LiveSpeechEndpoint(configuration: config)
            var position = 0
            var found = false
            let voiceFrames = (1536 + count - 1) / count
            let silenceFrames = (1600 + count - 1) / count
            for i in 0..<voiceFrames + silenceFrames + 2 {
                let p = i < voiceFrames ? 0.8 : 0.0
                let events = try old.observe(probability: p, startSample: position, sampleCount: count)
                try live.observe(score: p, startSample: position, sampleCount: count)
                if let first = events.first(where: { $0.kind == .finished }) {
                    XCTAssertEqual(live.candidate, first)
                    found = true
                    break
                }
                position += count
            }
            XCTAssertTrue(found, "The comparison must actually reach a finish decision")
        }
    }
    func testGapInvalidValueAndDuplicatePoisonCandidates() throws {
        for bad in [Double.nan, .infinity, -1, 1.1] {
            var gate = LiveSpeechEndpoint(configuration: try .init())
            XCTAssertThrowsError(try gate.observe(score: bad, startSample: 0, sampleCount: 512))
            XCTAssertTrue(gate.failed); XCTAssertNil(gate.candidate)
            XCTAssertThrowsError(try gate.observe(score: 1, startSample: 0, sampleCount: 512))
        }
        for offset in [0, 1024] {
            var gate = LiveSpeechEndpoint(configuration: try .init())
            try gate.observe(score: 1, startSample: 0, sampleCount: 512)
            XCTAssertThrowsError(try gate.observe(score: 1, startSample: offset, sampleCount: 512))
        }
        for count in [0, -1, 513, Int.max] {
            var gate = LiveSpeechEndpoint(configuration: try .init())
            XCTAssertThrowsError(try gate.observe(score: 1, startSample: 0, sampleCount: count))
        }
    }
}
