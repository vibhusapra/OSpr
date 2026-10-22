import Foundation
import CryptoKit

public struct NoteExcerpt: Codable, Identifiable, Equatable, Sendable {
    public var id: Int
    public var text: String
    public init(id: Int, text: String) { self.id = id; self.text = text }
}

/// Extractive notes preserve exact source spans. Relevance and surrounding
/// context still require review; selection is not a complete meeting summary.
public struct MeetingNotes: Codable, Sendable {
    public var excerpts: [NoteExcerpt]
    public var sourceSHA256: String
    public var model: String
    public var created: Date
    public init(source: String, excerpts: [NoteExcerpt], model: String) throws {
        guard excerpts.count <= 120, Set(excerpts.map(\.id)).count == excerpts.count,
              excerpts.allSatisfy({ !$0.text.isEmpty && $0.text.count <= 1000 && source.range(of: $0.text, options: .literal) != nil }) else {
            throw OSprError.message("Notes contained an invalid source excerpt. The transcript is unchanged.")
        }
        self.excerpts = excerpts; self.sourceSHA256 = Self.digest(source); self.model = model; created = Date()
    }
    public func matches(_ source: String) -> Bool { sourceSHA256 == Self.digest(source) }
    public var markdown: String {
        "# Key excerpts\n\nExact original excerpts selected by a local model. Review the full transcript for context and omissions.\n\n" +
        excerpts.map { "- [Source \($0.id + 1)] \($0.text)" }.joined(separator: "\n\n")
    }
    private static func digest(_ source: String) -> String { SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined() }
}
