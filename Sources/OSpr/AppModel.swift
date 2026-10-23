import AppKit
import Combine
import AVFoundation
import SwiftUI
import ServiceManagement
import OSprCore

@MainActor final class AppModel: ObservableObject {
    @Published var settings: OSprSettings {
        didSet {
            if credentialsReady && (oldValue.transcriptionURL != settings.transcriptionURL || oldValue.rewriteURL != settings.rewriteURL) { refreshCredentials() }
        }
    }
    let historyState: HistoryModel
    private var historyObservation: AnyCancellable?
    var historySaving: Bool { historyState.saving }
    var historySaveFailure: String { historyState.failure }
    @Published var audioBytesUsed: Int64 = 0
    @Published var audioMaintenance = false
    @Published var phase = "idle"
    @Published var status = "Your voice. Your Mac."
    @Published var error = ""
    @Published var preview = ""
    var selection: UUID? { get { historyState.selection } set { historyState.selection = newValue } }
    @Published var tab = "Studio"
    @Published var setupRunning = false
    @Published var setupLog = ""
    @Published var ready = false
    @Published var microphoneReady = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published var accessibilityReady = AXIsProcessTrusted()
    @Published var modelCache: [String: ModelCacheStatus] = [:]
    @Published var residentModels: Set<String> = []
    @Published var modelProgress = ""
    @Published var modelFraction: Double?
    @Published var checkingModels = false
    @Published var pending: PendingRecording?
    @Published var hasRecovery = false
    @Published var recordingDesktop = false
    @Published var meetingMicrophone = true
    @Published var meetingSeconds = 0.0
    @Published var meetingLevel: Float = 0
    var displaySeconds: Double { recordingDesktop ? meetingSeconds : capture.seconds }
    var displayLevel: Float { recordingDesktop ? meetingLevel : capture.level }
    var dictationDestination: String? {
        guard phase == "recording", !recordingDesktop else { return nil }
        guard recordingSettings.autoPaste, let app = target?.app else { return "Transcript in OSpr · automatic insertion off for this take" }
        return "Target · " + (app.localizedName ?? app.bundleIdentifier ?? "original app")
    }
    private var meetingSession: MeetingCaptureSession?
    private var meetingTimer: Timer?
    private var meetingDirectory: URL?
    @Published var transcriptionKey = "" {
        didSet { if !loadingCredentials { transcriptionKeyScope = ProviderCredentialScope(kind: .transcription, base: settings.transcriptionURL) } }
    }
    @Published var rewriteKey = "" {
        didSet { if !loadingCredentials { rewriteKeyScope = ProviderCredentialScope(kind: .rewrite, base: settings.rewriteURL) } }
    }
    let capture = Capture()
    let hotkey = Hotkey()
    let folderWatcher: FolderWatcher
    let audioArchive: AudioArchive
    let audioReview = AudioReviewPlayer()
    private var worker: WorkerClient
    private var savedTranscriptionKey = ""
    private var savedRewriteKey = ""
    private var transcriptionKeyScope: ProviderCredentialScope?
    private var rewriteKeyScope: ProviderCredentialScope?
    private var savedTranscriptionScope: ProviderCredentialScope?
    private var savedRewriteScope: ProviderCredentialScope?
    private var loadingCredentials = false
    private var credentialsReady = false
    private let store: LocalStore
    private let instanceLock: AppInstanceLock
    private let servicesEnabled: Bool
    private var settingsSaveToken = UUID()
    private let recovery: RecordingRecovery
    private var target: InsertionTarget?
    private var recordingMode: WritingMode = .clean
    private var recordingSettings = OSprSettings()
    private var recordingURL: URL?
    private var previewTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var streamSession: (generation: UUID, id: String)?
    private var generation = UUID()
    private var uploadingGeneration: UUID?
    private var shortcutCaptureGeneration: UUID?
    private var backgroundGeneration: UUID?
    var backgroundImportActive: Bool { backgroundGeneration == generation }
    private var overlay: NSPanel?
    @Published private(set) var quitting = false
    var busy: Bool { phase != "idle" || audioMaintenance || quitting }
    var audioBudgetBytes: Int64 { Int64(settings.audioBudgetMB) * 1024 * 1024 }
    var effectiveShortcutSettings: OSprSettings {
        var value = settings
        value.hotkeyFnOnly = hotkey.functionOnlyActive
        if let registered = hotkey.registeredCombination { value.hotkeyCode = registered.code; value.hotkeyModifiers = registered.modifiers }
        return value
    }
    var selected: Transcript? { historyState.selected }
    var root: URL { URL(fileURLWithPath: settings.rootPath) }
    var engineBundled: Bool { Bundle.main.resourceURL?.appendingPathComponent("Engine").path == root.path }
    var engineInstalled: Bool { FileManager.default.isExecutableFile(atPath: root.appendingPathComponent(".venv/bin/python").path) }
    var localOnly: Bool {
        let host = URL(string: settings.rewriteURL)?.host ?? ""
        let localRewrite = ["none", "local"].contains(settings.rewriteProvider) ||
            (["ollama", "compatible"].contains(settings.rewriteProvider) && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host))
        return settings.transcriptionProvider == "local" && localRewrite
    }

    init(instanceLock: AppInstanceLock, directory: URL = LocalStore.applicationDirectory, enableServices: Bool = true) {
        self.instanceLock = instanceLock
        servicesEnabled = enableServices
        // Application Support is required for state; an unwritable directory must
        // surface instead of silently putting transcripts somewhere unexpected.
        do {
            store = try LocalStore(directory: directory)
            audioArchive = try AudioArchive(directory: directory.appendingPathComponent("Audio"))
            folderWatcher = try FolderWatcher(directory: directory)
            recovery = try RecordingRecovery(directory: directory.appendingPathComponent("Recovery"))
        } catch { fatalError("Cannot create OSpr data folder: \(error.localizedDescription)") }
        var settings = OSprSettings()
        var loadError = ""
        do { settings = try store.read(OSprSettings.self, name: "settings.json") ?? settings } catch { loadError = "Settings could not be read. Original file was preserved. \(error.localizedDescription)" }
        if settings.rootPath.isEmpty {
            let bundled = Bundle.main.url(forResource: "checkout-root", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.rootPath = ProcessInfo.processInfo.environment["OSPR_ROOT"] ?? bundled ?? FileManager.default.currentDirectoryPath
        }
        if let bundledEngine = Bundle.main.resourceURL?.appendingPathComponent("Engine"),
           FileManager.default.isExecutableFile(atPath: bundledEngine.appendingPathComponent(".venv/bin/python").path) {
            // Resolve from the actual bundle every launch, including after moving
            // the .app; never retain a build-machine absolute runtime path.
            settings.rootPath = bundledEngine.path
        }
        settings = settings.validated()
        self.settings = settings
        self.worker = WorkerClient(root: settings.rootPath)
        historyState = HistoryModel(repository: HistoryRepository(directory: directory, saveHistory: settings.saveHistory, instanceLock: instanceLock), saving: settings.saveHistory)
        do { pending = try recovery.load() } catch { loadError += " " + error.localizedDescription }
        hasRecovery = recovery.exists
        self.error = loadError + (folderWatcher.loadError.isEmpty ? "" : " " + folderWatcher.loadError)
        credentialsReady = enableServices
        if enableServices { refreshCredentials() }
        historyObservation = historyState.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        historyState.onOrphanedAudio = { [weak self] names in self?.deleteAudioFiles(names) }
        hotkey.pressed = { [weak self] in
            guard let self else { return }
            self.shortcutCaptureGeneration = nil
            guard NSApp.modalWindow == nil else { return }
            let previous = self.generation
            self.toggle()
            if self.generation != previous && self.phase == "starting" { self.shortcutCaptureGeneration = self.generation }
        }
        hotkey.released = { [weak self] in
            guard let self else { return }
            let token = self.shortcutCaptureGeneration; self.shortcutCaptureGeneration = nil
            guard self.settings.pushToTalk, token == self.generation else { return }
            if self.phase == "starting" { self.cancel() } else { self.stop() }
        }
        hotkey.cancelled = { [weak self] in
            guard let self else { return }
            let token = self.shortcutCaptureGeneration; self.shortcutCaptureGeneration = nil
            if token == self.generation && ["starting", "recording"].contains(self.phase) { self.cancel() }
        }
        hotkey.failed = { [weak self] message in self?.error = message }
        capture.silenceReached = { [weak self] in self?.stop() }
        do { if enableServices { try hotkey.register(code: settings.hotkeyCode, modifiers: settings.hotkeyModifiers, functionOnly: settings.hotkeyFnOnly) } }
        catch {
            self.error = error.localizedDescription
            if settings.hotkeyFnOnly {
                self.settings.hotkeyFnOnly = false
                if settings.hotkeyCode >= 128 || settings.hotkeyModifiers & 0x1900 == 0 {
                    self.settings.hotkeyCode = 49; self.settings.hotkeyModifiers = 6144
                }
                do {
                    try hotkey.register(code: self.settings.hotkeyCode, modifiers: self.settings.hotkeyModifiers)
                    self.error += " A modified-key fallback is active; enable access and choose Globe/Fn again."
                } catch { self.error += " " + error.localizedDescription }
            }
        }
        folderWatcher.canProcess = { [weak self] in
            guard let self else { return false }
            let timing = !self.settings.speakerLabels || ["parakeet-v3", "whisper-turbo", "whisper-small"].contains(self.settings.model)
            return !self.busy && !self.hasRecovery && self.engineInstalled && timing && self.settings.transcriptionProvider == "local"
        }
        folderWatcher.pauseReason = { [weak self] in
            guard let self else { return "Disabled" }
            if self.settings.transcriptionProvider != "local" { return "Paused · cloud speech provider selected" }
            if !self.engineInstalled { return "Paused · install the local engine first" }
            if self.settings.speakerLabels && !["parakeet-v3", "whisper-turbo", "whisper-small"].contains(self.settings.model) {
                return "Paused · speaker labels require Parakeet or Whisper"
            }
            if self.hasRecovery { return "Paused · recover or discard the unfinished take" }
            if self.busy { return "Waiting for current task" }
            return nil
        }
        folderWatcher.process = { [weak self] file in await self?.processWatchedFile(file) ?? false }
        folderWatcher.reportError = { [weak self] error in self?.error = "Watched folder: " + error }
        if enableServices { folderWatcher.start() }
        // Persist pruning even when no new recording is made.
        if loadError.isEmpty {
            audioMaintenance = true; status = "Checking retained audio…"
            Task {
                do {
                    try await historyState.configure(saving: settings.saveHistory, retentionDays: settings.retentionDays)
                    let keep = try await historyState.audioFiles()
                    let removed = try await audioArchive.reconcile(keeping: keep, limitBytes: audioBudgetBytes)
                    applyAudioEvictions(removed)
                    audioBytesUsed = try await audioArchive.bytesUsed()
                } catch { self.error = "Audio maintenance: \(error.localizedDescription)" }
                audioMaintenance = false
                if phase == "idle" { status = "Your voice. Your Mac." }
            }
        }
        if enableServices { NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                try? self?.preserveOnQuit()
                self?.audioReview.stop()
                // applicationShouldTerminate completes the asynchronous save barrier.
                // This final fallback also covers termination outside the normal menu.
                do { try self?.historyState.flushOnQuit() } catch { self?.error = "Could not save history before quitting: \(error.localizedDescription)" }
                self?.hotkey.unregister()
                self?.operationTask?.cancel(); self?.worker.shutdown(); self?.previewTask?.cancel(); self?.discardAudio()
            }
        } }
    }

    func saveOSprSettings() {
        guard !quitting else { return }
        if servicesEnabled { refreshPermissions() }
        settings = settings.validated()
        var settingsWritten = false
        var ancillaryFailure: String?
        do {
            if servicesEnabled {
                try hotkey.register(code: settings.hotkeyCode, modifiers: settings.hotkeyModifiers, functionOnly: settings.hotkeyFnOnly)
                refreshCredentials()
            }
            guard transcriptionKey.isEmpty || transcriptionKeyScope != nil, rewriteKey.isEmpty || rewriteKeyScope != nil else {
                throw OSprError.message("Use a valid provider URL before saving its API key.")
            }
            try store.write(settings, name: "settings.json")
            settingsWritten = true
            // An unavailable/locked Keychain read must not turn a model or mode
            // preference save into a credential deletion. Write only edited keys.
            if servicesEnabled, transcriptionKey != savedTranscriptionKey || transcriptionKeyScope != savedTranscriptionScope, let scope = transcriptionKeyScope {
                try KeyVault.write(transcriptionKey, account: scope.account); savedTranscriptionKey = transcriptionKey; savedTranscriptionScope = scope
            }
            if servicesEnabled, rewriteKey != savedRewriteKey || rewriteKeyScope != savedRewriteScope, let scope = rewriteKeyScope {
                try KeyVault.write(rewriteKey, account: scope.account); savedRewriteKey = rewriteKey; savedRewriteScope = scope
            }
            if servicesEnabled {
                if settings.launchAtLogin && SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
                else if !settings.launchAtLogin && SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch { ancillaryFailure = error.localizedDescription; self.error = error.localizedDescription }
        guard settingsWritten else { return }
        // File persistence, history durability and Keychain/login-item writes
        // have distinct failure boundaries. Always honor a saved privacy request.
        let config = settings, token = UUID(); settingsSaveToken = token
        audioMaintenance = true; status = "Applying history preferences…"
        Task {
            defer { if settingsSaveToken == token { audioMaintenance = false } }
            do {
                try await historyState.configure(saving: config.saveHistory, retentionDays: config.retentionDays)
                guard settingsSaveToken == token else { return }
                let keep = try await historyState.audioFiles()
                let removed = try await audioArchive.reconcile(keeping: keep,
                    limitBytes: Int64(config.audioBudgetMB) * 1024 * 1024)
                applyAudioEvictions(removed)
                try await historyState.flush()
                audioBytesUsed = try await audioArchive.bytesUsed()
                if settingsSaveToken == token {
                    status = ancillaryFailure == nil ? "Preferences saved" : "History preferences applied · other settings need attention"
                }
            } catch {
                if settingsSaveToken == token {
                    self.error = "Could not apply history preferences: \(error.localizedDescription)"
                    status = "History preferences need attention · retry saving"
                }
            }
        }
    }

    private func refreshCredentials() {
        loadingCredentials = true
        defer { loadingCredentials = false }
        let speech = ProviderCredentialScope(kind: .transcription, base: settings.transcriptionURL)
        if speech != transcriptionKeyScope {
            transcriptionKey = speech.map { KeyVault.read($0.account) } ?? ""
            transcriptionKeyScope = speech; savedTranscriptionScope = speech; savedTranscriptionKey = transcriptionKey
        }
        let text = ProviderCredentialScope(kind: .rewrite, base: settings.rewriteURL)
        if text != rewriteKeyScope {
            rewriteKey = text.map { KeyVault.read($0.account) } ?? ""
            rewriteKeyScope = text; savedRewriteScope = text; savedRewriteKey = rewriteKey
        }
    }

    func chooseRoot() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Select the OSpr repository containing pyproject.toml and backend/."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("backend/ospr_backend/worker.py").path) else { error = "This folder is not an OSpr checkout."; return }
        worker.shutdown(); settings.rootPath = url.path; worker = WorkerClient(root: url.path); ready = false; saveOSprSettings()
    }

    func installEngine() {
        guard !setupRunning, !busy else { return }
        setupRunning = true; setupLog = "Installing the locked local engine…"
        let setup = root.appendingPathComponent("scripts/setup.sh")
        Task {
            do {
                let result = try await Task.detached { () -> (Int32, String) in
                    let process = Process(), pipe = Pipe()
                    process.executableURL = URL(fileURLWithPath: "/bin/bash"); process.arguments = [setup.path]
                    process.standardOutput = pipe; process.standardError = pipe
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
                }.value
                setupLog = result.1
                if result.0 != 0 { throw OSprError.message("Setup failed. See the setup output below.") }
                status = "Engine installed. Choose a model and load it."
            } catch { self.error = error.localizedDescription }
            setupRunning = false
        }
    }

    func refreshModels() {
        guard !busy, !checkingModels, engineInstalled else { return }
        checkingModels = true
        Task {
            defer { checkingModels = false }
            do {
                let result = try await worker.request(["action": "model_status"])
                let rows = result["models"] as? [[String: Any]] ?? []
                modelCache = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                    guard let value = ModelCacheStatus(row) else { return nil }
                    return (value.id, value)
                })
                residentModels = Set(result["resident"] as? [String] ?? [])
                if let rewrite = result["rewrite_resident"] as? String { residentModels.insert(rewrite) }
                if result["diarizer_resident"] as? Bool == true { residentModels.insert("diarization") }
            } catch { self.error = error.localizedDescription }
        }
    }

    func releaseModels() {
        guard !busy, !checkingModels else { return }
        worker.shutdown(); ready = false; residentModels = []
        status = "Local engine released · downloaded weights remain on disk"
    }

    func warm(downloadOnly id: String? = nil) {
        guard !busy else { return }
        generation = UUID(); let token = generation
        let modelID = id ?? settings.model
        modelProgress = "Checking pinned weights"; modelFraction = nil
        if id == nil { ready = false }
        phase = "warming"; error = ""; status = id == nil ? "Loading model · first use downloads weights" : "Downloading pinned model weights"
        operationTask = Task {
            do {
                _ = try await worker.request(["action": id == nil ? "warm" : "download_model", "model": modelID], progress: { [weak self] event in
                    let phase = event["phase"] as? String ?? ""
                    let completed = (event["completed_bytes"] as? NSNumber)?.doubleValue ?? 0
                    let total = (event["total_bytes"] as? NSNumber)?.doubleValue ?? 0
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token else { return }
                        self.modelFraction = phase == "download" && total > 0 ? min(1, completed / total) : nil
                        switch phase {
                        case "download": self.modelProgress = total > 0 ? "Preparing weights · \(ByteCountFormatter.string(fromByteCount: Int64(completed), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))" : "Downloading pinned weights · this can take several minutes"
                        case "loading": self.modelProgress = "Loading weights onto Metal"
                        case "priming": self.modelProgress = "Preparing first-use kernels · synthetic audio only"
                        default: self.modelProgress = "Checking pinned weights"
                        }
                    }
                })
                guard token == generation else { return }
                if id == nil { ready = true }
                status = id == nil ? "Model ready on your Mac" : "Weights downloaded · ready for offline loading"
            } catch { if token == generation { ready = false; residentModels = []; self.error = error.localizedDescription; status = id == nil ? "Model could not be loaded" : "Download could not be completed" } }
            if token == generation { phase = "idle"; modelProgress = ""; modelFraction = nil; refreshModels() }
        }
    }

    func toggle() {
        if backgroundImportActive { cancel(); start(); return }
        if phase == "recording" { stop() }
        else if phase == "idle" { start() }
    }
    func start() {
        guard !busy else { return }
        audioReview.pause()
        guard !hasRecovery else { error = "Retry, export or discard the unfinished recording first."; tab = "Studio"; return }
        let captured = InsertionTarget.capture()
        if captured.secure { error = "Recording is disabled in password fields."; return }
        target = captured.app?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : captured
        recordingSettings = settings
        recordingMode = settings.mode(for: target?.app?.bundleIdentifier ?? "")
        if recordingMode == .assistant && target?.selectedText.isEmpty != false { error = "Select text in another app first, then use the global shortcut."; return }
        generation = UUID(); let token = generation
        phase = "starting"; error = ""; preview = ""
        operationTask = Task {
            do {
                try Task.checkCancellation()
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                microphoneReady = allowed
                guard generation == token else { return }
                guard allowed else { throw OSprError.message("Allow OSpr microphone access in System Settings → Privacy & Security → Microphone.") }
                let file = try capture.start(deviceID: recordingSettings.microphoneID,
                    autoStop: recordingSettings.autoStopSeconds, threshold: recordingSettings.silenceThreshold)
                recordingURL = file; phase = "recording"; status = "Listening · \(recordingMode.title)"; showOverlay()
                if recordingSettings.preview && recordingSettings.transcriptionProvider == "local" { startPreview(token: token) }
            } catch { if generation == token { self.error = error.localizedDescription; phase = "idle" } }
        }
    }

    private func startPreview(token: UUID) {
        previewTask = Task {
            let incremental = recordingSettings.model == "nemotron-streaming"
            var sessionID: String?
            if incremental {
                do {
                    let result = try await worker.request(["action": "stream_begin", "language": recordingSettings.language])
                    sessionID = result["session_id"] as? String
                    guard generation == token, !Task.isCancelled else {
                        if let sessionID { _ = try? await worker.request(["action": "stream_cancel", "session_id": sessionID]) }
                        return
                    }
                    if let sessionID { streamSession = (token, sessionID) }
                } catch { return }
            }
            while !Task.isCancelled && generation == token && phase == "recording" {
                do {
                    try await Task.sleep(for: .milliseconds(incremental ? 320 : 3000))
                    guard phase == "recording", !Task.isCancelled else { break }
                    guard let file = try capture.snapshot(incremental: incremental) else { continue }
                    defer { try? FileManager.default.removeItem(at: file) }
                    let request: [String: Any] = sessionID.map { ["action": "stream_feed", "session_id": $0, "path": file.path] } ??
                        ["action": "transcribe", "path": file.path, "model": recordingSettings.model,
                         "language": recordingSettings.language, "trim": recordingSettings.silenceTrim]
                    let result = try await worker.request(request)
                    if generation == token && phase == "recording" { preview = result["text"] as? String ?? "" }
                } catch is CancellationError { break } catch {
                    if let sessionID { _ = try? await worker.request(["action": "stream_cancel", "session_id": sessionID]) }
                    if streamSession?.generation == token { streamSession = nil }
                    break // Final transcription can fall back to the complete audio.
                }
            }
        }
    }
    func stop() {
        if recordingDesktop { stopMeeting(); return }
        guard phase == "recording" else { return }
        phase = "transcribing"; status = "Transcribing on your Mac…"; previewTask?.cancel()
        do {
            guard let file = try capture.stop() else { throw OSprError.message("No recording available.") }
            let duration = capture.seconds, config = recordingSettings, mode = recordingMode, token = generation
            pending = try recovery.preserve(audio: file, duration: duration, settings: config, mode: mode)
            hasRecovery = true
            let outstandingPreview = previewTask
            operationTask = Task {
                let finalStarted = Date()
                await outstandingPreview?.value
                var streamed: [String: Any]?
                if generation == token, streamSession?.generation == token, let sessionID = streamSession?.id {
                    do {
                        if let tail = try capture.snapshot(incremental: true) {
                            defer { try? FileManager.default.removeItem(at: tail) }
                            _ = try await worker.request(["action": "stream_feed", "session_id": sessionID, "path": tail.path])
                        }
                        let final = try await worker.request(["action": "stream_end", "session_id": sessionID])
                        if let text = final["text"] as? String {
                            streamed = ["text": text, "model": config.model, "audio_seconds": duration,
                                "segments": [["start": 0.0, "end": duration, "text": text]],
                                "total_ms": Date().timeIntervalSince(finalStarted) * 1000]
                        }
                    } catch { /* Retry final ASR from complete audio; never drop a failed preview. */ }
                    _ = try? await worker.request(["action": "stream_cancel", "session_id": sessionID])
                    if streamSession?.generation == token { streamSession = nil }
                }
                let recognized = await transcribe(file: file, duration: duration, config: config, mode: mode,
                                 target: target, source: "dictation", token: token, preserveRecoveryOnSaveFailure: true, resultOverride: streamed, startedAt: finalStarted)
                if generation == token && recognized { discardRecovery() }
                try? FileManager.default.removeItem(at: file)
                if generation == token { recordingURL = nil; phase = "idle"; overlay?.orderOut(nil) }
            }
        } catch {
            self.error = error.localizedDescription; phase = "idle"
            if let recordingURL, !hasRecovery, FileManager.default.fileExists(atPath: recordingURL.path) {
                do {
                    pending = try recovery.preserve(audio: recordingURL, duration: capture.seconds, settings: recordingSettings,
                        mode: recordingMode, warning: "Capture ended with an error: " + error.localizedDescription)
                    hasRecovery = true
                } catch { self.error += " Partial audio could not be copied: " + error.localizedDescription }
            }
            if hasRecovery { discardAudio() }
            else if let recordingURL { self.error += " Source audio remains at " + recordingURL.path }
            overlay?.orderOut(nil)
        }
    }
    func prepareForTermination() async throws {
        // Stop admissions before the final asynchronous durability barrier.
        // A canceled quit leaves any unfinished take available for recovery.
        quitting = true
        do {
            // Settings/startup audio reconciliation can admit link updates after
            // an await. Let that already-admitted maintenance finish first.
            let deadline = Date().addingTimeInterval(60)
            while audioMaintenance {
                guard Date() < deadline else { throw OSprError.message("History maintenance is still running. Keep OSpr open and retry quitting after it finishes.") }
                try await Task.sleep(for: .milliseconds(20))
            }
            try preserveOnQuit()
            generation = UUID(); operationTask?.cancel(); previewTask?.cancel()
            worker.shutdown(); ready = false; residentModels = []
            meetingTimer?.invalidate(); meetingTimer = nil
            if let meetingSession { await meetingSession.discard() }
            meetingSession = nil; recordingDesktop = false
            _ = try? capture.stop(); phase = "idle"; overlay?.orderOut(nil)
            try await historyState.flush()
        } catch { quitting = false; throw error }
    }
    func cancelTermination() { quitting = false }

    private func preserveOnQuit() throws {
        ClipboardRestorer.shared.restorePending()
        guard !hasRecovery else { return }
            if let meetingSession {
                let tracks = try meetingSession.snapshotForQuit()
                if !tracks.isEmpty {
                    pending = try recovery.preserveTracks(tracks.map { RecoveryTrackSource(url: $0.url, start: $0.start) },
                        duration: meetingSeconds, settings: recordingSettings, warning: "Recording ended when OSpr quit; review the recovered take.")
                    hasRecovery = true
                }
            } else if phase == "recording", let file = try capture.stop() {
                pending = try recovery.preserve(audio: file, duration: capture.seconds, settings: recordingSettings, mode: recordingMode)
                hasRecovery = true
            }
    }
    func startMeeting() {
        guard !busy, !hasRecovery else { return }
        audioReview.pause()
        guard settings.transcriptionProvider == "local" else { error = "Desktop recording uses local speech. Choose a local provider first."; return }
        guard !settings.speakerLabels || ["parakeet-v3", "whisper-turbo", "whisper-small"].contains(settings.model) else {
            error = "Choose Parakeet or Whisper for speaker labels, or disable labels in Settings."; return
        }
        guard #available(macOS 15.0, *) else { error = "Desktop plus microphone capture requires macOS 15 or newer."; return }
        guard ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            error = "Desktop track mixing requires FFmpeg. Install with: brew install ffmpeg"; return
        }
        generation = UUID(); let token = generation
        let includeMic = meetingMicrophone
        recordingSettings = settings; recordingSettings.mode = .verbatim; recordingSettings.rewriteProvider = "none"
        target = nil; phase = "starting"; error = ""; preview = ""
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr/meeting-" + UUID().uuidString)
        operationTask = Task {
            var owned: MeetingCaptureSession?
            do {
                if includeMic {
                    let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                    guard token == generation else { return }
                    guard allowed else { throw OSprError.message("Allow OSpr microphone access, or turn off Include microphone.") }
                }
                let session = try MeetingCapture(directory: directory)
                owned = session; meetingSession = session; meetingDirectory = directory
                session.level = { [weak self] value in
                    if self?.generation == token && self?.phase == "recording" { self?.meetingLevel = value }
                }
                session.stopped = { [weak self] cause in
                    guard let self, self.generation == token, self.recordingDesktop, self.phase == "recording" else { return }
                    self.error = "Desktop capture stopped: " + cause.localizedDescription
                    if self.recordingDesktop { self.stopMeeting() }
                }
                try await session.start(includeMicrophone: includeMic, microphoneID: recordingSettings.microphoneID)
                guard token == generation else { await session.discard(); return }
                recordingDesktop = true; phase = "recording"; meetingSeconds = 0
                status = includeMic ? "Recording desktop + microphone" : "Recording desktop audio"
                let started = ProcessInfo.processInfo.systemUptime
                meetingTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        self.meetingSeconds = ProcessInfo.processInfo.systemUptime - started
                        if self.meetingSeconds >= 3600 { self.stopMeeting() }
                    }
                }
                showOverlay()
            } catch {
                if let owned { await owned.discard() }
                if token == generation {
                    meetingSession = nil; phase = "idle"; recordingDesktop = false
                    self.error = "Desktop recording could not start. Allow OSpr in Privacy & Security → Screen & System Audio Recording, then retry. " + error.localizedDescription
                }
            }
        }
    }
    private func stopMeeting() {
        guard phase == "recording", let session = meetingSession else { return }
        let token = generation, config = recordingSettings, duration = meetingSeconds
        phase = "transcribing"; status = "Preparing local meeting audio…"
        meetingTimer?.invalidate(); meetingTimer = nil
        operationTask = Task {
            let started = Date()
            do {
                var warning: String?
                let tracks: [MeetingTrack]
                do { tracks = try await session.stop() }
                catch let issue as MeetingCaptureIssue { tracks = issue.tracks; warning = issue.localizedDescription }
                guard token == generation else { await session.discard(); return }
                guard !tracks.isEmpty else { throw OSprError.message("No audio was received from the selected sources.") }
                pending = try recovery.preserveTracks(tracks.map { RecoveryTrackSource(url: $0.url, start: $0.start) },
                    duration: duration, settings: config, warning: warning)
                hasRecovery = true
                await session.discard()
                if token == generation { meetingSession = nil }
                if let warning { throw OSprError.message("Partial meeting audio was preserved for review. " + warning) }
                try await prepareRecoveryMix(token: token)
                guard token == generation else { return }
                let recognized = await transcribe(file: recovery.audioURL, duration: duration, config: config,
                    mode: .verbatim, target: nil, source: "desktop meeting", token: token, preserveRecoveryOnSaveFailure: true, startedAt: started)
                if recognized, token == generation { discardRecovery() }
            } catch {
                if token == generation {
                    self.error = error.localizedDescription
                    hasRecovery = recovery.exists
                    if hasRecovery { pending = try? recovery.load() }
                }
            }
            if token == generation {
                meetingSession = nil; recordingDesktop = false; meetingLevel = 0
                phase = "idle"; overlay?.orderOut(nil)
            }
        }
    }
    private func prepareRecoveryMix(token: UUID) async throws {
        guard recovery.needsMix else { return }
        let sources = try recovery.mixSources()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr/mix-" + UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: output) }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = try await worker.request(["action": "mix_meeting", "tracks": sources.map { ["path": $0.url.path, "start": $0.start] }, "output": output.path])
        guard token == generation else { throw CancellationError() }
        try recovery.replaceWithMix(output)
        pending = try recovery.load()
    }

    func cancel() {
        let wasCapture = phase == "recording" || phase == "starting"
        generation = UUID(); operationTask?.cancel(); operationTask = nil; previewTask?.cancel()
        if phase == "warming" || phase == "transcribing" || previewTask != nil { worker.shutdown(); ready = false; residentModels = [] }
        modelProgress = ""; modelFraction = nil
        streamSession = nil; backgroundGeneration = nil
        meetingTimer?.invalidate(); meetingTimer = nil
        if let meetingSession { Task { await meetingSession.discard() } }
        meetingSession = nil; recordingDesktop = false; meetingLevel = 0
        if wasCapture { discardRecovery() }
        _ = try? capture.stop(); discardAudio(); phase = "idle"; preview = ""
        status = hasRecovery ? "Cancelled · unfinished take retained" : wasCapture ? "Recording discarded" : "Cancelled"
        overlay?.orderOut(nil)
        // Generation fencing also prevents late cloud responses from being saved
        // or inserted. Task cancellation stops active URLSession work, while local
        // cancellation terminates the owned inference child.
    }
    private func discardAudio() { if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }; recordingURL = nil }

    func discardRecovery() {
        do { try recovery.discard(); pending = nil; hasRecovery = false }
        catch { self.error = "Could not discard unfinished audio: \(error.localizedDescription)" }
    }
    func exportRecovery() {
        guard !busy else { return }
        if recovery.needsMix {
            let folder = NSOpenPanel(); folder.canChooseDirectories = true; folder.canChooseFiles = false
            folder.message = "Choose a destination for the unfinished raw meeting tracks."
            guard folder.runModal() == .OK, let parent = folder.url else { return }
            let destination = parent.appendingPathComponent("OSpr Unfinished Take " + UUID().uuidString)
            let sources = recovery.managedAudio
            let metadata = pending
            Task {
              do {
                try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                for source in sources { try PrivateFileExport.copy(source, to: destination.appendingPathComponent(source.lastPathComponent)) }
                if let metadata { try PrivateFileExport.write(JSONEncoder().encode(metadata), to: destination.appendingPathComponent("OSpr-recovery.json")) }
                }.value
                status = "Unfinished tracks exported · original recovery kept"
              } catch { self.error = "Recovery export failed: \(error.localizedDescription). Original recovery is kept." }
            }
            return
        }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "OSpr-unfinished.wav"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let source = recovery.audioURL
        Task {
          do {
            try await Task.detached(priority: .utility) { try PrivateFileExport.copy(source, to: url) }.value
            status = "Unfinished audio exported · original recovery kept"
          } catch { self.error = "Recovery export failed: \(error.localizedDescription). Original recovery is kept." }
        }
    }
    func retryRecovery() {
        guard !busy, let pending else { return }
        generation = UUID(); let token = generation
        phase = "transcribing"; error = ""; status = "Recovering unfinished recording…"
        let config = settings
        operationTask = Task {
            // The retry button explicitly names the current speech route. Keep
            // rewriting off and never insert into a target from a previous run.
            do { try await prepareRecoveryMix(token: token) }
            catch { if token == generation { self.error = error.localizedDescription; phase = "idle" }; return }
            guard token == generation else { return }
            let recognized = await transcribe(file: recovery.audioURL, duration: pending.duration,
                config: config, mode: .verbatim, target: nil, source: "recovered recording", token: token, preserveRecoveryOnSaveFailure: true)
            if generation == token {
                if recognized { discardRecovery() }
                phase = "idle"
            }
        }
    }

    private func transcribe(file originalFile: URL, duration: Double, config: OSprSettings, mode: WritingMode, target: InsertionTarget?, source: String, token: UUID, preserveRecoveryOnSaveFailure: Bool = false, resultOverride: [String: Any]? = nil, startedAt: Date = Date()) async -> Bool {
        guard generation == token else { return false }
        var file = originalFile
        let recordID = UUID()
        var archived: ArchivedAudio?
        var uploadSnapshot: URL?
        var retentionWarning: String?
        defer {
            if let uploadSnapshot { Task { try? await audioArchive.discardUploadSource(uploadSnapshot) } }
            if let archived {
                let keep = historyState.retainsResultAudio(id: recordID, name: archived.name)
                Task {
                    do {
                        try await audioArchive.finishLease(archived.name, keep: keep); audioBytesUsed = try await audioArchive.bytesUsed()
                    }
                    catch { self.error = "Audio cleanup: \(error.localizedDescription)" }
                }
            }
        }
        var recognized = false
        let started = startedAt
        do {
            if config.keepAudio && config.saveHistory && settings.saveHistory {
                var staging: URL?
                do {
                    let output = try await audioArchive.newStagingURL(); staging = output
                    if config.transcriptionProvider != "local" { uploadSnapshot = try await audioArchive.snapshotUploadSource(originalFile, limitBytes: Int64(ProviderClient.maximumUploadBytes)) }
                    status = "Preparing private audio for review…"
                    let budget = Int64(config.validated().audioBudgetMB) * 1024 * 1024
                    _ = try await worker.request(["action": "prepare_review", "path": (uploadSnapshot ?? originalFile).path, "output": output.path, "limit_bytes": budget])
                    guard generation == token else { try? await audioArchive.discardStaging(output); return false }
                    archived = try await audioArchive.adoptPrepared(output, id: recordID, limitBytes: budget)
                    if let archived { file = archived.url; applyAudioEvictions(archived.evicted) }
                } catch {
                    if let staging { try? await audioArchive.discardStaging(staging) }
                    guard generation == token else { return false }
                    retentionWarning = "Audio was not retained: \(error.localizedDescription)"
                    self.error = retentionWarning ?? ""
                }
            }
            guard generation == token else { return false }
            let result: [String: Any]
            if let resultOverride { result = resultOverride }
            else if config.transcriptionProvider == "local" {
                let speakers = source != "dictation" && source != "recovered recording" && config.speakerLabels
                result = try await worker.request(["action": speakers ? "meeting" : "transcribe", "path": file.path, "model": config.model,
                    "language": config.language, "vocabulary": config.vocabulary, "trim": config.silenceTrim, "threshold": config.silenceThreshold])
            } else {
                let key = try ProviderCredentialScope.checkedKey(transcriptionKey, boundTo: transcriptionKeyScope, kind: .transcription, base: config.transcriptionURL)
                _ = try ProviderClient.speechEndpoint(base: config.transcriptionURL, provider: config.transcriptionProvider)
                let upload = uploadSnapshot ?? file
                let directFormats = ["wav", "mp3", "m4a", "flac", "ogg"]
                let uploadBytes = try upload.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                if config.transcriptionProvider == "deepgram" || uploadBytes >= ProviderClient.directUploadBytes || !directFormats.contains(upload.pathExtension.lowercased()) {
                    status = "Preparing audio upload parts locally…"
                    let workspace = try ProviderUploadWorkspace()
                    defer { workspace.close() }
                    let manifest = try await worker.request(["action": "prepare_upload_parts", "path": upload.path, "output_dir": workspace.url.path])
                    guard generation == token else { return false }
                    let plan = try ProviderUploadPlan(manifest, directory: workspace.url)
                    uploadingGeneration = token
                    defer { if uploadingGeneration == token { uploadingGeneration = nil } }
                    result = try await ProviderClient.transcribe(plan: plan, base: config.transcriptionURL,
                        model: config.transcriptionModel, key: key, language: config.language, vocabulary: config.vocabulary, provider: config.transcriptionProvider,
                        progress: { [weak self] part, total in
                            Task { @MainActor [weak self] in
                                guard let self, self.generation == token, self.uploadingGeneration == token else { return }
                                self.status = "Uploading to your selected provider · \(part) of \(total)"
                            }
                        })
                } else {
                    status = "Uploading to your selected speech provider…"
                    result = try await ProviderClient.transcribe(file: upload, base: config.transcriptionURL,
                        model: config.transcriptionModel, key: key, language: config.language, vocabulary: config.vocabulary, provider: config.transcriptionProvider)
                }
            }
            guard token == generation else { return false }
            let raw = result["raw_text"] as? String ?? result["text"] as? String ?? ""
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if result["silence"] as? Bool == true { status = "No speech detected"; return true }
                status = "The recognizer returned no words"
                self.error = "No transcript was returned. Completed recording audio is kept for retry; imported source files are unchanged. Try another model or language hint."
                return false
            }
            var text = TextPipeline.process(result["text"] as? String ?? raw, mode: mode, replacements: config.replacements, spokenPunctuation: config.spokenPunctuation, language: result["language"] as? String ?? config.language)
            if mode != .verbatim && config.rewriteProvider != "none" {
                status = "Refining your words…"
                let input = mode == .assistant ? "Selected passage:\n\(target?.selectedText ?? "")\n\nEditing request:\n\(text)" : text
                do {
                    let beforeRewrite = text
                    let instruction = mode.instruction(custom: config.customPrompt, language: config.translationLanguage)
                    if config.rewriteProvider == "local" {
                        let rewritten = try await worker.request(["action": "rewrite", "text": input, "instruction": instruction])
                        text = rewritten["text"] as? String ?? text
                    } else {
                        text = try await ProviderClient.rewrite(text: input, instruction: instruction, provider: config.rewriteProvider,
                            base: config.rewriteURL, model: config.rewriteModel, key: try ProviderCredentialScope.checkedKey(rewriteKey, boundTo: rewriteKeyScope, kind: .rewrite, base: config.rewriteURL))
                    }
                    if let reason = RewriteGuard.rejection(original: beforeRewrite, rewritten: text, mode: mode) {
                        text = beforeRewrite
                        self.error = "Original text retained. \(reason)"
                        if mode == .assistant {
                            saveResult(raw: raw, text: beforeRewrite, result: result, duration: duration, config: config, mode: mode, source: source, target: target, started: started, id: recordID, audioFile: archived?.name, audioWarning: retentionWarning)
                            return await finishResultStorage(config: config, token: token, preserveRecovery: preserveRecoveryOnSaveFailure)
                        }
                    }
                } catch {
                    guard generation == token else { return false }
                    self.error = "Transcription saved; rewrite failed: \(error.localizedDescription)"
                    if mode == .assistant { /* Never replace selected text with an unexecuted editing request. */
                        saveResult(raw: raw, text: text, result: result, duration: duration, config: config, mode: mode, source: source, target: target, started: started, id: recordID, audioFile: archived?.name, audioWarning: retentionWarning)
                        return await finishResultStorage(config: config, token: token, preserveRecovery: preserveRecoveryOnSaveFailure)
                    }
                }
            } else if mode == .assistant {
                throw OSprError.message("Edit selection needs a rewrite provider. Enable Local MLX or a BYOK provider in Settings.")
            } else if [.email, .bullets, .code, .translate, .custom].contains(mode) {
                self.error = "\(mode.title) needs a rewrite provider for formatting. This result contains the original transcription."
            }
            guard generation == token else { return false }
            saveResult(raw: raw, text: text, result: result, duration: duration, config: config, mode: mode, source: source, target: target, started: started, id: recordID, audioFile: archived?.name, audioWarning: retentionWarning)
            recognized = true
            if config.autoPaste && source == "dictation", let target { try await target.paste(text, restoreClipboard: config.restoreClipboard, allowUnverified: config.allowUnverifiedPaste) }
        } catch { if generation == token { self.error = error.localizedDescription; status = "Could not finish" } }
        return recognized ? await finishResultStorage(config: config, token: token, preserveRecovery: preserveRecoveryOnSaveFailure) : false
    }
    private func finishResultStorage(config: OSprSettings, token: UUID, preserveRecovery: Bool) async -> Bool {
        guard generation == token else { return false }
        do { try await historyState.flush(); return generation == token }
        catch {
            if generation == token {
                self.error = "Transcript is available in this session, but history could not be saved: \(error.localizedDescription) " + (preserveRecovery ? "Completed recording audio is kept for recovery." : "The imported source is unchanged; transcript export remains available.")
                status = preserveRecovery ? "History could not be saved · recording retained" : "History unsaved · export this result"
            }
            return !preserveRecovery && generation == token
        }
    }
    private func saveResult(raw: String, text: String, result: [String: Any], duration: Double, config: OSprSettings, mode: WritingMode, source: String, target: InsertionTarget?, started: Date, id: UUID, audioFile: String?, audioWarning: String?) {
        let segments = (result["segments"] as? [[String: Any]] ?? []).compactMap { segment -> Segment? in
            guard let start = segment["start"] as? Double, let end = segment["end"] as? Double, let text = segment["text"] as? String else { return nil }
            return Segment(start: start, end: end, text: text, speaker: segment["speaker"] as? Int, overlapSpeakers: segment["overlapSpeakers"] as? [Int])
        }
        let words = (result["words"] as? [[String: Any]])?.compactMap { word -> Segment? in
            guard let start = word["start"] as? Double, let end = word["end"] as? Double, let text = word["text"] as? String else { return nil }
            return Segment(start: start, end: end, text: text, speaker: word["speaker"] as? Int, overlapSpeakers: word["overlapSpeakers"] as? [Int])
        }
        var record = Transcript(rawText: raw, text: text, model: result["model"] as? String ?? config.model, mode: mode,
            app: target?.app?.localizedName ?? "", duration: result["audio_seconds"] as? Double ?? duration,
            latencyMS: Date().timeIntervalSince(started) * 1000, segments: segments, words: words, warning: source == "recovered recording" ? pending?.captureWarning : nil, source: source)
        record.id = id; record.audioFile = audioFile
        if let audioWarning { record.warning = [record.warning, audioWarning].compactMap { $0 }.joined(separator: " ") }
        historyState.submit(record, select: !backgroundImportActive)
        status = "Ready · \(Int(record.latencyMS)) ms"; preview = ""
    }
    func remove(_ record: Transcript) { if !quitting { historyState.remove(id: record.id) } }
    func removeHistoryRow(_ id: UUID) { if !quitting { historyState.remove(id: id) } }
    func clearHistory() { if !quitting { historyState.clear() } }
    func updateText(_ id: UUID, text: String) { if !quitting { historyState.updateText(id: id, text: text) } }
    func copyHistoryRow(_ id: UUID) {
        Task {
            do { if let record = try await historyState.record(id: id) { copy(record.text) } }
            catch { self.error = "Could not load transcript: \(error.localizedDescription)" }
        }
    }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); status = "Copied" }

    private func applyAudioEvictions(_ names: Set<String>) {
        if names.contains(audioReview.fileName ?? "") { audioReview.stop() }
        if !names.isEmpty { historyState.stripAudio(.names(names)) }
    }
    private func deleteAudioFiles(_ names: Set<String>) {
        guard !names.isEmpty else { return }
        if names.contains(audioReview.fileName ?? "") { audioReview.stop() }
        Task {
            do { try await audioArchive.remove(names); audioBytesUsed = try await audioArchive.bytesUsed() }
            catch { self.error = "Could not remove retained audio: \(error.localizedDescription)" }
        }
    }
    func eraseRetainedAudio(showStatus: Bool = true) {
        guard !busy else { return }
        audioMaintenance = true; audioReview.stop()
        Task {
            defer { audioMaintenance = false }
            do {
                historyState.stripAudio(.all)
                try await historyState.flush()
                try await audioArchive.eraseAll()
                audioBytesUsed = 0
                if showStatus { status = "Retained audio removed · transcript text kept" }
            } catch { self.error = "Could not remove retained audio: \(error.localizedDescription)" }
        }
    }
    func exportRetainedAudio(_ record: Transcript) {
        guard let name = record.audioFile else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "OSpr-audio.wav"; panel.allowedContentTypes = [.wav]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            do {
                guard let source = try await audioArchive.resolve(name: name, id: record.id) else { throw OSprError.message("Retained audio is no longer available.") }
                try await Task.detached(priority: .utility) {
                    try PrivateFileExport.copy(source, to: destination)
                }.value
                status = "Audio exported"
            } catch { self.error = "Audio export failed: \(error.localizedDescription)" }
        }
    }
    func reprocessRetainedAudio(_ record: Transcript) {
        guard !busy, let name = record.audioFile else { return }
        generation = UUID(); let token = generation
        phase = "transcribing"; error = ""; audioReview.pause()
        status = "Transcribing retained audio with your selected speech model…"
        var config = settings
        config.mode = .verbatim; config.rewriteProvider = "none"; config.autoPaste = false
        operationTask = Task {
            do {
                let source = try await audioArchive.copyForReprocessing(name: name, id: record.id)
                defer { Task { try? await audioArchive.discardStaging(source) } }
                guard generation == token else { return }
                _ = await transcribe(file: source, duration: record.duration, config: config, mode: .verbatim, target: nil,
                                     source: "Reprocessed · " + record.date.formatted(date: .abbreviated, time: .shortened), token: token)
            } catch { if generation == token { self.error = error.localizedDescription } }
            if generation == token { phase = "idle" }
        }
    }

    func generateNotes(_ record: Transcript) {
        guard !busy else { return }
        generation = UUID(); let token = generation
        phase = "transcribing"; error = ""; status = "Selecting source excerpts locally · first use downloads a 4B model"
        operationTask = Task {
            do {
                let result = try await worker.request(["action": "notes", "text": record.rawText])
                guard token == generation else { return }
                let excerpts = try (result["excerpts"] as? [[String: Any]] ?? []).map { item -> NoteExcerpt in
                    guard let id = item["id"] as? Int, let text = item["text"] as? String else { throw OSprError.message("Invalid notes response.") }
                    return NoteExcerpt(id: id, text: text)
                }
                let notes = try MeetingNotes(source: record.rawText, excerpts: excerpts, model: result["model"] as? String ?? "local")
                try await historyState.updateNotes(id: record.id, notes: notes, expectedRawText: record.rawText)
                status = notes.excerpts.isEmpty ? "No key excerpts selected · original text retained" : "Key excerpts ready · review the original context"
            } catch { if token == generation { self.error = error.localizedDescription } }
            if token == generation { phase = "idle" }
        }
    }

    func chooseWatchedFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        folderWatcher.settings.directory = directory.path
        do { try folderWatcher.save(reset: true) } catch { self.error = error.localizedDescription }
    }
    func saveWatchedFolder(reset: Bool) {
        do { try folderWatcher.save(reset: reset) } catch { self.error = error.localizedDescription }
    }
    private func processWatchedFile(_ file: URL) async -> Bool {
        guard !busy, settings.transcriptionProvider == "local" else { return false }
        var config = settings; config.mode = .verbatim; config.rewriteProvider = "none"; config.autoPaste = false
        generation = UUID(); let token = generation
        backgroundGeneration = token
        phase = "transcribing"; status = "Watched file · \(file.lastPathComponent)"
        let before = historyState.latest?.id
        let success = await transcribe(file: file, duration: 0, config: config, mode: .verbatim,
            target: nil, source: file.lastPathComponent, token: token)
        defer {
            if backgroundGeneration == token { backgroundGeneration = nil }
            if token == generation { phase = "idle" }
        }
        guard token == generation, success else { return false }
        guard let record = historyState.latest, record.id != before else { return true } // Silence is consumed without inventing a transcript.
        do {
            let output = file.deletingLastPathComponent().appendingPathComponent("OSpr Transcripts")
            _ = try LocalStore(directory: output)
            let prefix = file.deletingPathExtension().lastPathComponent + "-" + record.id.uuidString
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            let exports: [(String, Data)] = [("txt", Data(record.text.utf8)), ("json", try encoder.encode(record)),
                ("srt", Data(TranscriptExport.subtitles(record).utf8)), ("vtt", Data(TranscriptExport.subtitles(record, vtt: true).utf8))]
            for (ext, data) in exports {
                let destination = output.appendingPathComponent(prefix + "." + ext)
                try data.write(to: destination, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            }
            return true
        } catch { self.error = "Watched transcript retained in History; export failed: \(error.localizedDescription)"; return false }
    }

    func importFiles(_ files: [URL]? = nil) {
        guard !busy else { return }
        let urls: [URL]
        if let files { urls = files } else {
            let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
            panel.allowedContentTypes = [.audio, .movie]
            guard panel.runModal() == .OK else { return }; urls = panel.urls
        }
        phase = "transcribing"; generation = UUID(); let token = generation
        var config = settings
        if config.speakerLabels {
            guard config.transcriptionProvider == "local" && ["parakeet-v3", "whisper-turbo", "whisper-small"].contains(config.model) else {
                error = "Speaker labels need local Parakeet or Whisper. Choose one, or disable speaker labels for imports."; phase = "idle"; return
            }
            config.mode = .verbatim
        }
        operationTask = Task {
            for (index, file) in urls.enumerated() {
                guard generation == token else { break }
                status = "File \(index + 1) of \(urls.count) · \(file.lastPathComponent)"
                _ = await transcribe(file: file, duration: 0, config: config, mode: config.mode, target: nil, source: file.lastPathComponent, token: token)
            }
            if generation == token { phase = "idle" }
        }
    }
    func export(_ record: Transcript, format: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "OSpr-transcript.\(format)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
          do {
            try await Task.detached(priority: .utility) {
            let data: Data
            switch format {
            case "json": let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601; data = try encoder.encode(record)
            case "srt", "vtt": data = Data(TranscriptExport.subtitles(record, vtt: format == "vtt").utf8)
            default: data = Data(record.text.utf8)
            }
            try PrivateFileExport.write(data, to: url)
            }.value
            status = "Transcript exported · \(format.uppercased())"
          } catch { self.error = "Transcript export failed: \(error.localizedDescription)" }
        }
    }
    func refreshPermissions() {
        microphoneReady = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityReady = AXIsProcessTrusted()
    }
    func requestMicrophone() {
        Task {
            microphoneReady = await AVCaptureDevice.requestAccess(for: .audio)
            if !microphoneReady { error = "Allow OSpr microphone access in System Settings → Privacy & Security → Microphone. File imports do not require microphone access." }
        }
    }
    func requestAccessibility() {
        accessibilityReady = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    private func showOverlay() {
        if overlay == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true; panel.level = .floating; panel.backgroundColor = .clear; panel.isOpaque = false
            panel.hasShadow = true; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: RecordingOverlay(model: self, capture: capture))
            overlay = panel
        }
        if let screen = NSScreen.main { overlay?.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 180, y: screen.visibleFrame.minY + 30)) }
        overlay?.orderFrontRegardless()
    }
}
