import Foundation

/// A value snapshot for background indexing and action-time stale-result checks.
public struct AudioQuoteRequest: Equatable, Sendable {
    public let recordID: UUID
    public let audioFile: String?
    public let original: String
    public let source: String
    public let excerpts: [NoteExcerpt]
    public let duration: Double
    public let segments: [Segment]
    public let words: [Segment]?
    public init(record: Transcript, source: String, excerpts: [NoteExcerpt]) {
        recordID = record.id; audioFile = record.audioFile; original = record.rawText
        self.source = source; self.excerpts = excerpts; duration = record.duration
        segments = record.segments; words = record.words
    }
    public init(record: Transcript, summary: MeetingSummary) {
        self.init(record: record, source: summary.sourceKind == .original ? record.rawText : summary.sourceSnapshot ?? "", excerpts: summary.excerpts)
    }
    public init(record: Transcript, notes: MeetingNotes) { self.init(record: record, source: record.rawText, excerpts: notes.excerpts) }
}

public struct AudioQuoteTiming: Equatable, Sendable {
    public enum Precision: String, Sendable { case word, segment }
    public let start: Double
    public let end: Double
    public let precision: Precision
    public var label: String {
        let first = AudioTimeline.label(start), last = AudioTimeline.label(end)
        return (first == last ? first : first + "–" + last) + " · " + (precision == .word ? "Word timing" : "Segment estimate")
    }
}

public enum AudioQuoteUnavailable: String, Sendable {
    case editedSource, ambiguousQuote, invalidLocation, noAlignedTiming
    public var explanation: String {
        switch self {
        case .editedSource: return "Edited source has no original audio alignment."
        case .ambiguousQuote: return "Audio time unavailable for this repeated quote."
        case .invalidLocation: return "Source location could not be verified."
        case .noAlignedTiming: return "Matching recognizer timing is unavailable."
        }
    }
}

/// No fuzzy text matching or guessed interpolation. Word timing is used only
/// when the entire ordered word stream matches the original, with whitespace
/// gaps only; otherwise the same check is applied to coarser segments.
public struct AudioQuoteTimeline: Sendable {
    public let request: AudioQuoteRequest
    public private(set) var timings: [Int: AudioQuoteTiming] = [:]
    public private(set) var unavailable: [Int: AudioQuoteUnavailable] = [:]
    private struct Unit { let bytes: Range<Int>; let start: Double; let end: Double }

    public init(_ request: AudioQuoteRequest, cancelled: () -> Bool = { false }) {
        self.request = request
        guard !request.excerpts.isEmpty else { return }
        guard request.original.utf8.elementsEqual(request.source.utf8) else {
            for quote in request.excerpts { unavailable[quote.id] = .editedSource }; return
        }
        guard request.original.utf8.count <= 800_000, request.excerpts.count <= 512,
              Set(request.excerpts.map(\.id)).count == request.excerpts.count else { return }
        let source = Data(request.original.utf8)
        let alignedWords = Self.align(request.words ?? [], source: request.original, duration: request.duration, cancelled: cancelled)
        let aligned = alignedWords ?? Self.align(request.segments, source: request.original, duration: request.duration, cancelled: cancelled)
        let precision: AudioQuoteTiming.Precision = alignedWords == nil ? .segment : .word
        for quote in request.excerpts {
            if cancelled() { return }
            guard quote.id >= 0, !quote.text.isEmpty else { unavailable[quote.id] = .invalidLocation; continue }
            let span: Range<Int>
            switch (quote.sourceStartUTF8, quote.sourceEndUTF8) {
            case let (start?, end?):
                guard start >= 0, end > start, end <= source.count,
                      source[start..<end].elementsEqual(quote.text.utf8) else {
                    unavailable[quote.id] = .invalidLocation; continue
                }
                span = start..<end
            case (nil, nil):
                let needle = Data(quote.text.utf8)
                guard let first = source.range(of: needle) else { unavailable[quote.id] = .invalidLocation; continue }
                if source.range(of: needle, in: (first.lowerBound + 1)..<source.count) != nil {
                    unavailable[quote.id] = .ambiguousQuote; continue
                }
                span = first
            default: unavailable[quote.id] = .invalidLocation; continue
            }
            guard let aligned else { unavailable[quote.id] = .noAlignedTiming; continue }
            let first = Self.lowerBound(aligned.count) { aligned[$0].bytes.upperBound > span.lowerBound }
            let end = Self.lowerBound(aligned.count) { aligned[$0].bytes.lowerBound >= span.upperBound }
            guard first < end else { unavailable[quote.id] = .noAlignedTiming; continue }
            // Ends may overlap (e.g. overlapping speakers); do not assume the
            // last word has the greatest end time.
            let finish = aligned[first..<end].reduce(aligned[first].end) { max($0, $1.end) }
            timings[quote.id] = AudioQuoteTiming(start: aligned[first].start, end: finish, precision: precision)
        }
    }

    private static func lowerBound(_ count: Int, predicate: (Int) -> Bool) -> Int {
        var left = 0, right = count
        while left < right { let middle = left + (right - left) / 2; if predicate(middle) { right = middle } else { left = middle + 1 } }
        return left
    }
    private static func align(_ units: [Segment], source: String, duration: Double, cancelled: () -> Bool) -> [Unit]? {
        guard duration.isFinite, duration > 0, !units.isEmpty, units.count <= 100_000 else { return nil }
        let original = source as NSString
        var cursor = 0, byteCursor = 0, lastStart = -Double.infinity
        var result: [Unit] = []; result.reserveCapacity(units.count)
        for unit in units {
            if cancelled() { return nil }
            let text = unit.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, unit.start.isFinite, unit.end.isFinite,
                  unit.start >= 0, unit.end > unit.start, unit.end <= duration,
                  unit.start >= lastStart else { return nil }
            let match = original.range(of: text, options: .literal, range: NSRange(location: cursor, length: original.length - cursor))
            guard match.location != NSNotFound else { return nil }
            let gap = original.substring(with: NSRange(location: cursor, length: match.location - cursor))
            guard gap.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains),
                  original.substring(with: match).utf8.elementsEqual(text.utf8) else { return nil }
            byteCursor += gap.utf8.count
            let end = byteCursor + text.utf8.count
            result.append(Unit(bytes: byteCursor..<end, start: unit.start, end: unit.end))
            cursor = NSMaxRange(match); byteCursor = end; lastStart = unit.start
        }
        guard original.substring(from: cursor).unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains) else { return nil }
        return result
    }
}

public enum AudioQuotePlayback {
    /// Recheck selection, source evidence, timing and loaded audio at the click,
    /// not just when a background index completed.
    public static func startTime(_ timeline: AudioQuoteTimeline, sourceID: Int, current: Transcript?,
                                 loadedAudioFile: String?, playbackDuration: Double, ready: Bool, blocked: Bool) -> Double? {
        guard !blocked, ready, let current, let name = current.audioFile,
              loadedAudioFile == name, timeline.request.audioFile == name,
              let timing = timeline.timings[sourceID], playbackDuration.isFinite,
              timing.start >= 0, timing.end <= playbackDuration else { return nil }
        let matchesSummary = current.summary.map {
            $0.validatesStoredSource(for: current) && AudioQuoteRequest(record: current, summary: $0) == timeline.request
        } ?? false
        let matchesNotes = current.notes.map {
            $0.matches(current.rawText) && AudioQuoteRequest(record: current, notes: $0) == timeline.request
        } ?? false
        return matchesSummary || matchesNotes ? timing.start : nil
    }
}
