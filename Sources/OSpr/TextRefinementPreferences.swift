import SwiftUI
import OSprCore

struct TextRefinementPreferences: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Section("Optional text refinement") {
            Picker("Rewrite provider", selection: $model.settings.rewriteProvider) {
                Text("Off · deterministic text rules only").tag("none")
                ForEach(LocalRefinementModel.allCases, id: \.rawValue) { choice in
                    Text(choice.title).tag(choice.rawValue)
                }
                Text("Local Ollama / compatible service").tag("ollama")
                Text("BYOK · OpenAI-compatible API").tag("compatible")
                Text("BYOK · Anthropic Messages API").tag("anthropic")
                Text("BYOK · Google Gemini API").tag("gemini")
                Text("BYOK · Azure v1 API").tag("azure")
            }
            if ["ollama", "compatible", "anthropic", "gemini", "azure"].contains(model.settings.rewriteProvider) {
                ProviderPresetPicker(kind: "rewrite", model: model)
                TextField(model.settings.rewriteProvider == "azure" ? "Azure resource URL or /openai/v1 base" : model.settings.rewriteProvider == "gemini" ? "Base URL, including /v1beta" : "Base URL, including /v1", text: $model.settings.rewriteURL)
                TextField(model.settings.rewriteProvider == "azure" ? "Azure deployment name" : "Model ID", text: $model.settings.rewriteModel)
                SecureField("API key · saved in Keychain", text: $model.rewriteKey)
                Text("Only transcript text and selected-text editing context go to this endpoint. Screen content and clipboard are never read for context.").font(.caption).foregroundStyle(.secondary)
                if model.settings.rewriteProvider == "gemini" {
                    Text("Use the Gemini Developer API base URL and a model ID from your account. Incomplete or blocked responses keep the original text. This option sends text to your configured provider; it does not send audio.").font(.caption).foregroundStyle(.secondary)
                }
                if model.settings.rewriteProvider == "azure" {
                    Text("Use your Azure resource URL and deployment name, which may differ from the model name. This v1 option uses a resource API key, sends text only, and keeps the original on incomplete or blocked replies. Dated deployment URLs and Entra sign-in are not supported here.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let choice = model.settings.localRefinementModel {
                Text(choice == .larger ? "Experimental · 6 GB download shared with meeting summaries. Download in Models, then Prepare on Metal to move first-use work before dictation. Uses more memory than 4B. AI edits can change meaning; originals stay in History." : "First use downloads a quantized language model. Models offers optional preparation with synthetic text before dictating. Refinement adds latency and can change meaning; original transcripts stay available in History.").font(.caption).foregroundStyle(.secondary)
                if choice == .larger { Button("Prepare 9B model in Models") { model.tab = "Models" }.buttonStyle(.link) }
            }
        }
    }
}
