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
                    Text(model.localOnly ? "No account. No metering.\nBuilt to belong to you." : "Your provider, your key.\nProvider charges may apply.").font(.caption).foregroundStyle(.secondary).lineSpacing(3)
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
        .onAppear { model.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
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
    @State private var confirmingRecoveryDiscard = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageTitle(eyebrow: "A little less typing", title: "Make room for your thoughts.", description: "Speak naturally. Turn your words into something useful, right where you work.")
                Card {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack {
                            Label(model.localOnly ? "ON YOUR MAC" : "YOUR CHOSEN PROVIDER", systemImage: model.localOnly ? "cpu" : "cloud").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
                            Spacer()
                            Text(model.activeDictationModel ?? (model.settings.transcriptionProvider == "local" ? (model.settings.model == "parakeet-v3" ? "Parakeet v3" : model.settings.model) : model.settings.transcriptionModel)).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 26) {
                            Button { model.toggle() } label: {
                                Image(systemName: model.phase == "recording" ? "stop.fill" : "mic.fill")
                                    .font(.system(size: 30, weight: .medium)).foregroundStyle(.white)
                                    .frame(width: 86, height: 86).background(model.phase == "recording" ? Color.red : .osprPurple, in: Circle())
                                    .overlay(Circle().stroke(Color.osprPurple.opacity(0.14), lineWidth: 12).padding(-6))
                            }.buttonStyle(.plain).disabled(model.busy && model.phase != "recording" && !model.backgroundImportActive).accessibilityLabel(model.phase == "recording" ? "Finish dictation" : "Start dictation")
                            VStack(alignment: .leading, spacing: 9) {
                                Text(model.phase == "recording" ? (model.recordingDesktop ? "Recording desktop audio…" : "Listening to you…") : "Your next idea starts here.").font(.title3.weight(.medium))
                                Text(model.phase == "recording" ? String(format: "%.1f seconds · click to finish", model.displaySeconds) : "Click the mic, or use your shortcut in any app. Up to five minutes per take.").font(.subheadline).foregroundStyle(.secondary)
                                HStack(spacing: 7) {
                                    Text(model.hotkey.hasBinding ? shortcutLabel(model.effectiveShortcutSettings) : "No shortcut bound").font(.system(size: 12, weight: .medium, design: .monospaced)).padding(.horizontal, 9).padding(.vertical, 5).background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                                    Text(model.settings.pushToTalk ? "hold to talk" : "start / finish").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                        }.padding(.vertical, 14)
                        if model.phase == "recording" {
                            if let destination = model.dictationDestination { Text(destination).font(.caption).foregroundStyle(.secondary) }
                            Waveform(level: model.displayLevel)
                            if !model.preview.isEmpty { Text(model.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
                            Button("Discard recording", role: .destructive) { model.cancel() }.buttonStyle(.plain).font(.caption)
                        }
                        Divider()
                        if let seconds = model.countdownSeconds {
                            HStack {
                                Text("Starting in \(seconds)… Focus the field where you want to dictate.").font(.caption)
                                Spacer()
                                Button("Cancel countdown") { model.cancel() }
                            }
                        } else {
                            HStack {
                                Button("Start in 3 seconds") { model.startDictationCountdown() }
                                    .disabled(model.busy || !model.microphoneReady || model.hasRecovery)
                                Text("Focus your destination before the countdown ends.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            if let activeStyle = model.activeDictationStyle {
                                Text("This take · \(activeStyle.title)").font(.callout.weight(.medium))
                            } else {
                                Picker("Style", selection: $model.settings.mode) { ForEach(WritingMode.allCases) { Text($0.title).tag($0) } }.frame(maxWidth: 240).disabled(model.busy)
                            }
                            Spacer()
                            Button { model.importFiles() } label: { Label("Import files", systemImage: "arrow.down.doc") }.disabled(model.busy)
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Desktop audio · experimental", systemImage: "person.2.wave.2").font(.headline)
                        Text("Record desktop sound, with an optional microphone track. Up to one hour per take. Audio stays local; no video is stored. macOS 15+, system audio permission and FFmpeg are required. Use headphones to reduce speaker bleed; echo cancellation is not included.").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Toggle("Include microphone", isOn: $model.meetingMicrophone).disabled(model.busy)
                            Spacer()
                            Button(model.recordingDesktop ? "Finish meeting" : "Record desktop audio") {
                                if model.recordingDesktop { model.stop() } else { model.startMeeting() }
                            }.disabled(model.busy && !model.recordingDesktop || model.hasRecovery && !model.recordingDesktop)
                        }
                    }
                }
                if model.hasRecovery {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Unfinished recording", systemImage: "arrow.counterclockwise.circle").font(.headline)
                            Text("This completed take is kept privately on this Mac until transcription succeeds or you discard it. Retry uses your current speech settings and saves the raw transcript without rewriting or inserting into another app.").font(.caption).foregroundStyle(.secondary)
                            if let warning = model.pending?.captureWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
                            HStack {
                                Button(model.settings.transcriptionProvider == "local" ? "Retry locally" : "Retry with cloud provider") { model.retryRecovery() }.disabled(model.busy || model.pending == nil)
                                if model.settings.transcriptionProvider == "local" {
                                    Button("Retry without edge trimming") { model.retryRecovery(withoutEdgeTrimming: true) }.disabled(model.busy || model.pending == nil)
                                }
                                Button("Export audio") { model.exportRecovery() }.disabled(model.busy)
                                Button("Discard…", role: .destructive) { confirmingRecoveryDiscard = true }.disabled(model.busy)
                            }
                        }
                    }
                }
                if !model.engineInstalled || (model.settings.transcriptionProvider == "local" && !model.ready) || !model.microphoneReady || (model.settings.autoPaste && !model.accessibilityReady) {
                    Card {
                        VStack(alignment: .leading, spacing: 15) {
                            Label("Set up dictation", systemImage: "hand.wave").font(.headline)
                            Text("Local model loading downloads weights on first use. File imports need neither microphone nor insertion access.").font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                Button(model.engineInstalled ? "Engine installed ✓" : "Install local engine") { model.installEngine() }.disabled(model.setupRunning || model.engineInstalled || model.busy)
                                if model.settings.transcriptionProvider == "local" { Button(model.ready ? "Model ready ✓" : "Load model") { model.warm() }.disabled(model.ready || model.busy || !model.engineInstalled).buttonStyle(.borderedProminent) }
                            }
                            HStack(spacing: 10) {
                                Button(model.microphoneReady ? "Microphone allowed ✓" : "Allow microphone") { model.requestMicrophone() }.disabled(model.microphoneReady || model.busy)
                                if model.settings.autoPaste { Button(model.accessibilityReady ? "Insertion enabled ✓" : "Enable insertion") { model.requestAccessibility() }.disabled(model.accessibilityReady || model.busy) }
                            }
                            if model.setupRunning { ProgressView("Installing locked dependencies…").font(.caption) }
                            if !model.setupLog.isEmpty { DisclosureGroup("Setup output") { Text(model.setupLog).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxHeight: 160) } }
                        }
                    }
                }
                HStack(spacing: 14) {
                    StatTile(title: "WORDS CAPTURED", value: "\(model.historyState.statistics.words)", icon: "text.alignleft")
                    StatTile(title: "LAST PROCESSING", value: model.historyState.latest.map { String(format: "%.2f s", $0.latencyMS / 1000) } ?? "—", icon: "bolt")
                    StatTile(title: model.historyState.savingEnabled ? "SAVED LOCALLY" : "CURRENT SESSION", value: "\(model.historyState.statistics.records) sessions", icon: "internaldrive")
                }
                if let record = model.historyState.latest {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Text("Your latest words").font(.headline); Spacer(); Text(record.date, style: .time).font(.caption).foregroundStyle(.secondary) }
                            Text(record.text).font(.system(size: 15)).lineSpacing(5).lineLimit(5).textSelection(.enabled)
                            if let warning = record.warning {
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                            }
                            HStack { Button("Copy text") { model.copy(record.text) }; Button("Open in history") { model.tab = "History" }; Spacer(); Text(record.mode.title).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                Text(model.settings.keepAudio && model.settings.saveHistory ? "Audio review is on. Clips stay on this Mac within your history retention and storage budget." : "New audio is discarded after successful processing. Previously retained clips follow history retention; unresolved takes remain in private recovery.").font(.caption).foregroundStyle(.tertiary)
                Text(model.settings.saveHistory ? "Transcript history is saved on this Mac. Change retention in Settings." : "Transcript saving is off. Current-session text remains visible until quit.").font(.caption).foregroundStyle(.tertiary)
            }.padding(32)
        }.onChange(of: model.settings.mode) { model.saveOSprSettings() }
        .confirmationDialog("Discard the unfinished recording?", isPresented: $confirmingRecoveryDiscard, titleVisibility: .visible) {
            Button("Discard recording permanently", role: .destructive) { model.discardRecovery() }
            Button("Keep recording", role: .cancel) { }
        } message: {
            Text("This removes the recovery audio from this Mac. Export it first if you want to keep a copy.")
        }
    }
}

func shortcutLabel(_ settings: OSprSettings) -> String {
    if settings.hotkeyFnOnly { return "Globe / Fn" }
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
        }.accessibilityLabel("Audio input level")
    }
}
struct RecordingOverlay: View {
    @ObservedObject var model: AppModel
    @ObservedObject var capture: Capture
    var body: some View {
        VStack(spacing: 5) {
            HStack { Circle().fill(model.phase == "recording" ? .red : Color.osprPurple).frame(width: 7, height: 7); Text(model.countdownSeconds.map { "Starting in \($0)…" } ?? (model.phase == "recording" ? (model.recordingDesktop ? "Desktop audio" : "Listening") : "Working…")).font(.caption.weight(.medium)); Spacer(); if model.countdownSeconds == nil { Text(String(format: "%.1fs", model.displaySeconds)).font(.caption.monospacedDigit()) }; Button { if model.phase == "recording" { model.stop() } else { model.cancel() } } label: { Image(systemName: model.phase == "recording" ? "stop.circle.fill" : "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel(model.phase == "recording" ? "Finish recording" : model.countdownSeconds != nil ? "Cancel countdown" : "Cancel processing") }
            if let destination = model.dictationDestination { Text(destination).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            if model.phase == "recording", !model.recordingDesktop, let profile = model.recordingProfileTitle {
                Text("Profile · \(profile)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if model.countdownSeconds != nil { Text("Focus your destination field").font(.caption2).foregroundStyle(.secondary) }
            else { Waveform(level: model.displayLevel) }
        }.padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17)).overlay(RoundedRectangle(cornerRadius: 17).stroke(.quaternary))
    }
}

struct HistoryView: View {
    @ObservedObject var model: AppModel
    @State private var confirmDelete = false
    var body: some View {
        HSplitView {
            VStack(spacing: 12) {
                TextField("Search your words", text: Binding(get: { model.historyState.query }, set: { model.historyState.query = $0 })).textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.top, 18)
                List(selection: $model.selection) {
                    ForEach(model.historyState.rows) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record.preview).font(.system(size: 13)).lineLimit(2)
                            HStack { Text(record.date, style: .date); Spacer(); Text(record.mode.title) }.font(.caption2).foregroundStyle(.secondary)
                        }.padding(.vertical, 6).tag(record.id)
                        .contextMenu { Button("Copy full transcript") { model.copyHistoryRow(record.id) }; Button("Delete", role: .destructive) { model.removeHistoryRow(record.id) } }
                    }
                }.listStyle(.sidebar)
                if model.historyState.loading { ProgressView("Loading history…").font(.caption) }
                if model.historyState.next != nil {
                    Button("Load more") { model.historyState.loadMore() }.disabled(model.historyState.loading)
                }
                if !model.historySaveFailure.isEmpty {
                    Text(model.historySaveFailure).font(.caption).foregroundStyle(.orange).padding(.horizontal, 12)
                    Button("Retry history") { model.historyState.refresh() }.font(.caption)
                }
                Button("Delete all history", role: .destructive) { confirmDelete = true }.font(.caption).padding(.bottom, 16)
            }.frame(minWidth: 220, idealWidth: 270, maxWidth: 330)
            if let record = model.selected {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text(record.date.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                        Spacer()
                        Text(model.historySaving ? "Saving…" : !model.historySaveFailure.isEmpty ? "Save failed" : model.historyState.savingEnabled ? "Saved locally" : "Session only")
                            .font(.caption).foregroundStyle(model.historySaveFailure.isEmpty ? Color.secondary : Color.orange)
                        Button { model.copy(record.text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    }
                    HStack(spacing: 16) { Label(record.model, systemImage: "cpu"); Text(record.mode.title); Text(String(format: "%.1fs audio · %.2fs processing", record.duration, record.latencyMS / 1000)) }.font(.caption).foregroundStyle(.secondary)
                    if let warning = record.warning { Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    if record.audioFile != nil { AudioReviewView(model: model, record: record) }
                    TextEditor(text: Binding(get: { model.selected?.id == record.id ? model.selected?.text ?? record.text : record.text }, set: { model.updateText(record.id, text: $0) })).font(.system(size: 16)).lineSpacing(6).padding(10).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    DisclosureGroup("Original transcript · subtitle exports use original timing") { Text(record.rawText).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    if let notes = record.notes, notes.matches(record.rawText) {
                        DisclosureGroup("Key excerpts · local AI selection") {
                            ScrollView { VStack(alignment: .leading, spacing: 12) {
                                Text("Exact source excerpts. Selection can miss context or important points; review the full transcript.").font(.caption).foregroundStyle(.secondary)
                                ForEach(notes.excerpts) { excerpt in
                                    VStack(alignment: .leading, spacing: 3) { Text("SOURCE \(excerpt.id + 1)").font(.caption2).foregroundStyle(.secondary); Text(excerpt.text).textSelection(.enabled) }
                                }
                                Button("Copy notes as Markdown") { model.copy(notes.markdown) }
                            }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 220)
                        }
                    }
                    HStack {
                        Menu("Export") { ForEach(["txt", "json", "srt", "vtt"], id: \.self) { format in Button(format.uppercased()) { model.export(record, format: format) } } }
                        Button(record.notes == nil ? "Select key excerpts locally" : "Refresh local excerpts") { model.generateNotes(record) }.disabled(model.busy)
                        Spacer(); Button("Delete", role: .destructive) { model.remove(record) }
                    }
                }.padding(28).frame(minWidth: 350)
            } else if model.historyState.loadingDetail { ProgressView("Opening transcript…").frame(maxWidth: .infinity)
            } else { ContentUnavailableView("Your words will live here", systemImage: "text.bubble", description: Text("Record a thought or import an audio file to begin.")).frame(maxWidth: .infinity) }
        }.confirmationDialog("Delete all saved transcripts?", isPresented: $confirmDelete) { Button("Delete all history", role: .destructive) { model.clearHistory() } }
    }
}

struct ModelsView: View {
    @ObservedObject var model: AppModel
    let models: [(String, String, String, String)] = [
        ("parakeet-v3", "Parakeet v3", "FAST DAILY DICTATION", "600M parameters · 25 European languages · segment timestamps. MLX on Metal. Recommended starting point."),
        ("cohere-native8", "Cohere Transcribe", "MEASURED ENGLISH QUALITY", "2B parameters · 8-bit MLX · 14 languages. Lowest measured English error rate among the current choices. Blank language hint uses English; no automatic detection. Utterance timestamps."),
        ("whisper-turbo", "Whisper Large v3 Turbo", "BROAD LANGUAGE COVERAGE", "809M parameters · 99 languages · vocabulary prompting. MLX on Metal. A strong multilingual fallback."),
        ("whisper-small", "Whisper Small", "SMALLER FOOTPRINT", "244M parameters · 99 languages · vocabulary prompting. Lower memory use; measure the accuracy tradeoff."),
        ("qwen3-asr", "Qwen3 ASR 1.7B", "EXPERIMENTAL QUALITY", "8-bit MLX · 30 languages and Chinese dialects. Utterance-level timestamps. Compare measured accuracy by language in Research."),
        ("nemotron-streaming", "Nemotron 3.5 ASR", "INCREMENTAL PREVIEW", "8-bit MLX · multilingual, cache-aware streaming. Enable live preview in Settings. Utterance timestamps; microphone validation pending.")]
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            PageTitle(eyebrow: "A model for your Mac", title: "Choose your voice engine.", description: "All six run on Apple Silicon. Weights download on first use. Check Research for measured results and limits.")
            HStack {
                Button(model.checkingModels ? "Checking…" : "Refresh cache status") { model.refreshModels() }.disabled(model.busy || model.checkingModels || !model.engineInstalled)
                Button("Release engine memory") { model.releaseModels() }.disabled(model.busy || model.checkingModels)
                Spacer()
                Text("\(model.residentModels.count) models resident").font(.caption).foregroundStyle(.secondary)
            }
            if !model.modelProgress.isEmpty && model.phase == "warming" {
                Card { VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(model.modelProgress).font(.callout); Spacer(); Button("Cancel") { model.cancel() } }
                    if let fraction = model.modelFraction { ProgressView(value: fraction) } else { ProgressView().controlSize(.small) }
                    Text("Progress counts prepared weight bytes, including reused cache data. The total can change as files are discovered.").font(.caption).foregroundStyle(.secondary)
                } }
            }
            ForEach(models, id: \.0) { id, name, tag, detail in
                Card { HStack(alignment: .top, spacing: 18) {
                    Image(systemName: id == "parakeet-v3" ? "bolt" : "cpu").font(.title2).foregroundStyle(Color.osprInk).frame(width: 40, height: 40).background(Color.osprPurple.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(tag).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(Color.osprInk); Text(name).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary).lineSpacing(3)
                        if let cache = model.modelCache[id] {
                            HStack {
                                Label(cache.cacheLabel, systemImage: cache.complete ? "checkmark.circle" : "arrow.down.circle")
                                if model.residentModels.contains(id) { Text("Loaded on Metal").foregroundStyle(Color.osprInk) }
                            }.font(.caption)
                            HStack {
                                Text("Pinned \(String(cache.revision.prefix(10)))").textSelection(.enabled)
                                if !cache.complete { Button("Download weights") { model.warm(downloadOnly: id) }.disabled(model.busy) }
                                if let path = cache.path { Button("Show in Finder") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") } }
                            }.font(.caption)
                        }
                    }
                    Spacer()
                    Button(model.settings.model == id ? "Selected ✓" : "Select") { model.settings.model = id; model.ready = false; model.saveOSprSettings() }.disabled(model.busy)
                } }
            }
            HStack { Button("Load selected model") { model.warm() }.buttonStyle(.borderedProminent).disabled(model.busy || !model.engineInstalled); Text("Download alone uses no GPU. Loading also prepares first-use kernels.").font(.caption).foregroundStyle(.secondary) }
            Text("Optional local models").font(.headline)
            ForEach([("rewrite-quality", "Qwen3 4B · local refinement & key excerpts"), ("diarization", "Nemotron · experimental speaker labels"), ("speech-detector", "Silero · experimental neural edges & auto finish (native CPU)")], id: \.0) { id, name in
                if let cache = model.modelCache[id] {
                    Card { HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(name).font(.callout)
                            Text(cache.cacheLabel + (model.residentModels.contains(id) ? " · resident" : "")).font(.caption).foregroundStyle(.secondary)
                            if id == "speech-detector" { Text("MIT model data · optional edge filtering and auto finish; speech recognition uses your selected engine.").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if !cache.complete { Button("Download") { model.warm(downloadOnly: id) }.disabled(model.busy) }
                        if let path = cache.path { Button("Show in Finder") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") } }
                    } }
                }
            }
            Text("Model weights have their own licenses. Parakeet weights require attribution under CC BY 4.0; OSpr code is Apache 2.0. Downloads use the shared Hugging Face cache; removing weights there can affect other apps. OSpr never deletes that shared cache.").font(.caption).foregroundStyle(.tertiary)
        }.padding(32) }
        .onAppear { model.refreshModels() }
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
                Text("Whisper uses these during recognition. Deepgram Nova-3 uses comma- or newline-separated phrases as keyterms (up to 100 in OSpr; provider token limits also apply). Parakeet uses the replacements below; it does not support vocabulary prompting in this adapter.").font(.caption).foregroundStyle(.secondary)
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
    @State private var profileDraft: AppProfile?
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
                HStack { Text("App & site profiles").font(.headline); Spacer(); Button("Add profile") { profileDraft = AppProfile(bundleID: "", mode: model.settings.mode) } }
                Text("Choose a writing mode, local speech model, language or Custom instruction for an app. Site rules take priority over app rules; the longest matching path wins. Settings are captured when dictation starts.").font(.caption).foregroundStyle(.secondary)
                if model.settings.profiles.isEmpty { Text("Start with an app you dictate into often.").foregroundStyle(.secondary).padding(.vertical, 8) }
                ForEach(model.settings.profiles) { profile in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: profile.site == nil ? "app" : "globe").foregroundStyle(Color.osprInk).frame(width: 22)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(profile.title).fontWeight(.medium); if !profile.enabled { Text("Off").font(.caption).foregroundStyle(.secondary) } }
                            Text(profile.site ?? profile.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(profileSummary(profile)).font(.caption).foregroundStyle(.secondary)
                            if let error = profile.validationError { Text(error).font(.caption).foregroundStyle(.orange) }
                        }
                        Spacer()
                        Button("Edit") { profileDraft = profile }
                        Button { model.settings.profiles.removeAll { $0.id == profile.id }; model.saveOSprSettings() } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).accessibilityLabel("Delete profile \(profile.title)")
                    }
                    Divider()
                }
            } }
        }.padding(32) }
        .sheet(item: $profileDraft) { profile in
            ContextProfileEditor(profile: profile, localSpeech: model.settings.transcriptionProvider == "local", rewriteEnabled: model.settings.rewriteProvider != "none", globalTranslation: model.settings.translationLanguage) { edited in
                try model.settings.upsertProfile(edited)
                model.saveOSprSettings()
            }
        }
    }
    private func profileSummary(_ profile: AppProfile) -> String {
        var parts = [profile.mode.title]
        if let id = profile.localModel, let choice = ProfileSpeechModel(rawValue: id) { parts.append("Local: " + choice.title) }
        if let language = profile.language { parts.append(language.isEmpty ? "Automatic language" : language) }
        return parts.joined(separator: " · ")
    }
}

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    @State private var confirmEraseAudio = false
    var body: some View {
        Form {
            Section("Capture") {
                Picker("Microphone", selection: $model.settings.microphoneID) {
                    Text("System default").tag("")
                    ForEach(Capture.microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
                TextField(model.settings.model == "cohere-native8" ? "Language hint (ISO code; blank uses English)" : "Language hint (ISO code; blank for automatic)", text: $model.settings.language)
                Picker("Global shortcut", selection: $model.settings.hotkeyFnOnly) {
                    Text("Modified key").tag(false)
                    Text("Globe / Fn alone · experimental").tag(true)
                }
                if model.settings.hotkeyFnOnly {
                    Text("Requires Accessibility. In macOS Keyboard settings, set “Press Globe/Fn key to” to “Do Nothing” to avoid system dictation or emoji actions. Fn combinations cancel the gesture; typed content is not collected. Physical keyboard acceptance is still pending.").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack { Text("Key combination"); Spacer(); ShortcutRecorder(code: $model.settings.hotkeyCode, modifiers: $model.settings.hotkeyModifiers).frame(width: 190, height: 28) }
                }
                Toggle("Hold shortcut to talk", isOn: $model.settings.pushToTalk)
                Toggle("Paste into the original focused field", isOn: $model.settings.autoPaste)
                Toggle("Restore clipboard after paste fallback", isOn: $model.settings.restoreClipboard)
                Toggle("Allow paste when a field or cursor cannot be verified", isOn: $model.settings.allowUnverifiedPaste)
                if model.settings.allowUnverifiedPaste { Text("Only the original app can be checked in some destinations. A changed field may receive the paste. Leave this off for stricter destination checks.").font(.caption).foregroundStyle(.orange) }
                Toggle("Spoken punctuation (English phrases)", isOn: $model.settings.spokenPunctuation)
                Toggle("Neural edge trimming · experimental", isOn: $model.settings.neuralEdgeTrim)
                if model.settings.neuralEdgeTrim {
                    Text("Can shorten or miss quiet speech, including parts of a take. Keep this off for quiet or multilingual dictation while quality work continues. An empty result keeps completed audio for retry. Requires the detector in Models; cloud uploads are unchanged.").font(.caption).foregroundStyle(.orange)
                    Button("Open edge detector model") { model.tab = "Models" }
                } else {
                    Toggle("Volume-based silence edge trimming", isOn: $model.settings.silenceTrim)
                    Text("Off by default so the recognizer receives the complete audio. Volume filtering can remove quiet speech, including parts of a take. Empty results keep completed audio for retry.").font(.caption).foregroundStyle(.secondary)
                    HStack { Text("Silence threshold"); Slider(value: $model.settings.silenceThreshold, in: 0.0001...0.02); Text(String(format: "%.4f", model.settings.silenceThreshold)).monospacedDigit() }
                }
                Toggle("Neural auto finish · experimental", isOn: $model.settings.neuralAutoFinish)
                if model.settings.neuralAutoFinish {
                    Picker("Detector silence before finish", selection: $model.settings.neuralSilenceSeconds) { Text("1.2 seconds").tag(1.2); Text("1.5 seconds").tag(1.5); Text("3 seconds").tag(3.0); Text("5 seconds").tag(5.0) }
                    Text("Uses a local speech detector instead of volume alone. Pauses can end a take. Detection failure leaves recording active so you can stop manually. Prepare its small model in Models before use.").font(.caption).foregroundStyle(.secondary)
                    if model.settings.silenceTrim && !model.settings.neuralEdgeTrim { Text("Final edge trimming still uses volume. Disable it above to preserve quiet speech; neural edges can also miss quiet words.").font(.caption).foregroundStyle(.orange) }
                    Button("Open detector model") { model.tab = "Models" }
                } else {
                    Picker("Level-based auto finish", selection: $model.settings.autoStopSeconds) { Text("Off").tag(0.0); Text("1.5 seconds").tag(1.5); Text("3 seconds").tag(3.0); Text("5 seconds").tag(5.0) }
                }
                Toggle("Experimental live local preview", isOn: $model.settings.preview)
                Text("Nemotron streams incremental audio and flushes its cache at finish. Other models decode a rolling 12-second window every 3 seconds, adding GPU work. Neural edges use a separate final decode of the complete take; previews stay provisional. Partial text is displayed in OSpr, then final text is inserted.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Speech recognition") {
                Picker("Transcription", selection: Binding(get: { model.settings.transcriptionProvider }, set: { provider in
                    let previous = model.settings.transcriptionProvider
                    model.settings.transcriptionProvider = provider
                    if provider == "deepgram" {
                        model.settings.transcriptionURL = "https://api.deepgram.com/v1"; model.settings.transcriptionModel = "nova-3"
                    } else if provider == "soniox" {
                        model.settings.transcriptionURL = "https://api.soniox.com/v1"; model.settings.transcriptionModel = "stt-async-v5"
                    } else if provider == "compatible" && (["deepgram", "soniox"].contains(previous) || ["api.deepgram.com", "api.soniox.com"].contains(URL(string: model.settings.transcriptionURL)?.host ?? "")) {
                        model.settings.transcriptionURL = "https://api.groq.com/openai/v1"; model.settings.transcriptionModel = "whisper-large-v3-turbo"
                    }
                })) {
                    Text("Local MLX · audio stays on Mac").tag("local")
                    Text("BYOK · compatible speech API").tag("compatible")
                    Text("BYOK · Deepgram prerecorded API").tag("deepgram")
                    Text("BYOK · Soniox async API").tag("soniox")
                }
                if model.settings.transcriptionProvider != "local" {
                    Text("Recordings will be uploaded to this endpoint. Charges and retention are controlled by your provider.").font(.caption).foregroundStyle(.orange)
                    Text("Large files are split locally into audio-only parts, uploaded in order. Nothing is saved as a completed transcript until every part succeeds. Retrying a failed file uploads its parts again and may incur provider charges.").font(.caption).foregroundStyle(.secondary)
                    ProviderPresetPicker(kind: "transcription", model: model)
                    TextField("Base URL, including /v1", text: $model.settings.transcriptionURL)
                    TextField("Model ID", text: $model.settings.transcriptionModel)
                    SecureField("API key · saved in Keychain", text: $model.transcriptionKey)
                    Text("Keys are remembered separately for each provider origin.").font(.caption).foregroundStyle(.secondary)
                    if model.settings.transcriptionProvider == "deepgram" {
                        Text("Deepgram receives locally normalized mono audio. Nova-3 keyterms, punctuation and word times are supported. Blank language uses its detection, which may select another supported Deepgram model. This route does not stream audio or request cloud speaker labels, summaries or smart number formatting.").font(.caption).foregroundStyle(.secondary)
                    }
                    if model.settings.transcriptionProvider == "soniox" {
                        Text("Soniox receives locally normalized audio and creates remote transcription jobs. OSpr polls for completion, then attempts to delete its job and upload. Cancellation, timeouts or a failed cleanup can leave resources in the Soniox console; check your account. No automatic retry, translation or cloud speaker labels. Token-derived word times are included only when word boundaries match token boundaries.").font(.caption).foregroundStyle(.secondary)
                    }
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
                Toggle("Keep audio for transcript review", isOn: $model.settings.keepAudio).disabled(!model.settings.saveHistory)
                if model.settings.keepAudio {
                    Picker("Retained audio budget", selection: $model.settings.audioBudgetMB) {
                        Text("256 MB").tag(256); Text("1 GB").tag(1024); Text("4 GB").tag(4096); Text("8 GB").tag(8192)
                    }.disabled(!model.settings.saveHistory)
                }
                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: model.audioBytesUsed, countStyle: .file) + " retained locally").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete retained audio…", role: .destructive) { confirmEraseAudio = true }
                }
                Text("Audio retention is off by default. When enabled, OSpr keeps normalized audio without imported video or tags. Oldest clips are removed when the budget fills; deleting or expiring history also removes its audio. Turning retention off affects future transcripts; existing clips follow history retention until deleted.").font(.caption).foregroundStyle(.secondary)
                Picker("Keep saved history", selection: $model.settings.retentionDays) { Text("1 day").tag(1); Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90); Text("Forever").tag(0) }
                Text("Turning off saving removes persisted history when you save preferences. Current-session results remain visible until quit. Completed takes are kept in a private recovery slot until transcription succeeds or you discard them. History uses a local SQLite archive; use FileVault for disk encryption. Older JSON archives migrate on first use after verification.").font(.caption).foregroundStyle(.secondary)
                Toggle("Launch OSpr at login", isOn: $model.settings.launchAtLogin)
                Button("Open local data folder") { NSWorkspace.shared.open(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OSpr")) }
                Button("Enable Accessibility for insertion") { model.requestAccessibility() }
            }
            Section("Local engine") {
                LabeledContent("Checkout", value: model.settings.rootPath).textSelection(.enabled)
                Button("Choose OSpr checkout…") { model.chooseRoot() }.disabled(model.busy)
                Button(model.engineBundled ? "Engine bundled · update the app to repair" : "Install / repair locked engine") { model.installEngine() }.disabled(model.setupRunning || model.busy || model.engineBundled)
                if !model.setupLog.isEmpty { DisclosureGroup("Setup output") { Text(model.setupLog).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) } }
            }
            Button("Save preferences") { model.saveOSprSettings() }.buttonStyle(.borderedProminent)
        }.formStyle(.grouped).disabled(model.busy)
            .confirmationDialog("Delete all retained audio? Transcript text will be kept.", isPresented: $confirmEraseAudio) { Button("Delete retained audio", role: .destructive) { model.eraseRetainedAudio() } }
    }
}

struct ProviderPresetPicker: View {
    var kind: String
    @ObservedObject var model: AppModel
    var body: some View {
        Menu("Use a provider preset") {
            if kind == "transcription" {
                Button("Groq · Whisper Turbo") { model.settings.transcriptionProvider = "compatible"; model.settings.transcriptionURL = "https://api.groq.com/openai/v1"; model.settings.transcriptionModel = "whisper-large-v3-turbo" }
                Button("OpenAI · gpt-transcribe") { model.settings.transcriptionProvider = "compatible"; model.settings.transcriptionURL = "https://api.openai.com/v1"; model.settings.transcriptionModel = "gpt-transcribe" }
                Button("Deepgram · Nova-3") { model.settings.transcriptionProvider = "deepgram"; model.settings.transcriptionURL = "https://api.deepgram.com/v1"; model.settings.transcriptionModel = "nova-3" }
                Button("Soniox · Async v5") { model.settings.transcriptionProvider = "soniox"; model.settings.transcriptionURL = "https://api.soniox.com/v1"; model.settings.transcriptionModel = "stt-async-v5" }
                Button("Local compatible server") { model.settings.transcriptionProvider = "compatible"; model.settings.transcriptionURL = "http://127.0.0.1:8080/v1"; model.settings.transcriptionModel = "whisper-1" }
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
