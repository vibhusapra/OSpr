import Foundation
import NaturalLanguage

public enum WritingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case verbatim, clean, email, bullets, code, translate, custom, assistant
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .verbatim: return "Verbatim"
        case .clean: return "Clean"
        case .email: return "Email"
        case .bullets: return "Notes"
        case .code: return "Code"
        case .translate: return "Translate"
        case .custom: return "Custom"
        case .assistant: return "Edit selection"
        }
    }
    public var symbol: String {
        switch self {
        case .verbatim: return "waveform"
        case .clean: return "sparkles"
        case .email: return "envelope"
        case .bullets: return "list.bullet"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .translate: return "globe"
        case .custom: return "slider.horizontal.3"
        case .assistant: return "text.cursor"
        }
    }
    public func instruction(custom: String, language: String) -> String {
        switch self {
        case .verbatim: return "Return the transcript unchanged."
        case .clean: return "Remove filler words, false starts and accidental repetitions. Fix punctuation. Preserve the speaker's voice."
        case .email: return "Format as a concise email. Do not invent recipients, greetings, signatures or facts."
        case .bullets: return "Format as concise Markdown notes with bullet points. Preserve all substantive details."
        case .code: return "Format dictated code or technical prose. Preserve identifiers, casing, paths and commands exactly. Output plain text; no code fences."
        case .translate: return "Translate into \(language). Preserve names, numbers and meaning."
        case .custom: return custom
        case .assistant: return "Edit the supplied selected passage according to the dictated editing request. Return only the edited passage."
        }
    }
}

public struct Replacement: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var spoken: String
    public var replacement: String
    public init(id: UUID = UUID(), spoken: String, replacement: String) {
        self.id = id; self.spoken = spoken; self.replacement = replacement
    }
}

public struct AppProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var bundleID: String
    public var mode: WritingMode
    public var enabled: Bool
    public init(id: UUID = UUID(), bundleID: String, mode: WritingMode = .clean, enabled: Bool = true) {
        self.id = id; self.bundleID = bundleID; self.mode = mode; self.enabled = enabled
    }
}

public struct Segment: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public var speaker: Int?
    public var overlapSpeakers: [Int]?
    public init(start: Double, end: Double, text: String, speaker: Int? = nil, overlapSpeakers: [Int]? = nil) { self.start = start; self.end = end; self.text = text; self.speaker = speaker; self.overlapSpeakers = overlapSpeakers }
}

public struct Transcript: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var date: Date = Date()
    public var rawText: String
    public var text: String
    public var model: String
    public var mode: WritingMode
    public var app: String
    public var duration: Double
    public var latencyMS: Double
    public var segments: [Segment]
    public var words: [Segment]?
    public var warning: String?
    public var notes: MeetingNotes?
    public var source: String
    public init(rawText: String, text: String, model: String, mode: WritingMode, app: String = "",
                duration: Double, latencyMS: Double, segments: [Segment] = [], words: [Segment]? = nil, warning: String? = nil, source: String = "dictation") {
        self.rawText = rawText; self.text = text; self.model = model; self.mode = mode; self.app = app
        self.duration = duration; self.latencyMS = latencyMS; self.segments = segments; self.words = words; self.warning = warning; self.source = source
    }
}

public struct OSprSettings: Codable, Sendable {
    public var model = "parakeet-v3"
    public var language = ""
    public var mode: WritingMode = .clean
    public var rewriteProvider = "none" // none, local, ollama, compatible, anthropic
    public var rewriteURL = "http://127.0.0.1:11434/v1"
    public var rewriteModel = "qwen3:1.7b"
    public var transcriptionProvider = "local" // local or compatible
    public var transcriptionURL = "https://api.groq.com/openai/v1"
    public var transcriptionModel = "whisper-large-v3-turbo"
    public var customPrompt = "Make the text clear and concise. Preserve meaning."
    public var translationLanguage = "English"
    public var vocabulary = ""
    public var replacements: [Replacement] = []
    public var profiles: [AppProfile] = []
    public var saveHistory = true
    public var retentionDays = 30 // 0 = forever
    public var autoPaste = true
    public var restoreClipboard = true
    public var allowUnverifiedPaste = false
    public var spokenPunctuation = false
    public var silenceTrim = true
    public var silenceThreshold = 0.003
    public var autoStopSeconds = 0.0
    public var pushToTalk = false
    public var hotkeyCode: UInt32 = 49 // Space
    public var hotkeyModifiers: UInt32 = 6144 // Control + Option, Carbon modifiers
    public var microphoneID = ""
    public var preview = false
    public var speakerLabels = false
    public var launchAtLogin = false
    public var rootPath = ""
    private enum CodingKeys: String, CodingKey { case model, language, mode, rewriteProvider, rewriteURL, rewriteModel, transcriptionProvider, transcriptionURL, transcriptionModel, customPrompt, translationLanguage, vocabulary, replacements, profiles, saveHistory, retentionDays, autoPaste, restoreClipboard, allowUnverifiedPaste, spokenPunctuation, silenceTrim, silenceThreshold, autoStopSeconds, pushToTalk, hotkeyCode, hotkeyModifiers, microphoneID, preview, speakerLabels, launchAtLogin, rootPath }
    public init() {}
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent(type(of: model), forKey: .model) ?? model
        language = try c.decodeIfPresent(type(of: language), forKey: .language) ?? language
        mode = try c.decodeIfPresent(type(of: mode), forKey: .mode) ?? mode
        rewriteProvider = try c.decodeIfPresent(type(of: rewriteProvider), forKey: .rewriteProvider) ?? rewriteProvider
        rewriteURL = try c.decodeIfPresent(type(of: rewriteURL), forKey: .rewriteURL) ?? rewriteURL
        rewriteModel = try c.decodeIfPresent(type(of: rewriteModel), forKey: .rewriteModel) ?? rewriteModel
        transcriptionProvider = try c.decodeIfPresent(type(of: transcriptionProvider), forKey: .transcriptionProvider) ?? transcriptionProvider
        transcriptionURL = try c.decodeIfPresent(type(of: transcriptionURL), forKey: .transcriptionURL) ?? transcriptionURL
        transcriptionModel = try c.decodeIfPresent(type(of: transcriptionModel), forKey: .transcriptionModel) ?? transcriptionModel
        customPrompt = try c.decodeIfPresent(type(of: customPrompt), forKey: .customPrompt) ?? customPrompt
        translationLanguage = try c.decodeIfPresent(type(of: translationLanguage), forKey: .translationLanguage) ?? translationLanguage
        vocabulary = try c.decodeIfPresent(type(of: vocabulary), forKey: .vocabulary) ?? vocabulary
        replacements = try c.decodeIfPresent(type(of: replacements), forKey: .replacements) ?? replacements
        profiles = try c.decodeIfPresent(type(of: profiles), forKey: .profiles) ?? profiles
        saveHistory = try c.decodeIfPresent(type(of: saveHistory), forKey: .saveHistory) ?? saveHistory
        retentionDays = try c.decodeIfPresent(type(of: retentionDays), forKey: .retentionDays) ?? retentionDays
        autoPaste = try c.decodeIfPresent(type(of: autoPaste), forKey: .autoPaste) ?? autoPaste
        restoreClipboard = try c.decodeIfPresent(type(of: restoreClipboard), forKey: .restoreClipboard) ?? restoreClipboard
        allowUnverifiedPaste = try c.decodeIfPresent(Bool.self, forKey: .allowUnverifiedPaste) ?? false
        spokenPunctuation = try c.decodeIfPresent(type(of: spokenPunctuation), forKey: .spokenPunctuation) ?? spokenPunctuation
        silenceTrim = try c.decodeIfPresent(type(of: silenceTrim), forKey: .silenceTrim) ?? silenceTrim
        silenceThreshold = try c.decodeIfPresent(type(of: silenceThreshold), forKey: .silenceThreshold) ?? silenceThreshold
        autoStopSeconds = try c.decodeIfPresent(type(of: autoStopSeconds), forKey: .autoStopSeconds) ?? autoStopSeconds
        pushToTalk = try c.decodeIfPresent(type(of: pushToTalk), forKey: .pushToTalk) ?? pushToTalk
        hotkeyCode = try c.decodeIfPresent(type(of: hotkeyCode), forKey: .hotkeyCode) ?? hotkeyCode
        hotkeyModifiers = try c.decodeIfPresent(type(of: hotkeyModifiers), forKey: .hotkeyModifiers) ?? hotkeyModifiers
        microphoneID = try c.decodeIfPresent(type(of: microphoneID), forKey: .microphoneID) ?? microphoneID
        preview = try c.decodeIfPresent(type(of: preview), forKey: .preview) ?? preview
        speakerLabels = try c.decodeIfPresent(type(of: speakerLabels), forKey: .speakerLabels) ?? speakerLabels
        launchAtLogin = try c.decodeIfPresent(type(of: launchAtLogin), forKey: .launchAtLogin) ?? launchAtLogin
        rootPath = try c.decodeIfPresent(type(of: rootPath), forKey: .rootPath) ?? rootPath
    }
    public func mode(for bundleID: String) -> WritingMode {
        profiles.first(where: { $0.enabled && $0.bundleID == bundleID })?.mode ?? mode
    }
    public func validated() -> OSprSettings {
        var result = self
        result.retentionDays = max(0, min(3650, retentionDays))
        result.silenceThreshold = silenceThreshold.isFinite ? max(0, min(0.1, silenceThreshold)) : 0.003
        result.autoStopSeconds = autoStopSeconds.isFinite ? max(0, min(30, autoStopSeconds)) : 0
        return result
    }
}

public enum TextPipeline {
    public static func process(_ input: String, mode: WritingMode, replacements: [Replacement], spokenPunctuation: Bool, language: String = "") -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Longest phrases first; replacements are applied simultaneously. Expanded
        // snippets must never trigger other replacement rules in the same pass.
        let rules = replacements.filter { !$0.spoken.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.spoken.count > $1.spoken.count }
        if !rules.isEmpty {
            let pattern = "(?i)(?<![\\p{L}\\p{N}_])(?:" + rules.map { NSRegularExpression.escapedPattern(for: $0.spoken) }.joined(separator: "|") + ")(?![\\p{L}\\p{N}_])"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let source = text as NSString
                for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
                    let found = source.substring(with: match.range)
                    if let rule = rules.first(where: { $0.spoken.caseInsensitiveCompare(found) == .orderedSame }),
                       let range = Range(match.range, in: text) { text.replaceSubrange(range, with: rule.replacement) }
                }
            }
        }
        if spokenPunctuation {
            let punctuation = ["new paragraph": "\n\n", "new line": "\n", "question mark": "?", "exclamation mark": "!", "comma": ",", "full stop": ".", "semicolon": ";", "colon": ":"]
            for (phrase, value) in punctuation.sorted(by: { $0.key.count > $1.key.count }) {
                text = text.replacingOccurrences(of: "(?i)\\b" + phrase + "\\b", with: value, options: .regularExpression)
            }
            text = text.replacingOccurrences(of: "[ \\t]+([,.;:!?])", with: "$1", options: .regularExpression)
                .replacingOccurrences(of: "[ \\t]*\\n[ \\t]*", with: "\n", options: .regularExpression)
        }
        if mode == .clean {
            // "um" is an ordinary German/Portuguese word. Limit these English
            // filler rules to confidently identified English, and preserve
            // compounds such as "uh-oh". Verbatim is always available.
            let filler = "(?i)(?<![\\p{L}\\p{N}_'’-])(?:um+|uh+|erm+)(?![\\p{L}\\p{N}_'’-])[, ]*"
            if text.range(of: filler, options: .regularExpression) != nil {
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(text)
                let hint = language.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? ""
                if hint == "en" || (hint.isEmpty && (recognizer.languageHypotheses(withMaximum: 3)[.english] ?? 0) >= 0.8) {
                    text = text.replacingOccurrences(of: filler, with: "", options: .regularExpression)
                }
            }
            text = text.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum TranscriptExport {
    public static func timestamp(_ seconds: Double, separator: String = ",") -> String {
        let value = max(0, Int((seconds.isFinite ? seconds : 0) * 1000))
        return String(format: "%02d:%02d:%02d%@%03d", value / 3600000, value / 60000 % 60,
                      value / 1000 % 60, separator, value % 1000)
    }
    public static func subtitles(_ transcript: Transcript, vtt: Bool = false) -> String {
        let segments = transcript.segments.isEmpty ? [Segment(start: 0, end: transcript.duration, text: transcript.rawText)] : transcript.segments
        return (vtt ? "WEBVTT\n\n" : "") + segments.enumerated().map { i, s in
            let separator = vtt ? "." : ","
            let label = !(s.overlapSpeakers ?? []).isEmpty ? "Overlapping speakers: " : s.speaker.map { "Speaker \($0 + 1): " } ?? ""
            return "\(i + 1)\n\(timestamp(s.start, separator: separator)) --> \(timestamp(s.end, separator: separator))\n\(label)\(s.text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }.joined(separator: "\n")
    }
}
