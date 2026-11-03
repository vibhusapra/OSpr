import Foundation
import CryptoKit

public struct NoteExcerpt: Codable, Identifiable, Equatable, Sendable {
    public var id: Int
    public var text: String
    public var sourceStartUTF8: Int?
    public var sourceEndUTF8: Int?
    enum CodingKeys: String, CodingKey { case id, text; case sourceStartUTF8 = "source_start_utf8", sourceEndUTF8 = "source_end_utf8" }
    public init(id: Int, text: String, sourceStartUTF8: Int? = nil, sourceEndUTF8: Int? = nil) {
        self.id = id; self.text = text; self.sourceStartUTF8 = sourceStartUTF8; self.sourceEndUTF8 = sourceEndUTF8
    }
    /// Both coordinates must describe these exact bytes, including Unicode
    /// spelling. Legacy quotes without coordinates retain literal membership.
    func matchesSource(_ source: String, bytes: [UInt8]) -> Bool {
        guard id >= 0, id < Int.max else { return false }
        switch (sourceStartUTF8, sourceEndUTF8) {
        case (nil, nil): return source.range(of: text, options: .literal) != nil
        case let (start?, end?):
            guard start >= 0, end > start, end <= bytes.count else { return false }
            return bytes[start..<end].elementsEqual(text.utf8)
        default: return false
        }
    }
}

/// Extractive notes preserve exact source spans. Relevance and surrounding
/// context still require review; selection is not a complete meeting summary.
public struct MeetingNotes: Codable, Sendable {
    public var excerpts: [NoteExcerpt]
    public var sourceSHA256: String
    public var model: String
    public var created: Date
    public init(source: String, excerpts: [NoteExcerpt], model: String) throws {
        let bytes = Array(source.utf8)
        guard excerpts.count <= 120, Set(excerpts.map(\.id)).count == excerpts.count,
              excerpts.allSatisfy({ !$0.text.isEmpty && $0.text.count <= 1000 && $0.matchesSource(source, bytes: bytes) }) else {
            throw OSprError.message("Notes contained an invalid source excerpt. The transcript is unchanged.")
        }
        self.excerpts = excerpts; self.sourceSHA256 = Self.digest(source); self.model = model; created = Date()
    }
    public static func fromWorker(_ response: [String: Any], source: String) throws -> MeetingNotes {
        struct Payload: Decodable { var excerpts: [NoteExcerpt]; var model: String? }
        do {
            let data = try JSONSerialization.data(withJSONObject: response)
            guard data.count <= 4_000_000 else { throw OSprError.message("Notes response is too large.") }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            return try MeetingNotes(source: source, excerpts: payload.excerpts, model: payload.model ?? "local")
        } catch { throw OSprError.message("Invalid notes response. The transcript is unchanged.") }
    }
    public func matches(_ source: String) -> Bool {
        guard sourceSHA256 == Self.digest(source), excerpts.count <= 120, Set(excerpts.map(\.id)).count == excerpts.count else { return false }
        let bytes = Array(source.utf8)
        return excerpts.allSatisfy { !$0.text.isEmpty && $0.text.count <= 1000 && $0.matchesSource(source, bytes: bytes) }
    }
    public var markdown: String {
        markdown(timings: [:])
    }
    public func markdown(audio: AudioQuoteTimeline) -> String {
        guard sourceSHA256 == Self.digest(audio.request.source), excerpts == audio.request.excerpts else { return markdown }
        return markdown(timings: audio.timings)
    }
    private func markdown(timings: [Int: AudioQuoteTiming]) -> String {
        "# Key excerpts\n\nExact original excerpts selected by a local model. Review the full transcript for context and omissions.\n\n" +
        (timings.isEmpty ? "" : "Times are recognizer estimates in the original recording.\n\n") +
        excerpts.map { quote in
            "- [Source \(quote.id + 1)" + (timings[quote.id].map { " · " + $0.label } ?? "") + "] " + quote.text
        }.joined(separator: "\n\n")
    }
    private static func digest(_ source: String) -> String { SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined() }
}
