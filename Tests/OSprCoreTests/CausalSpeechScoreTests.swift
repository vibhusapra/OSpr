import XCTest
@testable import OSprCore

final class CausalSpeechScoreTests: XCTestCase {
    func testRawWindowIsExactIdentity() throws {
        var score = try CausalSpeechScore(windowFrames: 1)
        for p in [0, 1e-30, 0.125, 0.5, 1] { XCTAssertEqual(try score.consume(p), p) }
    }
    func testCausalPrefixAndChronologicalWindowMatchReference() throws {
        let input = [0.01, 0.2, 0.7, 0, 0.05, 0.8, 0.001, 0.33, 0.17, 0.04, 0.19, 0.25, 0.02]
        var score = try CausalSpeechScore()
        for index in input.indices {
            var complement = 1.0
            for p in input[max(0, index - 7)...index] { complement *= 1 - p }
            XCTAssertEqual(try score.consume(input[index]), 1 - complement)
        }
    }
    func testOldActivityExpiresOnEighthSubsequentFrame() throws {
        var score = try CausalSpeechScore()
        XCTAssertEqual(try score.consume(1), 1)
        for _ in 0..<7 { XCTAssertEqual(try score.consume(0), 1) }
        XCTAssertEqual(try score.consume(0), 0)
    }
    func testResetDoesNotCarrySpeechAcrossTakes() throws {
        var score = try CausalSpeechScore()
        _ = try score.consume(1); score.reset()
        XCTAssertEqual(try score.consume(0), 0)
    }
    func testInvalidValuesPoisonUntilReset() throws {
        for value in [Double.nan, .infinity, -.infinity, -0.1, 1.1] {
            var score = try CausalSpeechScore()
            XCTAssertThrowsError(try score.consume(value)); XCTAssertTrue(score.failed)
            XCTAssertThrowsError(try score.consume(0.5))
            score.reset(); XCTAssertEqual(try score.consume(0.5), 0.5)
        }
    }
    func testOnlyPreselectedWindowsAreAccepted() throws {
        for count in [-1, 0, 2, 7, 9, Int.max] { XCTAssertThrowsError(try CausalSpeechScore(windowFrames: count)) }
    }
    func testContinuingWeakEvidenceCanSustainActivityBeyondHistorySpan() throws {
        var scoring = try CausalSpeechScore()
        var endpoint = SpeechEndpoint(configuration: try .init(silenceSeconds: 0.1))
        for index in 0..<100 {
            let score = try scoring.consume(0.1)
            _ = try endpoint.observe(probability: score, startSample: index * 512, sampleCount: 512)
        }
        XCTAssertTrue(endpoint.hasSpeech)
        XCTAssertFalse(endpoint.finished)
    }
}
