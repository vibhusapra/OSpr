import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OSprCore

struct ContextProfileEditor: View {
    private let id: UUID
    let localSpeech: Bool
    let rewriteEnabled: Bool
    let save: (AppProfile) throws -> Void
    let close: () -> Void
    @State private var name: String
    @State private var bundleID: String
    @State private var mode: WritingMode
    @State private var enabled: Bool
    @State private var useSite: Bool
    @State private var site: String
    @State private var localModel: String
    @State private var overrideLanguage: Bool
    @State private var language: String
    @State private var overridePrompt: Bool
    @State private var prompt: String
    @State private var overrideTranslation: Bool
    @State private var translation: String
    @State private var error = ""

    init(profile: AppProfile, localSpeech: Bool, rewriteEnabled: Bool, globalTranslation: String,
         close: @escaping () -> Void, save: @escaping (AppProfile) throws -> Void) {
        id = profile.id; self.localSpeech = localSpeech; self.rewriteEnabled = rewriteEnabled; self.save = save; self.close = close
        _name = State(initialValue: profile.name ?? ""); _bundleID = State(initialValue: profile.bundleID)
        _mode = State(initialValue: profile.mode); _enabled = State(initialValue: profile.enabled)
        _useSite = State(initialValue: profile.site != nil); _site = State(initialValue: profile.site ?? "")
        _localModel = State(initialValue: profile.localModel ?? "")
        _overrideLanguage = State(initialValue: profile.language != nil); _language = State(initialValue: profile.language ?? "")
        _overridePrompt = State(initialValue: profile.customPrompt != nil); _prompt = State(initialValue: profile.customPrompt ?? "")
        _overrideTranslation = State(initialValue: profile.translationLanguage != nil)
        _translation = State(initialValue: profile.translationLanguage ?? globalTranslation)
    }

    private var profile: AppProfile {
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let siteText = site.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppProfile(id: id, bundleID: bundleID.trimmingCharacters(in: .whitespacesAndNewlines), mode: mode, enabled: enabled,
            name: displayName.isEmpty ? nil : displayName,
            site: useSite ? (ProfileSite(siteText)?.normalized ?? siteText) : nil,
            localModel: localModel.isEmpty ? nil : localModel,
            language: overrideLanguage ? language.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            customPrompt: mode == .custom && overridePrompt ? prompt : nil,
            translationLanguage: mode == .translate && overrideTranslation ? translation.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { VStack(alignment: .leading, spacing: 5) { Text("Make dictation fit your work.").font(.title2.bold()); Text("A profile applies to one app, with an optional site rule.").foregroundStyle(.secondary) }; Spacer() }
            ScrollView { VStack(alignment: .leading, spacing: 20) {
                Card { VStack(alignment: .leading, spacing: 12) {
                    Label("Application", systemImage: "app").font(.headline)
                    TextField("Profile name (optional)", text: $name)
                    HStack { TextField("App bundle ID", text: $bundleID); Button("Choose app…", action: chooseApp) }
                    Toggle("Enable this profile", isOn: $enabled)
                } }
                Card { VStack(alignment: .leading, spacing: 12) {
                    Label("Site", systemImage: "globe").font(.headline)
                    Toggle("Match a site in this app", isOn: $useSite)
                    if useSite {
                        TextField("https://example.com/project", text: $site)
                        Text("Exact origin and an optional path prefix. Queries and fragments are ignored in the active document; leave them out of the rule. Accessibility reads only document URL metadata when this app has an enabled site rule. If unavailable, the app rule or global mode applies.").font(.caption).foregroundStyle(.secondary)
                    }
                } }
                Card { VStack(alignment: .leading, spacing: 12) {
                    Label("Dictation", systemImage: "waveform").font(.headline)
                    Picker("Writing mode", selection: $mode) { ForEach(WritingMode.allCases) { Text($0.title).tag($0) } }
                    Picker("Local speech model", selection: $localModel) {
                        Text("Use global model").tag("")
                        ForEach(ProfileSpeechModel.allCases) { Text($0.title).tag($0.rawValue) }
                    }.disabled(!localSpeech)
                    if !localSpeech { Text("Choose Local MLX in Settings to use local-model overrides.").font(.caption).foregroundStyle(.secondary) }
                    Toggle("Override language hint", isOn: $overrideLanguage)
                    if overrideLanguage { TextField("Language code; blank for automatic", text: $language) }
                    Text("Cohere uses English when the language hint is blank. Model weights download on first use.").font(.caption).foregroundStyle(.secondary)
                    if mode == .custom {
                        Toggle("Use an instruction for this profile", isOn: $overridePrompt)
                        if overridePrompt { TextEditor(text: $prompt).font(.body).frame(minHeight: 100).padding(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary)).accessibilityLabel("Profile custom instruction") }
                    }
                    if mode == .translate {
                        Toggle("Override translation language", isOn: $overrideTranslation)
                        if overrideTranslation { TextField("Translate into", text: $translation) }
                    }
                } }
            }.textFieldStyle(.roundedBorder) }
            if let validation = profile.validationError, !bundleID.isEmpty {
                Label { Text(validation) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            } else if !rewriteEnabled && ![WritingMode.clean, .verbatim].contains(mode) {
                Label { Text("Choose a rewrite provider in Settings to apply this writing mode.") }
                    icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("profile-save-error") }
            HStack { Button("Cancel", action: close).keyboardShortcut(.cancelAction); Spacer(); Button("Save profile") {
                do { try save(profile); close() } catch { self.error = error.localizedDescription }
            }.keyboardShortcut(.defaultAction).disabled(profile.validationError != nil) }
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url, let app = Bundle(url: url), let identifier = app.bundleIdentifier else { return }
        bundleID = identifier
        if name.isEmpty { name = app.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent }
    }
}
