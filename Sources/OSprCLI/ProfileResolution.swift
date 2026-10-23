import Foundation
import OSprCore

enum ProfileResolution {
    static func run(file: URL, bundleID: String, document: String?) throws -> [String: Any] {
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw OSprError.message("Profile settings must be a regular JSON file.")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let maximum = 4 * 1024 * 1024
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw OSprError.message("Profile settings exceed the 4 MiB dry-run limit.") }
        let settings = try JSONDecoder().decode(OSprSettings.self, from: data)
        let context = settings.profileDocument(for: bundleID) { document }
        let profile = settings.matchingProfile(for: bundleID, document: context)
        let effective = settings.resolvedProfile(for: bundleID, document: context)
        return ["match": profile.map { $0.site == nil ? "app" : "site" } ?? "global",
            "profile_id": profile?.id.uuidString as Any? ?? NSNull(),
            "profile_name": profile?.title as Any? ?? NSNull(),
            "document_available": context != nil, "mode": effective.mode.rawValue,
            "speech_provider": effective.transcriptionProvider,
            "speech_model": effective.transcriptionProvider == "local" ? effective.model : effective.transcriptionModel,
            "language": effective.language,
            "instruction": effective.mode.instruction(custom: effective.customPrompt, language: effective.translationLanguage),
            "boundary": "Profile resolution only. No AX lookup, microphone, model loading or provider request. The supplied document URL is not included in the output."]
    }
}
