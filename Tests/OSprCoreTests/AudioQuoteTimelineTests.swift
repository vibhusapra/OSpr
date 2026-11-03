import XCTest
@testable import OSprCore

final class AudioQuoteTimelineTests: XCTestCase {
    private func record(_ text: String = "One. Two. One.") -> Transcript {
        Transcript(rawText: text, text: text, model: "fixture", mode: .verbatim, duration: 10, latencyMS: 0,
            segments: [.init(start: 1, end: 2, text: "One."), .init(start: 3, end: 4, text: "Two."), .init(start: 7, end: 8, text: "One.")])
    }
    private func quote(_ id: Int, _ text: String, _ start: Int, _ end: Int) -> NoteExcerpt {
        .init(id: id, text: text, sourceStartUTF8: start, sourceEndUTF8: end)
    }
    func testRepeatedQuotesUseValidatedByteOccurrenceAndLegacyAmbiguityHasNoTime() {
        let value = record(), excerpts = [quote(0, "One.", 0, 4), quote(2, "One.", 10, 14), .init(id: 3, text: "One."), .init(id: 1, text: "Two.")]
        let timeline = AudioQuoteTimeline(.init(record: value, source: value.rawText, excerpts: excerpts))
        XCTAssertEqual(timeline.timings[0]?.start, 1); XCTAssertEqual(timeline.timings[2]?.start, 7)
        XCTAssertEqual(timeline.timings[1]?.start, 3); XCTAssertEqual(timeline.unavailable[3], .ambiguousQuote)
        XCTAssertEqual(timeline.timings[2]?.precision, .segment)
    }
    func testUTF8UnicodeAndCombiningSpellingAreNotConfusedWithCharacterOffsets() throws {
        let text = "😀. cafe\u{301}. 東京。"
        let value = Transcript(rawText: text, text: text, model: "fixture", mode: .verbatim, duration: 6, latencyMS: 0,
            segments: [.init(start: 0, end: 1, text: "😀."), .init(start: 2, end: 3, text: "cafe\u{301}."), .init(start: 4, end: 5, text: "東京。")])
        let start = "😀. cafe\u{301}. ".utf8.count
        let excerpts = [quote(0, "東京。", start, text.utf8.count), quote(1, "😀.", 1, 5)]
        let timeline = AudioQuoteTimeline(.init(record: value, source: text, excerpts: excerpts))
        XCTAssertEqual(timeline.timings[0]?.start, 4); XCTAssertEqual(timeline.unavailable[1], .invalidLocation)
        XCTAssertThrowsError(try MeetingNotes(source: text, excerpts: [excerpts[1]], model: "fixture"))
        XCTAssertThrowsError(try MeetingNotes(source: text, excerpts: [.init(id: 0, text: "café.", sourceStartUTF8: 6, sourceEndUTF8: 13)], model: "fixture"))
    }
    func testWordTimingPreferredAndWholeStreamMismatchFallsBackToSegments() {
        var value = record("Hello world."); value.segments = [.init(start: 1, end: 5, text: value.rawText)]
        value.words = [.init(start: 1, end: 2, text: " Hello"), .init(start: 3, end: 4, text: "world.")]
        let excerpts = [quote(0, "world.", 6, 12)]
        var timeline = AudioQuoteTimeline(.init(record: value, source: value.rawText, excerpts: excerpts))
        XCTAssertEqual(timeline.timings[0]?.start, 3); XCTAssertEqual(timeline.timings[0]?.precision, .word)
        value.words?[1].text = "world" // Unmapped punctuation is not guessed.
        timeline = AudioQuoteTimeline(.init(record: value, source: value.rawText, excerpts: excerpts))
        XCTAssertEqual(timeline.timings[0]?.start, 1); XCTAssertEqual(timeline.timings[0]?.precision, .segment)
        value.segments[0].text = "Different text."
        timeline = AudioQuoteTimeline(.init(record: value, source: value.rawText, excerpts: excerpts))
        XCTAssertNil(timeline.timings[0]); XCTAssertEqual(timeline.unavailable[0], .noAlignedTiming)
    }
    func testNoTimingForEditedSourceAndInvalidOrUnorderedTimes() {
        let excerpt = NoteExcerpt(id: 0, text: "One.")
        let edited = AudioQuoteTimeline(.init(record: record(), source: "Edited. One.", excerpts: [excerpt]))
        XCTAssertEqual(edited.unavailable[0], .editedSource)
        for bad in [Segment(start: .nan, end: 2, text: "One."), .init(start: 1, end: .infinity, text: "One."), .init(start: -1, end: 2, text: "One."), .init(start: 1, end: 11, text: "One."), .init(start: 2, end: 1, text: "One.")] {
            var value = record("One."); value.segments = [bad]
            XCTAssertTrue(AudioQuoteTimeline(.init(record: value, source: value.rawText, excerpts: [excerpt])).timings.isEmpty)
        }
        var value = record(); value.segments[2].start = 0
        XCTAssertTrue(AudioQuoteTimeline(.init(record: value, source: value.rawText, excerpts: [excerpt])).timings.isEmpty)
    }
    func testOverlappingEndsAndWhitespaceGapsArePreservedWithoutInterpolation() {
        var value = record(" One.\nTwo. ")
        value.segments = [.init(start: 1, end: 8, text: "One."), .init(start: 3, end: 4, text: "Two.")]
        let timeline = AudioQuoteTimeline(.init(record: value, source: value.rawText, excerpts: [.init(id: 0, text: "One.\nTwo.")]))
        XCTAssertEqual(timeline.timings[0]?.start, 1); XCTAssertEqual(timeline.timings[0]?.end, 8)
    }
    func testMalformedCoordinatesRejectSummaryAndNotesWithoutChangingLegacyEncoding() throws {
        let source = "One."
        for excerpt in [NoteExcerpt(id: 0, text: source, sourceStartUTF8: 0), quote(0, source, -1, 3), quote(0, source, 0, Int.max), NoteExcerpt(id: Int.max, text: source), NoteExcerpt(id: -1, text: source)] {
            XCTAssertThrowsError(try MeetingSummary(source: source, items: [.init(section: .overview, text: source, sourceIDs: [0])], excerpts: [excerpt], model: "fixture", chunks: 1))
            XCTAssertThrowsError(try MeetingNotes(source: source, excerpts: [excerpt], model: "fixture"))
        }
        let legacy = NoteExcerpt(id: 0, text: source)
        let data = try JSONEncoder().encode(legacy), fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["id", "text"])
        XCTAssertEqual(try JSONDecoder().decode(NoteExcerpt.self, from: data), legacy)
        let located = quote(0, source, 0, 4)
        XCTAssertEqual(try JSONDecoder().decode(NoteExcerpt.self, from: JSONEncoder().encode(located)), located)
        for payload: [String: Any] in [["excerpts": [["id": true, "text": source]]], ["excerpts": [["id": 0, "text": source, "source_start_utf8": true, "source_end_utf8": 4]]]] {
            XCTAssertThrowsError(try MeetingNotes.fromWorker(payload, source: source))
        }
    }
    func testCopiedMarkdownUsesOnlySourceBoundTimingAndPreservesQuoteText() throws {
        let value = record("One.")
        let excerpts = [quote(0, "One.", 0, 4)]
        let summary = try MeetingSummary(source: value.rawText, items: [.init(section: .overview, text: "One.", sourceIDs: [0])], excerpts: excerpts, model: "fixture", chunks: 1)
        let notes = try MeetingNotes(source: value.rawText, excerpts: excerpts, model: "fixture")
        let audio = AudioQuoteTimeline(.init(record: value, source: value.rawText, excerpts: excerpts))
        // record("One.") has three unmatched segments, so no time is invented.
        XCTAssertEqual(summary.markdown(audio: audio), summary.markdown)
        var timed = value; timed.segments = [.init(start: 1, end: 2, text: "One.")]
        let aligned = AudioQuoteTimeline(.init(record: timed, source: timed.rawText, excerpts: excerpts))
        XCTAssertTrue(summary.markdown(audio: aligned).contains("0:01–0:02 · Segment estimate"))
        XCTAssertTrue(notes.markdown(audio: aligned).contains("One."))
        let different = AudioQuoteTimeline(.init(record: timed, source: "Other.", excerpts: [.init(id: 0, text: "Other.")]))
        XCTAssertEqual(summary.markdown(audio: different), summary.markdown)
    }
    func testLargeOrderedTimelineResolvesLateRepeatedOccurrenceAndCancellation() {
        var value = record(String(repeating: "word ", count: 10_000))
        value.duration = 10_001; value.segments = (0..<10_000).map { .init(start: Double($0), end: Double($0 + 1), text: "word") }
        let request = AudioQuoteRequest(record: value, source: value.rawText, excerpts: [quote(0, "word", 49_995, 49_999)])
        XCTAssertEqual(AudioQuoteTimeline(request).timings[0]?.start, 9_999)
        XCTAssertTrue(AudioQuoteTimeline(request, cancelled: { true }).timings.isEmpty)
    }
    func testPlaybackRequiresLiveSelectionSourceAudioAndTransportReadiness() throws {
        var value = record("One."); value.audioFile = value.id.uuidString + ".wav"
        value.segments = [.init(start: 1, end: 2, text: "One.")]
        value.summary = try MeetingSummary(source: value.rawText, items: [.init(section: .overview, text: "One.", sourceIDs: [0])],
            excerpts: [quote(0, "One.", 0, 4)], model: "fixture", chunks: 1)
        let timeline = AudioQuoteTimeline(.init(record: value, summary: try XCTUnwrap(value.summary)))
        func start(_ current: Transcript?, file: String? = nil, duration: Double = 10, ready: Bool = true, blocked: Bool = false) -> Double? {
            AudioQuotePlayback.startTime(timeline, sourceID: 0, current: current, loadedAudioFile: file ?? value.audioFile,
                                         playbackDuration: duration, ready: ready, blocked: blocked)
        }
        XCTAssertEqual(start(value), 1)
        XCTAssertNil(start(nil)); XCTAssertNil(start(value, file: "other.wav")); XCTAssertNil(start(value, duration: 1.5))
        XCTAssertNil(start(value, duration: .nan)); XCTAssertNil(start(value, ready: false)); XCTAssertNil(start(value, blocked: true))
        var changed = value; changed.id = UUID(); XCTAssertNil(start(changed))
        changed = value; changed.summary = nil; XCTAssertNil(start(changed))
        changed = value; changed.rawText = "Changed."; XCTAssertNil(start(changed))
        changed = value; changed.segments[0].start = 0.5; XCTAssertNil(start(changed))
        changed = value; changed.audioFile = nil; XCTAssertNil(start(changed))
    }
    func testExtractivePlaybackUsesTheSameGuardAndEditedSnapshotCanAlignOnlyWhenIdentical() throws {
        var value = record("One."); value.audioFile = value.id.uuidString + ".wav"; value.segments = [.init(start: 1, end: 2, text: "One.")]
        value.notes = try MeetingNotes(source: value.rawText, excerpts: [quote(0, "One.", 0, 4)], model: "fixture")
        let audio = AudioQuoteTimeline(.init(record: value, notes: try XCTUnwrap(value.notes)))
        XCTAssertEqual(AudioQuotePlayback.startTime(audio, sourceID: 0, current: value, loadedAudioFile: value.audioFile, playbackDuration: 10, ready: true, blocked: false), 1)
        var changed = value; changed.notes?.excerpts[0].sourceEndUTF8 = 3
        XCTAssertNil(AudioQuotePlayback.startTime(audio, sourceID: 0, current: changed, loadedAudioFile: value.audioFile, playbackDuration: 10, ready: true, blocked: false))
        let summary = try MeetingSummary(source: value.rawText, items: [.init(section: .overview, text: "One.", sourceIDs: [0])], excerpts: [quote(0, "One.", 0, 4)], model: "fixture", chunks: 1, sourceKind: .edited)
        XCTAssertEqual(AudioQuoteTimeline(.init(record: value, summary: summary)).timings[0]?.start, 1)
        let edited = try MeetingSummary(source: "Edited. One.", items: [.init(section: .overview, text: "One.", sourceIDs: [1])], excerpts: [.init(id: 1, text: "One.")], model: "fixture", chunks: 1, sourceKind: .edited)
        XCTAssertEqual(AudioQuoteTimeline(.init(record: value, summary: edited)).unavailable[1], .editedSource)
    }
}
