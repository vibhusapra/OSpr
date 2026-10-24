import Foundation
import CryptoKit

public enum SummarySection: String, Codable, CaseIterable, Sendable {
    case overview, decisions, actions, questions
    public var title: String {
        switch self {
        case .overview: return "Overview"
        case .decisions: return "Decisions"
        case .actions: return "Actions"
        case .questions: return "Open questions"
        }
    }
}

public struct SummaryPoint: Codable, Equatable, Sendable {
    public var section: SummarySection
    public var text: String
    public var sourceIDs: [Int]
    enum CodingKeys: String, CodingKey { case section, text; case sourceIDs = "source_ids" }
    public init(section: SummarySection, text: String, sourceIDs: [Int]) {
        self.section = section; self.text = text; self.sourceIDs = sourceIDs
    }
}

public enum SummarySource: String, Codable, CaseIterable, Sendable {
    case original, edited
    public var title: String { self == .original ? "Original transcript" : "Edited text" }
    public func text(in record: Transcript) -> String { self == .original ? record.rawText : record.text }
}

/// A model's paraphrases and exact supporting quotes. References validate source
/// membership, not entailment, completeness, relevance or speaker attribution.
public struct MeetingSummary: Codable, Equatable, Sendable {
    public var items: [SummaryPoint]
    public var excerpts: [NoteExcerpt]
    public var sourceSHA256: String
    public var model: String
    public var chunks: Int
    public var created: Date
    public let sourceKind: SummarySource
    /// Only edited sources need a snapshot: later text edits must not erase the
    /// evidence or prevent saving the transcript. Original text remains separate.
    public let sourceSnapshot: String?
    private enum CodingKeys: String, CodingKey {
        case items, excerpts, sourceSHA256, model, chunks, created, sourceKind, sourceSnapshot
    }
    public init(source: String, items: [SummaryPoint], excerpts: [NoteExcerpt], model: String, chunks: Int,
                sourceKind: SummarySource = .original) throws {
        self.items = items; self.excerpts = excerpts; self.model = model; self.chunks = chunks
        self.sourceKind = sourceKind; sourceSnapshot = sourceKind == .edited ? source : nil
        sourceSHA256 = Self.digest(source); created = Date()
        guard matches(source) else {
            throw OSprError.message("Summary contained invalid notes or source references. Previous notes and transcript are unchanged.")
        }
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decode([SummaryPoint].self, forKey: .items)
        excerpts = try values.decode([NoteExcerpt].self, forKey: .excerpts)
        sourceSHA256 = try values.decode(String.self, forKey: .sourceSHA256)
        model = try values.decode(String.self, forKey: .model)
        chunks = try values.decode(Int.self, forKey: .chunks)
        created = try values.decode(Date.self, forKey: .created)
        sourceKind = values.contains(.sourceKind) ? try values.decode(SummarySource.self, forKey: .sourceKind) : .original
        sourceSnapshot = try values.decodeIfPresent(String.self, forKey: .sourceSnapshot)
        guard sourceKind == .original ? sourceSnapshot == nil : sourceSnapshot.map({ matches($0) }) == true else {
            throw DecodingError.dataCorruptedError(forKey: .sourceSnapshot, in: values,
                debugDescription: "Summary source metadata or snapshot is invalid.")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(items, forKey: .items); try values.encode(excerpts, forKey: .excerpts)
        try values.encode(sourceSHA256, forKey: .sourceSHA256); try values.encode(model, forKey: .model)
        try values.encode(chunks, forKey: .chunks); try values.encode(created, forKey: .created)
        // Preserve the original summary format for old readers until the edited
        // feature is actually used. Its first save requires the v4 writer fence.
        if sourceKind == .edited {
            try values.encode(sourceKind, forKey: .sourceKind)
            try values.encode(sourceSnapshot, forKey: .sourceSnapshot)
        }
    }
    public static func fromWorker(_ response: [String: Any], source: String,
                                  sourceKind: SummarySource = .original) throws -> MeetingSummary {
        struct Payload: Decodable { var items: [SummaryPoint]; var excerpts: [NoteExcerpt]; var model: String; var chunks: Int }
        do {
            let data = try JSONSerialization.data(withJSONObject: response)
            guard data.count <= 4_000_000 else { throw OSprError.message("Summary response is too large.") }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            return try MeetingSummary(source: source, items: payload.items, excerpts: payload.excerpts, model: payload.model, chunks: payload.chunks, sourceKind: sourceKind)
        } catch {
            throw OSprError.message("Summary contained invalid notes or source references. Previous notes and transcript are unchanged.")
        }
    }
    public func matches(_ source: String) -> Bool {
        guard sourceKind == .original ? sourceSnapshot == nil : sourceSnapshot.map({ $0.utf8.elementsEqual(source.utf8) }) == true else { return false }
        guard sourceSHA256 == Self.digest(source), source.utf16.count <= 200_000,
              (0...20).contains(chunks), (chunks > 0 || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
              !model.isEmpty, model.count <= 256, items.count <= 32, excerpts.count <= 512,
              Set(excerpts.map(\.id)).count == excerpts.count,
              excerpts.allSatisfy({ $0.id >= 0 && !$0.text.isEmpty && $0.text.count <= 1000 && source.range(of: $0.text, options: .literal) != nil }) else { return false }
        let valid = Set(excerpts.map(\.id))
        guard items.allSatisfy({ item in
            !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && item.text.count <= 1000 &&
            item.text.unicodeScalars.allSatisfy { $0.value >= 32 || $0 == "\n" || $0 == "\t" } &&
            (1...512).contains(item.sourceIDs.count) && Set(item.sourceIDs).count == item.sourceIDs.count &&
            Set(item.sourceIDs).isSubset(of: valid)
        }) else { return false }
        func quantities(_ text: String) -> Set<String> {
            let ns = text as NSString
            return Set(Self.numberPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) })
        }
        guard items.allSatisfy({ item in
            let cited = excerpts.filter { item.sourceIDs.contains($0.id) }.map(\.text).joined(separator: " ")
            func temporals(_ text: String) -> Set<String> {
                let value = text.lowercased() as NSString
                return Set(Self.temporalPattern.matches(in: value as String, range: NSRange(location: 0, length: value.length)).map { match in
                    value.substring(with: match.range(at: 1)) + " " + value.substring(with: match.range(at: 2)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
                })
            }
            let protected = temporals(cited)
            let temporalMatches = temporals(item.text).allSatisfy { phrase in
                let target = phrase.split(separator: " ").dropFirst().joined(separator: " ")
                let originals = protected.filter { $0.hasSuffix(" " + target) }
                return originals.isEmpty || originals.contains(phrase)
            }
            return quantities(item.text).isSubset(of: quantities(cited)) && temporalMatches
        }) else { return false }
        return Set(items.flatMap(\.sourceIDs)) == valid
    }
    public func validatesStoredSource(for record: Transcript) -> Bool {
        switch sourceKind {
        case .original: return matches(record.rawText)
        case .edited: return sourceSnapshot.map { matches($0) } == true
        }
    }
    /// Freshness is separate from source validation: stale edited notes remain
    /// valid against their saved snapshot without blocking subsequent text edits.
    public func sourceIsCurrent(in record: Transcript) -> Bool {
        sourceSHA256 == Self.digest(sourceKind.text(in: record))
    }
    public var markdown: String {
        var parts = ["# Meeting summary", "Source: " + sourceKind.title,
            "AI paraphrases with exact-source citations. Citations do not prove correctness or completeness. Review quotes and the full transcript; no task is executed."]
        if sourceKind == .edited {
            parts.append("Uses the edited text captured when this summary was generated. Later transcript edits do not update these notes. Source SHA-256: " + sourceSHA256)
        }
        for section in SummarySection.allCases {
            let points = items.filter { $0.section == section }
            if !points.isEmpty {
                parts.append("## " + section.title)
                parts.append(points.map { point in
                    "- " + point.text + " " + point.sourceIDs.map { "[Source \($0 + 1)](#source-\($0 + 1))" }.joined(separator: " ")
                }.joined(separator: "\n\n"))
            }
        }
        parts.append("## Source quotes")
        parts.append(excerpts.sorted { $0.id < $1.id }.map { "### Source \($0.id + 1)\n\n> " + $0.text.replacingOccurrences(of: "\n", with: "\n> ") }.joined(separator: "\n\n"))
        return parts.joined(separator: "\n\n")
    }
    private static let temporalPattern = try! NSRegularExpression(pattern: #"\b(on|by|before|after|until|at)\s+((?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)|(?:(?:january|february|march|april|may|june|july|august|september|october|november|december)\s+[0-9]{1,2})|(?:[0-9]{1,2}:[0-9]{2}))\b"#)
    private static let numberPattern = try! NSRegularExpression(pattern: #"[+-]?[0-9]+(?:[.,:/-][0-9]+)*%?"#)
    private static func digest(_ source: String) -> String { SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined() }
}
