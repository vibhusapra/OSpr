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

/// A model's paraphrases and exact supporting quotes. References validate source
/// membership, not entailment, completeness, relevance or speaker attribution.
public struct MeetingSummary: Codable, Sendable {
    public var items: [SummaryPoint]
    public var excerpts: [NoteExcerpt]
    public var sourceSHA256: String
    public var model: String
    public var chunks: Int
    public var created: Date
    public init(source: String, items: [SummaryPoint], excerpts: [NoteExcerpt], model: String, chunks: Int) throws {
        self.items = items; self.excerpts = excerpts; self.model = model; self.chunks = chunks
        sourceSHA256 = Self.digest(source); created = Date()
        guard matches(source) else {
            throw OSprError.message("Summary contained invalid notes or source references. Previous notes and transcript are unchanged.")
        }
    }
    public static func fromWorker(_ response: [String: Any], source: String) throws -> MeetingSummary {
        struct Payload: Decodable { var items: [SummaryPoint]; var excerpts: [NoteExcerpt]; var model: String; var chunks: Int }
        do {
            let data = try JSONSerialization.data(withJSONObject: response)
            guard data.count <= 4_000_000 else { throw OSprError.message("Summary response is too large.") }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            return try MeetingSummary(source: source, items: payload.items, excerpts: payload.excerpts, model: payload.model, chunks: payload.chunks)
        } catch {
            throw OSprError.message("Summary contained invalid notes or source references. Previous notes and transcript are unchanged.")
        }
    }
    public func matches(_ source: String) -> Bool {
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
    public var markdown: String {
        var parts = ["# Meeting summary", "AI paraphrases with exact-source citations. Citations do not prove correctness or completeness. Review quotes and the full transcript; no task is executed."]
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
