import Foundation

/// A conservative tripwire, not a semantic correctness proof. Clean mode is
/// allowed to delete fillers and disfluencies; it must not summarize the passage.
public enum RewriteGuard {
    private static let specialLatin = try! NSRegularExpression(pattern: "[\\p{Latin}&&[^\\p{ASCII}]]|\\p{Latin}\\p{M}")
    public static func rejection(original: String, rewritten: String, mode: WritingMode) -> String? {
        guard !rewritten.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "The rewrite was empty." }
        guard mode == .clean || mode == .email || mode == .bullets || mode == .code else { return nil }
        func tokens(_ text: String) -> [String] {
            text.precomposedStringWithCanonicalMapping.lowercased().replacingOccurrences(of: "’", with: "'")
                .replacingOccurrences(of: "‘", with: "'").replacingOccurrences(of: "ʼ", with: "'")
                .split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
        }
        let source = tokens(original), output = tokens(rewritten)
        // Preserve accented/special Latin spellings, including repeated names.
        // This is a lexical tripwire, not named-entity or semantic validation.
        // The second alternative covers a Latin letter with combining marks
        // (e.g. the lowercase form of Turkish capital dotted I).
        func specialSpellings(_ words: [String]) -> [String: Int] {
            words.reduce(into: [:]) { counts, word in
                guard word.utf8.contains(where: { $0 >= 128 }) else { return }
                if specialLatin.firstMatch(in: word, range: NSRange(word.startIndex..., in: word)) != nil {
                    counts[word, default: 0] += 1
                }
            }
        }
        if specialSpellings(source) != specialSpellings(output) {
            return "The rewrite changed an accented or special spelling. Original retained for review."
        }
        let fillers: Set<String> = ["um", "uh", "erm", "hmm"]
        let significant = source.filter { !fillers.contains($0) }
        if mode == .clean && significant.count >= 8 {
            var counts = output.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            let kept = significant.reduce(0) { count, word in
                if counts[word, default: 0] > 0 { counts[word, default: 0] -= 1; return count + 1 }
                return count
            }
            if Double(kept) / Double(significant.count) < 0.72 { return "The rewrite removed too much content." }
        }
        if mode == .clean {
            if output.count > max(16, significant.count * 2) { return "The rewrite added too much content." }
            if original.contains(where: { $0 == "?" || $0 == "？" }) && !rewritten.contains(where: { $0 == "?" || $0 == "？" }) {
                return "The rewrite removed a question. Original retained for review."
            }
        }
        let negations: Set<String> = ["not", "no", "never", "without", "don't", "doesn't", "didn't", "can't", "cannot", "won't", "shouldn't", "isn't", "aren't", "wasn't", "weren't", "haven't", "hasn't", "hadn't", "couldn't", "wouldn't", "mustn't", "needn't"]
        let sourceNegations = source.filter { negations.contains($0) }.count
        let outputNegations = output.filter { negations.contains($0) }.count
        if sourceNegations != outputNegations {
            return "The rewrite changed a negation. Original retained for review."
        }
        func numberCounts(_ words: [String]) -> [String: Int] {
            words.filter { $0.allSatisfy(\.isNumber) }.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }
        if numberCounts(source) != numberCounts(output) {
            return "The rewrite changed a number. Original retained for review."
        }
        return nil
    }
}
