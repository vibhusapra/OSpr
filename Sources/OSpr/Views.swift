import SwiftUI
import AppKit
import AVFoundation
import OSprCore

extension Color {
    static let osprPurple = Color(red: 0.39, green: 0.26, blue: 0.82)
    static let osprInk = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.70, green: 0.62, blue: 1, alpha: 1) : NSColor(red: 0.39, green: 0.26, blue: 0.82, alpha: 1)
    })
    static let canvas = Color(nsColor: .windowBackgroundColor)
}

struct WorkspaceView: View {
    @ObservedObject var model: AppModel
    let tabs = [("Studio", "waveform"), ("History", "clock"), ("Models", "cpu"), ("Dictionary", "text.book.closed"),
                ("Modes", "slider.horizontal.3"), ("Settings", "gearshape"), ("Research", "chart.bar.xaxis")]
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").font(.title2.weight(.bold)).foregroundStyle(.white).frame(width: 38, height: 38).background(Color.osprPurple, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 1) { Text("OSpr").font(.title2.weight(.bold)); Text("OPEN VOICE").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(.secondary) }
                }.padding(.top, 20)
                VStack(spacing: 5) {
                    ForEach(tabs, id: \.0) { title, icon in
                        Button { model.tab = title } label: {
                            HStack(spacing: 12) { Image(systemName: icon).frame(width: 20); Text(title); Spacer() }
                                .font(.system(size: 13, weight: model.tab == title ? .semibold : .regular))
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .foregroundStyle(model.tab == title ? Color.osprInk : Color.primary)
                                .background(model.tab == title ? Color.osprPurple.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 9) {
                    Label(model.localOnly ? "Local by choice" : "Cloud enabled", systemImage: model.localOnly ? "lock.shield" : "network")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(model.localOnly ? .green : .orange)
                    Text("No account. No limits.\nBuilt to belong to you.").font(.caption).foregroundStyle(.secondary).lineSpacing(3)
                    Text("v0.1 · Apple Silicon").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }.padding(.horizontal, 18).padding(.bottom, 20).frame(width: 195).background(.regularMaterial)
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text(model.tab).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    HStack(spacing: 6) { Circle().fill(model.phase == "recording" ? .red : Color.osprPurple).frame(width: 6, height: 6); Text(model.status).lineLimit(1) }.font(.caption).foregroundStyle(.secondary)
                    if model.busy { ProgressView().controlSize(.small) }
                    if model.busy { Button("Cancel") { model.cancel() }.font(.caption) }
                }.padding(.horizontal, 32).frame(height: 60)
                Divider()
                if !model.error.isEmpty {
                    HStack(alignment: .top) { Image(systemName: "exclamationmark.circle"); Text(model.error).textSelection(.enabled); Spacer(); Button { model.error = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                        .font(.caption).foregroundStyle(.orange).padding(12).background(.orange.opacity(0.07))
                }
                Group {
                    switch model.tab {
                    case "History": HistoryView(model: model)
                    case "Models": ModelsView(model: model)
                    case "Dictionary": DictionaryView(model: model)
                    case "Modes": ModesView(model: model)
                    case "Settings": PreferencesView(model: model)
                    case "Research": ResearchView(model: model)
                    default: StudioView(model: model, capture: model.capture)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.background(Color.canvas)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.importFiles([url]) } }
                }
            }
            return !providers.isEmpty
        }
    }
}

struct PageTitle: View {
    var eyebrow: String
    var title: String
    var description: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow.uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(Color.osprInk)
            Text(title).font(.system(size: 31, weight: .semibold, design: .rounded)).tracking(-0.8)
            Text(description).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary, lineWidth: 1)) }
}

struct StudioView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var capture: Capture
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageTitle(eyebrow: "A little less typing", title: "Make room for your thoughts.", description: "Speak naturally. Turn your words into something useful, right where you work.")
                Card {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack {
                            Label(model.localOnly ? "ON YOUR MAC" : "YOUR CHOSEN PROVIDER", systemImage: model.localOnly ? "cpu" : "cloud").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
                            Spacer()
                            Text(model.settings.model == "parakeet-v3" ? "Parakeet v3" : model.settings.model).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 26) {
                            Button { model.toggle() } label: {
                                Image(systemName: model.phase == "recording" ? "stop.fill" : "mic.fill")
                                    .font(.system(size: 30, weight: .medium)).foregroundStyle(.white)
                                    .frame(width: 86, height: 86).background(model.phase == "recording" ? Color.red : .osprPurple, in: Circle())
                                    .overlay(Circle().stroke(Color.osprPurple.opacity(0.14), lineWidth: 12).padding(-6))
                            }.buttonStyle(.plain).disabled(model.busy && model.phase != "recording").accessibilityLabel(model.phase == "recording" ? "Finish dictation" : "Start dictation")
                            VStack(alignment: .leading, spacing: 9) {
                                Text(model.phase == "recording" ? "Listening to you…" : "Your next idea starts here.").font(.title3.weight(.medium))
                                Text(model.phase == "recording" ? String(format: "%.1f seconds · click to finish", capture.seconds) : "Click the mic, or use your shortcut in any app.").font(.subheadline).foregroundStyle(.secondary)
                                HStack(spacing: 7) {
                                    Text(shortcutLabel(model.settings)).font(.system(size: 12, weight: .medium, design: .monospaced)).padding(.horizontal, 9).padding(.vertical, 5).background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                                    Text(model.settings.pushToTalk ? "hold to talk" : "start / finish").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                        }.padding(.vertical, 14)
                        if model.phase == "recording" {
                            Waveform(level: capture.level)
                            if !model.preview.isEmpty { Text(model.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
                            Button("Discard recording", role: .destructive) { model.cancel() }.buttonStyle(.plain).font(.caption)
                        }
                        Divider()
                        HStack {
                            Picker("Style", selection: $model.settings.mode) { ForEach(WritingMode.allCases) { Text($0.title).tag($0) } }.frame(maxWidth: 240)
                            Spacer()
                            Button { model.importFiles() } label: { Label("Import files", systemImage: "arrow.down.doc") }.disabled(model.busy)
                        }
                    }
                }
                if model.hasRecovery {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Unfinished recording", systemImage: "arrow.counterclockwise.circle").font(.headline)
                            Text("This completed take is kept privately on this Mac until transcription succeeds or you discard it. Retry uses your current speech settings and saves the raw transcript without rewriting or inserting into another app.").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button(model.settings.transcriptionProvider == "local" ? "Retry locally" : "Retry with cloud provider") { model.retryRecovery() }.disabled(model.busy || model.pending == nil)
                                Button("Export audio") { model.exportRecovery() }.disabled(model.busy)
                                Button("Discard", role: .destructive) { model.discardRecovery() }.disabled(model.busy)
                            }
                        }
                    }
                }
                if !model.ready {
                    Card {
                        VStack(alignment: .leading, spacing: 15) {
                            Label("Make yourself at home", systemImage: "hand.wave").font(.headline)
                            Text("One-time setup, then offline dictation. The first model load downloads its weights from Hugging Face.").font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                Button(model.engineInstalled ? "1. Engine installed ✓" : "1. Install local engine") { model.installEngine() }.disabled(model.setupRunning || model.engineInstalled || model.busy)
                                Button("2. Load model") { model.warm() }.disabled(model.busy || !model.engineInstalled).buttonStyle(.borderedProminent)
                                Button("3. Enable insertion") { model.requestAccessibility() }
                            }
                            if model.setupRunning { ProgressView("Installing locked dependencies…").font(.caption) }
                            if !model.setupLog.isEmpty { DisclosureGroup("Setup output") { Text(model.setupLog).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxHeight: 160) } }
                        }
                    }
                }
                HStack(spacing: 14) {
                    StatTile(title: "WORDS CAPTURED", value: "\(model.history.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count })", icon: "text.alignleft")
                    StatTile(title: "LAST PROCESSING", value: model.history.first.map { String(format: "%.2f s", $0.latencyMS / 1000) } ?? "—", icon: "bolt")
                    StatTile(title: "SAVED LOCALLY", value: "\(model.history.count) sessions", icon: "internaldrive")
                }
                if let record = model.history.first {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Text("Your latest words").font(.headline); Spacer(); Text(record.date, style: .time).font(.caption).foregroundStyle(.secondary) }
                            Text(record.text).font(.system(size: 15)).lineSpacing(5).lineLimit(5).textSelection(.enabled)
                            HStack { Button("Copy text") { model.copy(record.text) }; Button("Open in history") { model.tab = "History" }; Spacer(); Text(record.mode.title).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                Text("Audio is discarded after processing. History stays on this Mac. Change retention or disable saving in Settings.").font(.caption).foregroundStyle(.tertiary)
            }.padding(32)
        }.onChange(of: model.settings.mode) { model.saveOSprSettings() }
    }
}

func shortcutLabel(_ settings: OSprSettings) -> String {
    let flags = settings.hotkeyModifiers
    let modifiers = (flags & 4096 != 0 ? "⌃" : "") + (flags & 2048 != 0 ? "⌥" : "") + (flags & 512 != 0 ? "⇧" : "") + (flags & 256 != 0 ? "⌘" : "")
    let names: [UInt32: String] = [49: "Space", 0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 35: "P", 37: "L", 40: "K", 45: "N", 46: "M", 47: "."]
    return modifiers + (names[settings.hotkeyCode] ?? "Key \(settings.hotkeyCode)")
}

struct StatTile: View {
    let title: String; let value: String; let icon: String
    var body: some View { Card { VStack(alignment: .leading, spacing: 12) { HStack { Text(title).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(.secondary); Spacer(); Image(systemName: icon).foregroundStyle(Color.osprInk) }; Text(value).font(.system(size: 22, weight: .medium, design: .rounded)) } } }
}
struct Waveform: View {
    var level: Float
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08)) { context in
            HStack(spacing: 4) {
                ForEach(0..<36) { i in
                    Capsule().fill(Color.osprPurple.opacity(0.3 + Double(level) * 0.7)).frame(width: 4,
                        height: 4 + CGFloat(level) * CGFloat(12 + 20 * abs(sin(Double(i) * 0.8 + context.date.timeIntervalSince1970 * 5))))
                }
            }.frame(height: 38).frame(maxWidth: .infinity)
        }.accessibilityLabel("Microphone input level")
    }
}
struct RecordingOverlay: View {
    @ObservedObject var model: AppModel
    @ObservedObject var capture: Capture
    var body: some View {
        VStack(spacing: 5) {
            HStack { Circle().fill(.red).frame(width: 7, height: 7); Text(model.phase == "recording" ? "Listening" : "Working…").font(.caption.weight(.medium)); Spacer(); Text(String(format: "%.1fs", capture.seconds)).font(.caption.monospacedDigit()); Button { model.stop() } label: { Image(systemName: "stop.circle.fill") }.buttonStyle(.plain).accessibilityLabel("Finish dictation") }
            Waveform(level: capture.level)
        }.padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17)).overlay(RoundedRectangle(cornerRadius: 17).stroke(.quaternary))
    }
}

struct HistoryView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    @State private var confirmDelete = false
    var filtered: [Transcript] { model.history.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) || $0.rawText.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        HSplitView {
            VStack(spacing: 12) {
                TextField("Search your words", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.top, 18)
                List(selection: $model.selection) {
                    ForEach(filtered) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record.text).font(.system(size: 13)).lineLimit(2)
                            HStack { Text(record.date, style: .date); Spacer(); Text(record.mode.title) }.font(.caption2).foregroundStyle(.secondary)
                        }.padding(.vertical, 6).tag(record.id)
                        .contextMenu { Button("Copy") { model.copy(record.text) }; Button("Delete", role: .destructive) { model.remove(record) } }
                    }
                }.listStyle(.sidebar)
                Button("Delete all history", role: .destructive) { confirmDelete = true }.font(.caption).padding(.bottom, 16)
            }.frame(minWidth: 220, idealWidth: 270, maxWidth: 330)
            if let record = model.selected {
                VStack(alignment: .leading, spacing: 18) {
                    HStack { Text(record.date.formatted(date: .abbreviated, time: .shortened)).font(.headline); Spacer(); Button { model.copy(record.text) } label: { Label("Copy", systemImage: "doc.on.doc") } }
                    HStack(spacing: 16) { Label(record.model, systemImage: "cpu"); Text(record.mode.title); Text(String(format: "%.1fs audio · %.2fs processing", record.duration, record.latencyMS / 1000)) }.font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: Binding(get: { model.history.first { $0.id == record.id }?.text ?? record.text }, set: { model.updateText(record.id, text: $0) })).font(.system(size: 16)).lineSpacing(6).padding(10).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    DisclosureGroup("Original transcript · subtitle exports use original timing") { Text(record.rawText).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    HStack {
                        Menu("Export") { ForEach(["txt", "json", "srt", "vtt"], id: \.self) { format in Button(format.uppercased()) { model.export(record, format: format) } } }
                        Spacer(); Button("Delete", role: .destructive) { model.remove(record) }
                    }
                }.padding(28).frame(minWidth: 350)
            } else { ContentUnavailableView("Your words will live here", systemImage: "text.bubble", description: Text("Record a thought or import an audio file to begin.")).frame(maxWidth: .infinity) }
        }.confirmationDialog("Delete all saved transcripts?", isPresented: $confirmDelete) { Button("Delete all history", role: .destructive) { model.clearHistory() } }
    }
}

struct ModelsView: View {
    @ObservedObject var model: AppModel
    let models: [(String, String, String, String)] = [
        ("parakeet-v3", "Parakeet v3", "FAST DAILY DICTATION", "600M parameters · 25 European languages · segment timestamps. MLX on Metal. Recommended starting point."),
        ("whisper-turbo", "Whisper Large v3 Turbo", "BROAD LANGUAGE COVERAGE", "809M parameters · 99 languages · vocabulary prompting. MLX on Metal. A strong multilingual fallback."),
        ("whisper-small", "Whisper Small", "SMALLER FOOTPRINT", "244M parameters · 99 languages · vocabulary prompting. Lower memory use; measure the accuracy tradeoff."),
        ("qwen3-asr", "Qwen3 ASR 1.7B", "EXPERIMENTAL QUALITY", "8-bit MLX · 30 languages and Chinese dialects. Utterance-level timestamps. Requires the research extra."),
        ("nemotron-streaming", "Nemotron 3.5 ASR", "INCREMENTAL PREVIEW", "8-bit MLX · multilingual, cache-aware streaming. Enable live preview in Settings. Utterance timestamps; microphone validation pending.")]
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            PageTitle(eyebrow: "A model for your Mac", title: "Choose your voice engine.", description: "All five run on Apple Silicon. Downloads happen only when you load a model. Check Research for measured results and limits.")
            ForEach(models, id: \.0) { id, name, tag, detail in
                Card { HStack(alignment: .top, spacing: 18) {
                    Image(systemName: id == "parakeet-v3" ? "bolt" : "cpu").font(.title2).foregroundStyle(Color.osprInk).frame(width: 40, height: 40).background(Color.osprPurple.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 7) { Text(tag).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(Color.osprInk); Text(name).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary).lineSpacing(3) }
                    Spacer()
                    Button(model.settings.model == id ? "Selected ✓" : "Select") { model.settings.model = id; model.ready = false; model.saveOSprSettings() }.disabled(model.busy)
                } }
            }
            HStack { Button("Load selected model") { model.warm() }.buttonStyle(.borderedProminent).disabled(model.busy || !model.engineInstalled); Text("First load can take several minutes.").font(.caption).foregroundStyle(.secondary) }
            Text("Model weights have their own licenses. Parakeet weights require attribution under CC BY 4.0; OSpr code is Apache 2.0. Model caches can be managed with the Hugging Face CLI.").font(.caption).foregroundStyle(.tertiary)
        }.padding(32) }
    }
}

struct DictionaryView: View {
    @ObservedObject var model: AppModel
    @State private var spoken = ""
    @State private var replacement = ""
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 22) {
            PageTitle(eyebrow: "Your words, exactly", title: "Give your vocabulary a home.", description: "Names, project terms, and phrases you use every day. Deterministic replacements work with every engine.")
            Card { VStack(alignment: .leading, spacing: 12) {
                Text("Vocabulary hints").font(.headline)
                Text("Whisper uses these during recognition. Parakeet uses the replacements below; it does not support vocabulary prompting in this adapter.").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $model.settings.vocabulary).font(.body).frame(height: 100).padding(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                Button("Save vocabulary") { model.saveOSprSettings() }
            } }
            Card { VStack(alignment: .leading, spacing: 14) {
                Text("Replacements & snippets").font(.headline)
                Text("Say “meeting link” to expand a URL, or correct “open spr” to “OSpr”. Whole phrases only; rules never cascade.").font(.caption).foregroundStyle(.secondary)
                HStack { TextField("When I say", text: $spoken); Image(systemName: "arrow.right").foregroundStyle(.secondary); TextField("Write this", text: $replacement); Button("Add") {
                    model.settings.replacements.append(Replacement(spoken: spoken.trimmingCharacters(in: .whitespacesAndNewlines), replacement: replacement)); spoken = ""; replacement = ""; model.saveOSprSettings()
                }.disabled(spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || replacement.isEmpty) }.textFieldStyle(.roundedBorder)
                ForEach(model.settings.replacements) { rule in HStack { Text(rule.spoken).frame(maxWidth: .infinity, alignment: .leading); Image(systemName: "arrow.right").foregroundStyle(.tertiary); Text(rule.replacement).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled); Button { model.settings.replacements.removeAll { $0.id == rule.id }; model.saveOSprSettings() } label: { Image(systemName: "trash") }.buttonStyle(.plain).accessibilityLabel("Delete replacement for \(rule.spoken)") }; Divider() }
            } }
        }.padding(32) }
    }
}

struct ModesView: View {
    @ObservedObject var model: AppModel
    @State private var bundleID = ""
    @State private var profileMode: WritingMode = .clean
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 22) {
            PageTitle(eyebrow: "Set the tone", title: "One voice. Many ways to write.", description: "Verbatim preserves the model output. Clean removes basic fillers locally. Other styles use the rewrite provider you choose.")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(WritingMode.allCases) { mode in
                    Button { model.settings.mode = mode; model.saveOSprSettings() } label: {
                        Card { HStack(alignment: .top) { Image(systemName: mode.symbol).foregroundStyle(Color.osprInk).frame(width: 24); VStack(alignment: .leading, spacing: 8) { Text(mode.title).font(.headline); Text(mode.instruction(custom: model.settings.customPrompt, language: model.settings.translationLanguage)).font(.caption).foregroundStyle(.secondary).lineLimit(3) }; Spacer(); if model.settings.mode == mode { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.osprInk) } } }
                    }.buttonStyle(.plain)
                }
            }
            Card { VStack(alignment: .leading, spacing: 12) {
                Text("Custom instruction").font(.headline)
                TextEditor(text: $model.settings.customPrompt).font(.body).frame(height: 90).padding(8)
                TextField("Translate into", text: $model.settings.translationLanguage).textFieldStyle(.roundedBorder)
                Button("Save instructions") { model.saveOSprSettings() }
            } }
            Card { VStack(alignment: .leading, spacing: 14) {
                Text("Automatically match an app").font(.headline)
                Text("Use an app bundle ID such as com.apple.mail or com.microsoft.VSCode. A profile changes the writing mode when you start dictation there.").font(.caption).foregroundStyle(.secondary)
                HStack { TextField("App bundle ID", text: $bundleID); Picker("Mode", selection: $profileMode) { ForEach(WritingMode.allCases) { Text($0.title).tag($0) } }; Button("Add") { model.settings.profiles.removeAll { $0.bundleID == bundleID }; model.settings.profiles.append(AppProfile(bundleID: bundleID, mode: profileMode)); bundleID = ""; model.saveOSprSettings() }.disabled(bundleID.isEmpty) }.textFieldStyle(.roundedBorder)
                ForEach(model.settings.profiles) { profile in HStack { Text(profile.bundleID); Spacer(); Text(profile.mode.title).foregroundStyle(.secondary); Button { model.settings.profiles.removeAll { $0.id == profile.id }; model.saveOSprSettings() } label: { Image(systemName: "trash") }.buttonStyle(.plain) } }
            } }
        }.padding(32) }
    }
}

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section("Capture") {
                Picker("Microphone", selection: $model.settings.microphoneID) {
                    Text("System default").tag("")
                    ForEach(Capture.microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
                TextField("Language hint (ISO code; blank for automatic)", text: $model.settings.language)
                HStack { Text("Global shortcut"); Spacer(); ShortcutRecorder(code: $model.settings.hotkeyCode, modifiers: $model.settings.hotkeyModifiers).frame(width: 190, height: 28) }
                Toggle("Hold shortcut to talk", isOn: $model.settings.pushToTalk)
                Toggle("Paste into the original focused field", isOn: $model.settings.autoPaste)
                Toggle("Restore clipboard after paste fallback", isOn: $model.settings.restoreClipboard)
                Toggle("Spoken punctuation (English phrases)", isOn: $model.settings.spokenPunctuation)
                Toggle("Conservative silence edge trimming", isOn: $model.settings.silenceTrim)
                HStack { Text("Silence threshold"); Slider(value: $model.settings.silenceThreshold, in: 0.0001...0.02); Text(String(format: "%.4f", model.settings.silenceThreshold)).monospacedDigit() }
                Picker("Auto finish after silence", selection: $model.settings.autoStopSeconds) { Text("Off").tag(0.0); Text("1.5 seconds").tag(1.5); Text("3 seconds").tag(3.0); Text("5 seconds").tag(5.0) }
                Toggle("Experimental live local preview", isOn: $model.settings.preview)
                Text("Nemotron streams incremental audio and flushes its cache at finish. Other models decode a rolling 12-second window every 3 seconds, adding GPU work. Partial text is displayed in OSpr, then final text is inserted.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Speech recognition") {
                Picker("Transcription", selection: $model.settings.transcriptionProvider) { Text("Local MLX · audio stays on Mac").tag("local"); Text("BYOK · upload audio to selected provider").tag("compatible") }
                if model.settings.transcriptionProvider != "local" {
                    Text("Recordings will be uploaded to this endpoint. Charges and retention are controlled by your provider.").font(.caption).foregroundStyle(.orange)
                    ProviderPresetPicker(kind: "transcription", model: model)
                    TextField("Base URL, including /v1", text: $model.settings.transcriptionURL)
                    TextField("Model ID", text: $model.settings.transcriptionModel)
                    SecureField("API key · saved in Keychain", text: $model.transcriptionKey)
                }
            }
            Section("Optional text refinement") {
                Picker("Rewrite provider", selection: $model.settings.rewriteProvider) {
                    Text("Off · deterministic text rules only").tag("none")
                    Text("Local MLX · Qwen3 4B Instruct 4-bit").tag("local")
                    Text("Local Ollama / compatible service").tag("ollama")
                    Text("BYOK · OpenAI-compatible API").tag("compatible")
                    Text("BYOK · Anthropic Messages API").tag("anthropic")
                }
                if ["ollama", "compatible", "anthropic"].contains(model.settings.rewriteProvider) {
                    ProviderPresetPicker(kind: "rewrite", model: model)
                    TextField("Base URL, including /v1", text: $model.settings.rewriteURL)
                    TextField("Model ID", text: $model.settings.rewriteModel)
                    SecureField("API key · saved in Keychain", text: $model.rewriteKey)
                    Text("Only transcript text and selected-text editing context go to this endpoint. Screen content and clipboard are never read for context.").font(.caption).foregroundStyle(.secondary)
                }
                if model.settings.rewriteProvider == "local" { Text("First use downloads a quantized language model. Refinement adds latency and can change meaning; original transcripts stay available in History.").font(.caption).foregroundStyle(.secondary) }
            }
            Section("File imports") {
                Toggle("Add anonymous speaker labels locally", isOn: $model.settings.speakerLabels)
                Text("Uses Nemotron diarization plus Parakeet/Whisper word timing. Downloads a separate 107 MB model. Imports keep raw ASR and timing, skip rewriting, and flag overlapping speech instead of claiming to separate it. Up to eight generic speaker channels; real-meeting accuracy is still being evaluated.").font(.caption).foregroundStyle(.secondary)
            }
            WatchedFolderPreferences(model: model, watcher: model.folderWatcher)
            Section("Privacy & storage") {
                Toggle("Save transcript history", isOn: $model.settings.saveHistory)
                Picker("Keep saved history", selection: $model.settings.retentionDays) { Text("1 day").tag(1); Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90); Text("Forever").tag(0) }
                Text("Turning off saving removes persisted history when you save preferences. Current-session results remain visible until quit. Completed takes are kept in a private recovery slot until transcription succeeds or you discard them. History is stored as local JSON; use FileVault for disk encryption.").font(.caption).foregroundStyle(.secondary)
                Toggle("Launch OSpr at login", isOn: $model.settings.launchAtLogin)
                Button("Open local data folder") { NSWorkspace.shared.open(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OSpr")) }
                Button("Enable Accessibility for insertion") { model.requestAccessibility() }
            }
            Section("Local engine") {
                LabeledContent("Checkout", value: model.settings.rootPath).textSelection(.enabled)
                Button("Choose OSpr checkout…") { model.chooseRoot() }.disabled(model.busy)
                Button("Install / repair locked engine") { model.installEngine() }.disabled(model.setupRunning || model.busy)
                if !model.setupLog.isEmpty { DisclosureGroup("Setup output") { Text(model.setupLog).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) } }
            }
            Button("Save preferences") { model.saveOSprSettings() }.buttonStyle(.borderedProminent)
        }.formStyle(.grouped).disabled(model.busy)
    }
}

struct ProviderPresetPicker: View {
    var kind: String
    @ObservedObject var model: AppModel
    var body: some View {
        Menu("Use a provider preset") {
            if kind == "transcription" {
                Button("Groq · Whisper Turbo") { model.settings.transcriptionURL = "https://api.groq.com/openai/v1"; model.settings.transcriptionModel = "whisper-large-v3-turbo" }
                Button("OpenAI · gpt-transcribe") { model.settings.transcriptionURL = "https://api.openai.com/v1"; model.settings.transcriptionModel = "gpt-transcribe" }
                Button("Local compatible server") { model.settings.transcriptionURL = "http://127.0.0.1:8080/v1"; model.settings.transcriptionModel = "whisper-1" }
            } else {
                Button("Ollama · Qwen3 1.7B") { model.settings.rewriteProvider = "ollama"; model.settings.rewriteURL = "http://127.0.0.1:11434/v1"; model.settings.rewriteModel = "qwen3:1.7b" }
                Button("OpenAI-compatible · enter model ID") { model.settings.rewriteProvider = "compatible"; model.settings.rewriteURL = "https://api.openai.com/v1"; model.settings.rewriteModel = "" }
                Button("Anthropic · enter model ID") { model.settings.rewriteProvider = "anthropic"; model.settings.rewriteURL = "https://api.anthropic.com/v1"; model.settings.rewriteModel = "" }
            }
        }.font(.caption)
    }
}

struct ResearchView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 22) {
            PageTitle(eyebrow: "Built in the open", title: "Evidence before superlatives.", description: "Compare features, read the model strategy, and inspect the exact measurements behind OSpr.")
            Card { VStack(alignment: .leading, spacing: 14) {
                Text("The OSpr field guide").font(.title3.weight(.medium))
                Text("Competitor plans and differentiation, the parity ledger, architecture, ten optimization experiments, and benchmark methodology. Vendor claims and measured results are labeled separately.").font(.body).foregroundStyle(.secondary)
                Button("Open research & benchmark report") { NSWorkspace.shared.open(model.root.appendingPathComponent("docs/research.html")) }.buttonStyle(.borderedProminent)
            } }
            Card { VStack(alignment: .leading, spacing: 14) {
                Text("Reproduce the results").font(.headline)
                Text("PYTHONPATH=backend .venv/bin/python benchmarks/run.py --model parakeet-v3").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                Text("Benchmark recordings and outputs live in the repository’s benchmarks folder. A model’s decoding speed is only one part of dictation latency. We do not claim a top-three app ranking without comparable end-to-end measurements.").font(.caption).foregroundStyle(.secondary)
                Button("Open progress & TODOs") { NSWorkspace.shared.open(model.root.appendingPathComponent("docs/PROGRESS.md")) }
            } }
        }.padding(32) }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var code: UInt32
    @Binding var modifiers: UInt32
    func makeNSView(context: Context) -> ShortcutButton { let button = ShortcutButton(); button.onKey = { event in
        code = UInt32(event.keyCode)
        let flags = event.modifierFlags
        modifiers = (flags.contains(.command) ? 256 : 0) | (flags.contains(.shift) ? 512 : 0) | (flags.contains(.option) ? 2048 : 0) | (flags.contains(.control) ? 4096 : 0)
    }; return button }
    func updateNSView(_ button: ShortcutButton, context: Context) { var settings = OSprSettings(); settings.hotkeyCode = code; settings.hotkeyModifiers = modifiers; button.title = shortcutLabel(settings) + " · change" }
}
final class ShortcutButton: NSButton {
    var onKey: ((NSEvent) -> Void)?
    private var recording = false
    override var acceptsFirstResponder: Bool { true }
    init() { super.init(frame: .zero); bezelStyle = .rounded; target = self; action = #selector(beginRecording) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func beginRecording() { recording = true; title = "Press a modified shortcut…"; window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; title = "Cancelled · click to change"; return }
        guard !event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { title = "Include ⌘, ⌃ or ⌥"; return }
        recording = false; onKey?(event); window?.makeFirstResponder(nil)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { if recording { keyDown(with: event); return true }; return super.performKeyEquivalent(with: event) }
}

struct WatchedFolderPreferences: View {
    @ObservedObject var model: AppModel
    @ObservedObject var watcher: FolderWatcher
    var body: some View {
        Section("Watched folder") {
            Toggle("Process new media locally", isOn: $watcher.settings.enabled)
                .onChange(of: watcher.settings.enabled) { _, _ in model.saveWatchedFolder(reset: true) }
            HStack { Text(watcher.settings.directory.isEmpty ? "No folder chosen" : watcher.settings.directory).lineLimit(1).truncationMode(.middle); Button("Choose folder…") { model.chooseWatchedFolder() } }
            Toggle("Ignore existing files when enabling", isOn: $watcher.settings.ignoreExisting)
                .onChange(of: watcher.settings.ignoreExisting) { _, _ in model.saveWatchedFolder(reset: false) }
            Text(watcher.status).font(.caption).foregroundStyle(.secondary)
            Text("Watches this folder while OSpr is open. Waits for stable files, transcribes locally without rewriting or auto-paste, and saves TXT/JSON/SRT/VTT in OSpr Transcripts. Existing exports are not overwritten. Cloud speech settings pause the watcher. Native interaction acceptance is still pending.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
