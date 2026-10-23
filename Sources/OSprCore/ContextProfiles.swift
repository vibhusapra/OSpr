import Foundation

public enum ProfileSpeechModel: String, CaseIterable, Identifiable, Sendable {
    case parakeet = "parakeet-v3", cohere = "cohere-native8", whisperTurbo = "whisper-turbo"
    case whisperSmall = "whisper-small", qwen = "qwen3-asr", nemotron = "nemotron-streaming"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .parakeet: return "Parakeet v3"
        case .cohere: return "Cohere Transcribe"
        case .whisperTurbo: return "Whisper Turbo"
        case .whisperSmall: return "Whisper Small"
        case .qwen: return "Qwen3 ASR"
        case .nemotron: return "Nemotron 3.5"
        }
    }
}

/// Routing uses an exact HTTP(S) origin and a segment-bounded path prefix.
/// Query strings and fragments from a document are discarded at construction.
public struct ProfileSite: Equatable, Sendable {
    public let origin: String
    public let path: String
    public var normalized: String { origin + (path == "/" ? "" : path) }

    public init?(_ value: String, isDocument: Bool = false) {
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !value.isEmpty, value.utf8.count <= 4096,
              value.unicodeScalars.allSatisfy({ !forbidden.contains($0) }),
              var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let url = components.url, let host = url.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              isDocument || (components.query == nil && components.fragment == nil) else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        let port = components.port ?? defaultPort
        guard (1...65535).contains(port) else { return nil }
        var path = components.percentEncodedPath
        guard let decoded = path.removingPercentEncoding, !decoded.contains("\\"),
              !decoded.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        if path.isEmpty { path = "/" }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        // Percent escape spelling is case-insensitive, unlike path characters.
        if path.contains("%") {
            let pattern = try! NSRegularExpression(pattern: "%[0-9a-fA-F]{2}")
            for match in pattern.matches(in: path, range: NSRange(path.startIndex..., in: path)).reversed() {
                if let range = Range(match.range, in: path) { path.replaceSubrange(range, with: path[range].uppercased()) }
            }
        }
        components.scheme = scheme; components.host = host
        components.port = port == defaultPort ? nil : port
        components.path = ""; components.query = nil; components.fragment = nil
        guard let origin = components.string else { return nil }
        self.origin = origin; self.path = path
    }

    public func matches(_ document: ProfileSite) -> Bool {
        origin == document.origin && (path == "/" || document.path == path || document.path.hasPrefix(path + "/"))
    }
}

extension AppProfile {
    public var title: String { name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? bundleID }
    public var validationError: String? {
        let identifierCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        guard !bundleID.isEmpty, bundleID.utf8.count <= 256,
              bundleID.unicodeScalars.allSatisfy({ identifierCharacters.contains($0) }) else {
            return "Choose an app or enter its exact bundle ID."
        }
        if let name, name.count > 80 { return "Use a profile name of at most 80 characters." }
        if let site, ProfileSite(site) == nil { return "Use an HTTP(S) origin and path, without a query, fragment, credentials or dot segments." }
        if let localModel, ProfileSpeechModel(rawValue: localModel) == nil { return "Choose a supported local speech model." }
        if let language, !language.isEmpty {
            if language.count > 32 || language.range(of: "\\A[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\\z", options: .regularExpression) == nil {
                return "Use a language code such as en or en-GB; leave it blank for automatic."
            }
        }
        if let customPrompt, mode != .custom || customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || customPrompt.unicodeScalars.count > 16000 {
            return "A profile instruction needs Custom mode and between 1 and 16,000 characters."
        }
        if let translationLanguage, mode != .translate || translationLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || translationLanguage.count > 80 {
            return "A translation target needs Translate mode and between 1 and 80 characters."
        }
        return nil
    }

    public func hasSameRule(as other: AppProfile) -> Bool {
        guard bundleID == other.bundleID else { return false }
        if site == nil || other.site == nil { return site == nil && other.site == nil }
        guard let a = site.flatMap({ ProfileSite($0) }), let b = other.site.flatMap({ ProfileSite($0) }) else { return false }
        return a == b
    }
}

extension OSprSettings {
    public mutating func upsertProfile(_ profile: AppProfile) throws {
        if let error = profile.validationError { throw OSprError.message(error) }
        guard !profiles.contains(where: { $0.id != profile.id && $0.hasSameRule(as: profile) }) else {
            throw OSprError.message("This app/site rule already exists. Edit its profile instead.")
        }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        else { profiles.append(profile) }
    }

    public func needsProfileDocument(for bundleID: String) -> Bool {
        profiles.contains { $0.enabled && $0.bundleID == bundleID && $0.site != nil && $0.validationError == nil }
    }

    public func profileDocument(for bundleID: String, read: () -> String?) -> ProfileSite? {
        guard needsProfileDocument(for: bundleID), let value = read() else { return nil }
        return ProfileSite(value, isDocument: true)
    }

    public func matchingProfile(for bundleID: String, document: ProfileSite? = nil) -> AppProfile? {
        var fallback: AppProfile?, siteMatch: AppProfile?, specificity = -1
        for profile in profiles where profile.enabled && profile.bundleID == bundleID && profile.validationError == nil {
            if let rule = profile.site.flatMap({ ProfileSite($0) }) {
                if let document, rule.matches(document), rule.path.utf8.count > specificity {
                    siteMatch = profile; specificity = rule.path.utf8.count
                }
            } else if fallback == nil { fallback = profile }
        }
        return siteMatch ?? fallback
    }

    /// A value snapshot for one dictation. The global settings are never mutated.
    /// Provider endpoints, credentials, insertion and retention remain explicit
    /// global choices; profiles only refine mode/local model/language/instruction.
    public func resolvedProfile(for bundleID: String, document: ProfileSite? = nil) -> OSprSettings {
        guard let profile = matchingProfile(for: bundleID, document: document) else { return self }
        var result = self
        result.mode = profile.mode
        if transcriptionProvider == "local", let model = profile.localModel { result.model = model }
        if let language = profile.language { result.language = language }
        if profile.mode == .custom, let prompt = profile.customPrompt { result.customPrompt = prompt }
        if profile.mode == .translate, let target = profile.translationLanguage { result.translationLanguage = target }
        return result
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
