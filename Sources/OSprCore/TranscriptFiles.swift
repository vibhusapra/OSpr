import Foundation

public enum TranscriptFileFormat: String, CaseIterable, Sendable { case txt, json, srt, vtt }

extension Transcript {
    public var sourceName: String {
        let leaf = source.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        let name = leaf.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format }
        let cleaned = String(String.UnicodeScalarView(name)).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Dictation" : cleaned
    }
}

extension TranscriptExport {
    public static func filename(_ record: Transcript, format: TranscriptFileFormat) -> String {
        let source = (record.sourceName as NSString).deletingPathExtension
        var stem = ""
        for scalar in source.unicodeScalars {
            let value = CharacterSet.alphanumerics.contains(scalar) || " -_".unicodeScalars.contains(scalar) ? String(scalar) : "-"
            if stem.utf8.count + value.utf8.count > 120 { break }
            stem += value
        }
        stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
        if stem.isEmpty { stem = "OSpr transcript" }
        return stem + "-" + record.id.uuidString.lowercased() + "." + format.rawValue
    }

    public static func data(_ record: Transcript, format: TranscriptFileFormat) throws -> Data {
        switch format {
        case .json:
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(record)
        case .srt, .vtt: return Data(subtitles(record, vtt: format == .vtt).utf8)
        case .txt: return Data(record.text.utf8)
        }
    }
}
