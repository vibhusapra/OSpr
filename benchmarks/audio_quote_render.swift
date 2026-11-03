// Offscreen production label layouts; no native app, clicks or playback.
import AppKit
import SwiftUI
import XCTest
@testable import OSpr
@testable import OSprCore

final class AudioQuoteRenderTemporary: XCTestCase {
    @MainActor func testLayouts() throws {
        guard let path = ProcessInfo.processInfo.environment["OSPR_QUOTE_RENDER_ROOT"] else { throw XCTSkip("Explicit offscreen render only") }
        let output = URL(fileURLWithPath: path), text = "Review the launch plan."
        var record = Transcript(rawText: text, text: text, model: "fixture", mode: .verbatim, duration: 60, latencyMS: 0,
            segments: [.init(start: 12, end: 18, text: text)], words: [.init(start: 12, end: 13, text: "Review"), .init(start: 14, end: 15, text: "the"), .init(start: 15, end: 16, text: "launch"), .init(start: 17, end: 18, text: "plan.")])
        record.audioFile = record.id.uuidString + ".wav"
        let excerpt = NoteExcerpt(id: 0, text: text, sourceStartUTF8: 0, sourceEndUTF8: text.utf8.count)
        let word = AudioQuoteTimeline(.init(record: record, source: text, excerpts: [excerpt]))
        record.words = nil
        let segment = AudioQuoteTimeline(.init(record: record, source: text, excerpts: [excerpt]))
        record.audioFile = nil
        let noAudio = AudioQuoteTimeline(.init(record: record, source: text, excerpts: [excerpt]))
        let edited = AudioQuoteTimeline(.init(record: record, source: "Updated launch plan.", excerpts: [excerpt]))
        record.rawText = text + " " + text
        let repeated = AudioQuoteTimeline(.init(record: record, source: record.rawText, excerpts: [.init(id: 0, text: text)]))
        XCTAssertEqual(word.timings[0]?.precision, .word); XCTAssertEqual(segment.timings[0]?.precision, .segment)
        for (name, scheme, width) in [("light", ColorScheme.light, 700.0), ("dark", .dark, 700.0), ("compact", .light, 390.0)] {
            let body = VStack(alignment: .leading, spacing: 18) {
                Text("Review a source in its recording").font(.title2.weight(.semibold))
                Text("Source quotes stay exact. Recognizer times are estimates.").font(.callout).foregroundStyle(.secondary)
                ForEach(Array([("Word timestamps", word, true), ("Segment fallback", segment, true), ("Audio loading · disabled", segment, false), ("Audio was not retained", noAudio, false), ("Edited source", edited, false), ("Legacy repeated quote", repeated, false)].enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(row.0).font(.caption2).foregroundStyle(.secondary)
                        QuoteAudioLabel(id: 0, audio: row.1, canPlay: row.2)
                        Text(text).font(.callout)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Component fixtures only; no native playback acceptance.").font(.caption2).foregroundStyle(.secondary)
            }.padding(24).frame(width: width).environment(\.colorScheme, scheme).tint(.osprPurple).background(Color.canvas)
            let view = NSHostingView(rootView: body); view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            view.frame = NSRect(origin: .zero, size: view.fittingSize); view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("quote-audio-" + name + ".png"))
        }
    }
}
