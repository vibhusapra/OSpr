import XCTest
@testable import OSprCore

final class MeetingSummaryTests: XCTestCase {
    private let source = "Do not ship Friday. Priya will send the review on Monday. The price is $12.50, not $15.50. 次は東京です。"
    private func summary() throws -> MeetingSummary {
        try MeetingSummary(source: source, items: [
            .init(section: .decisions, text: "Hold the Friday release.", sourceIDs: [0]),
            .init(section: .actions, text: "Priya to send review Monday.", sourceIDs: [1]),
            .init(section: .overview, text: "Proposed price: $12.50, not $15.50.", sourceIDs: [2])],
            excerpts: [.init(id: 0, text: "Do not ship Friday."), .init(id: 1, text: "Priya will send the review on Monday."), .init(id: 2, text: "The price is $12.50, not $15.50.")], model: "local-fixture", chunks: 1)
    }
    func testParaphrasesKeepExactCitationsHashAndMarkdownAcrossRoundTrip() throws {
        let value = try summary()
        XCTAssertTrue(value.matches(source)); XCTAssertFalse(value.matches(source + "Changed"))
        XCTAssertTrue(value.markdown.contains("## Decisions")); XCTAssertTrue(value.markdown.contains("## Actions"))
        XCTAssertTrue(value.markdown.contains("[Source 3](#source-3)"))
        XCTAssertTrue(value.markdown.contains("> Do not ship Friday."))
        XCTAssertTrue(value.markdown.contains("Citations do not prove"))
        let restored = try JSONDecoder().decode(MeetingSummary.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(restored.items, value.items); XCTAssertEqual(restored.excerpts, value.excerpts)
        XCTAssertTrue(restored.matches(source))
    }
    func testUnknownDuplicateOrFabricatedReferencesCannotBecomeSavedSummary() throws {
        for ids in [[99], [0, 0], []] {
            XCTAssertThrowsError(try MeetingSummary(source: source, items: [.init(section: .actions, text: "Send review.", sourceIDs: ids)], excerpts: [.init(id: 0, text: "Do not ship Friday.")], model: "fixture", chunks: 1))
        }
        XCTAssertThrowsError(try MeetingSummary(source: source, items: [.init(section: .actions, text: "Ship.", sourceIDs: [0])], excerpts: [.init(id: 0, text: "Ship Friday.")], model: "fixture", chunks: 1))
        var value = try summary(); value.excerpts.append(.init(id: 0, text: "Do not ship Friday."))
        XCTAssertFalse(value.matches(source))
    }
    func testUncitedQuantityAndInvalidWorkerPayloadAreRejectedWithoutEchoingIt() throws {
        var value = try summary(); value.items[0].text = "Ship on May 25."
        XCTAssertFalse(value.matches(source))
        value = try summary(); value.items[1].text = "Priya will send review by Monday."
        XCTAssertFalse(value.matches(source))
        value = try summary(); value.items[2].text = "Price is $12.55."
        XCTAssertFalse(value.matches(source))
        for payload: [String: Any] in [["items": "PRIVATE"], ["items": [], "excerpts": [], "model": "fixture", "chunks": true]] {
            XCTAssertThrowsError(try MeetingSummary.fromWorker(payload, source: source)) { error in
                XCTAssertFalse(error.localizedDescription.contains("PRIVATE"))
            }
        }
    }
    func testLegacyTranscriptWithoutSummaryStillDecodesAndNewSummaryDoesNotOverwriteNotes() throws {
        var record = Transcript(rawText: source, text: "Edited", model: "fixture", mode: .clean, duration: 1, latencyMS: 2)
        record.notes = try MeetingNotes(source: source, excerpts: [.init(id: 0, text: "Do not ship Friday.")], model: "extractive")
        let oldData = try JSONEncoder().encode(record)
        XCTAssertNil(try JSONDecoder().decode(Transcript.self, from: oldData).summary)
        record.summary = try summary()
        let restored = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored.notes?.model, "extractive"); XCTAssertEqual(restored.text, "Edited")
        XCTAssertTrue(try XCTUnwrap(restored.summary).matches(source))
    }
    func testMultipleSupportingQuotesRemainBoundedWithoutDroppingEvidence() throws {
        let quotes = (0..<12).map { NoteExcerpt(id: $0, text: "Observation \($0) has no decision.") }
        let source = quotes.map(\.text).joined(separator: " ")
        let value = try MeetingSummary(source: source, items: [.init(section: .overview, text: "General observations with no decision.", sourceIDs: quotes.map(\.id))], excerpts: quotes, model: "fixture", chunks: 1)
        XCTAssertTrue(value.matches(source)); XCTAssertEqual(value.excerpts.count, 12)
        var invalid = value
        invalid.items[0].text = String(repeating: "x", count: 1001)
        XCTAssertFalse(invalid.matches(source))
        invalid = value; invalid.items[0].sourceIDs = Array(0..<513)
        XCTAssertFalse(invalid.matches(source))
    }

    func testCalendarAndClockQualifierSwapsAreRejectedWithoutRejectingBareDeadlines() throws {
        for (source, output) in [("Omar sends results on June 5.", "Omar sends results by June 5."), ("Review starts at 14:00.", "Review starts before 14:00.")] {
            XCTAssertThrowsError(try MeetingSummary(source: source, items: [.init(section: .actions, text: output, sourceIDs: [0])], excerpts: [.init(id: 0, text: source)], model: "fixture", chunks: 1))
        }
        XCTAssertNoThrow(try MeetingSummary(source: "The deadline is June 5.", items: [.init(section: .actions, text: "Review due by June 5.", sourceIDs: [0])], excerpts: [.init(id: 0, text: "The deadline is June 5.")], model: "fixture", chunks: 1))
    }

}
