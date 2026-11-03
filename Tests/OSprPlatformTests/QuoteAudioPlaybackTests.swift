import XCTest
import AVFoundation
@testable import OSpr
@testable import OSprCore

final class QuoteAudioPlaybackTests: XCTestCase {
    @MainActor private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Quote playback state did not settle")
    }
    @MainActor func testStoredQuoteLocationsDriveRealSilentTransportAndStaleSelectionCannotSeek() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-quote-transport-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppModel(instanceLock: try AppInstanceLock(directory: directory), directory: directory, enableServices: false)
        try await settle { !app.audioMaintenance }
        var record = Transcript(rawText: "One. Two. One.", text: "Edited text stays separate.", model: "fixture", mode: .verbatim,
            duration: 4, latencyMS: 0, segments: [.init(start: 0, end: 1, text: "One."), .init(start: 1, end: 2, text: "Two."), .init(start: 3, end: 4, text: "One.")])
        let quote = NoteExcerpt(id: 2, text: "One.", sourceStartUTF8: 10, sourceEndUTF8: 14)
        record.summary = try MeetingSummary(source: record.rawText, items: [.init(section: .overview, text: "One.", sourceIDs: [2])], excerpts: [quote], model: "fixture", chunks: 1)
        record.notes = try MeetingNotes.fromWorker(["excerpts": [["id": 2, "text": "One.", "source_start_utf8": 10, "source_end_utf8": 14]], "model": "fixture"], source: record.rawText)
        record.audioFile = record.id.uuidString + ".wav"
        let url = directory.appendingPathComponent(try XCTUnwrap(record.audioFile))
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64000)); buffer.frameLength = 64000
        for index in 0..<64000 { buffer.floatChannelData?[0][index] = 0 } // Deliberately silent, including play:true.
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings); try file?.write(from: buffer); file = nil
        app.historyState.submit(record, select: true); try await app.historyState.flush()
        let saved = try XCTUnwrap(try HistoryDatabase(directory: directory).record(id: record.id))
        XCTAssertEqual(saved.notes?.excerpts, [quote]); XCTAssertEqual(saved.summary?.excerpts, [quote])
        await app.audioReview.load(url); try await settle { app.audioReview.ready || !app.audioReview.error.isEmpty }
        XCTAssertTrue(app.audioReview.ready, app.audioReview.error)
        for request in [AudioQuoteRequest(record: saved, summary: try XCTUnwrap(saved.summary)), .init(record: saved, notes: try XCTUnwrap(saved.notes))] {
            let audio = AudioQuoteTimeline(request)
            app.playQuote(audio, sourceID: 2); XCTAssertEqual(app.audioReview.position, 3); app.audioReview.pause()
            app.audioReview.seek(to: 0)
            app.phase = "starting"; app.playQuote(audio, sourceID: 2); XCTAssertEqual(app.audioReview.position, 0); app.phase = "idle"
        }
        let old = AudioQuoteTimeline(.init(record: saved, summary: try XCTUnwrap(saved.summary)))
        let other = Transcript(rawText: "Other.", text: "Other.", model: "fixture", mode: .verbatim, duration: 4, latencyMS: 0)
        app.historyState.submit(other, select: true)
        app.playQuote(old, sourceID: 2); XCTAssertEqual(app.audioReview.position, 0)
        app.audioReview.stop(); app.playQuote(old, sourceID: 2); XCTAssertFalse(app.audioReview.playing)
        try await app.prepareForTermination()
    }
}
