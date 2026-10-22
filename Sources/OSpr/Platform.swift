import AppKit
import AVFoundation
import Carbon
import Security
import OSprCore

enum KeyVault {
    static func read(_ account: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.ospr.credentials", kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func write(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.ospr.credentials", kSecAttrAccount as String: account]
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw OSprError.message("Keychain removal failed (\(status)).") }
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var entry = query; entry[kSecValueData as String] = data
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(entry as CFDictionary, nil)
            guard added == errSecSuccess else { throw OSprError.message("Keychain save failed (\(added)).") }
        } else if status != errSecSuccess { throw OSprError.message("Keychain update failed (\(status)).") }
    }
}

@MainActor final class Hotkey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var combination: (code: UInt32, modifiers: UInt32)?
    private var functionMonitor: FunctionHotkeyMonitor?
    private var carbonEdges = ShortcutEdgeGate()
    private var nextRegistration: UInt32 = 1
    var hasBinding: Bool { reference != nil || functionMonitor != nil }
    var functionOnlyActive: Bool { functionMonitor != nil }
    var registeredCombination: (code: UInt32, modifiers: UInt32)? { combination }
    var pressed: (() -> Void)?
    var released: (() -> Void)?
    var cancelled: (() -> Void)?
    var failed: ((String) -> Void)?
    func register(code: UInt32, modifiers: UInt32, functionOnly: Bool = false) throws {
        if functionOnly {
            guard AXIsProcessTrusted() else {
                let fallback = reference != nil ? "The previous modified shortcut remains active." : "Choose a modified shortcut until access is enabled."
                throw OSprError.message("Globe/Fn requires Accessibility access. " + fallback)
            }
            if functionMonitor != nil { return }
            let replacement = try FunctionHotkeyMonitor()
            replacement.pressed = { [weak self] in self?.pressed?() }
            replacement.released = { [weak self] in self?.released?() }
            replacement.cancelled = { [weak self] in self?.cancelled?() }
            replacement.failed = { [weak self] message in self?.failed?(message) }
            if let reference { UnregisterEventHotKey(reference) }
            reference = nil; combination = nil; carbonEdges.clear(); functionMonitor = replacement
            return
        }
        guard code < 128, modifiers & 0x1900 != 0 else {
            throw OSprError.message("Choose a shortcut with Control, Option or Command, so ordinary typing stays available.")
        }
        if reference != nil, combination?.code == code, combination?.modifiers == modifiers { return }
        if handler == nil {
            var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let pointer = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return noErr }
                var identifier = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                    identifier.signature == 0x4F535052 else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<Hotkey>.fromOpaque(context).takeUnretainedValue()
                let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                MainActor.assumeIsolated {
                    switch owner.carbonEdges.receive(id: identifier.id, pressed: down) {
                    case .press?: owner.pressed?()
                    case .release?: owner.released?()
                    case nil: break
                    }
                }
                return noErr
            }, events.count, &events, pointer, &handler)
        }
        var replacement: EventHotKeyRef?
        let identifier = nextRegistration
        nextRegistration &+= 1
        if nextRegistration == 0 { nextRegistration = 1 }
        let status = RegisterEventHotKey(code, modifiers, EventHotKeyID(signature: 0x4F535052, id: identifier),
                                        GetApplicationEventTarget(), 0, &replacement)
        guard status == noErr else { throw OSprError.message("That shortcut is already in use. The previous shortcut remains active; choose another in Settings.") }
        if let reference { UnregisterEventHotKey(reference) }
        functionMonitor?.stop(); functionMonitor = nil
        reference = replacement; combination = (code, modifiers); carbonEdges.activate(identifier)
    }
    func unregister() {
        functionMonitor?.stop(); functionMonitor = nil
        if let reference { UnregisterEventHotKey(reference) }; reference = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
        combination = nil
        carbonEdges.clear()
    }
    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        let monitor = functionMonitor
        Task { @MainActor in monitor?.stop() }
    }
}

@MainActor final class Capture: ObservableObject {
    @Published var level: Float = 0
    @Published var seconds: Double = 0
    var silenceReached: (() -> Void)?
    private var engine: AVAudioEngine?
    private var writer: AudioSink?
    private var pipeline: CapturePipeline?
    private var captureFailure: Error?
    private var timer: Timer?
    private var started = ProcessInfo.processInfo.systemUptime
    private var url: URL?
    private var autoStop = 0.0
    private var tapInstalled = false
    private var inputRate: Double = 48000
    static var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }
    func start(deviceID: String, autoStop: Double, threshold: Double) throws -> URL {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw OSprError.message("Allow OSpr microphone access in System Settings → Privacy & Security → Microphone.") }
        let engine = AVAudioEngine()
        if !deviceID.isEmpty {
            // AVCapture IDs match CoreAudio UIDs. Resolve using the system device list.
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
            var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)
            var matched = false
            for var device in devices {
                var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var uid: CFString?; var uidSize = UInt32(MemoryLayout<CFString?>.size)
                let uidStatus = withUnsafeMutablePointer(to: &uid) { pointer in AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, pointer) }
                if uidStatus == noErr, uid as String? == deviceID {
                    guard let unit = engine.inputNode.audioUnit else { throw OSprError.message("Audio input is unavailable.") }
                    let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
                    guard status == noErr else { throw OSprError.message("Could not open the selected microphone.") }
                    matched = true
                    break
                }
            }
            guard matched else { throw OSprError.message("The selected microphone is disconnected. Choose System default in Settings.") }
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw OSprError.message("No usable audio input. Check your microphone connection.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(UUID().uuidString + ".wav")
        let writer = try AudioSink(url: url, format: format)
        self.writer = writer; self.engine = engine; self.url = url; self.autoStop = autoStop
        self.inputRate = format.sampleRate; captureFailure = nil
        started = ProcessInfo.processInfo.systemUptime; seconds = 0
        let pipeline = CapturePipeline(sink: writer, format: format, threshold: Float(threshold), now: started)
        self.pipeline = pipeline
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in pipeline.ingest(buffer) }
        tapInstalled = true
        do { try engine.start() } catch { input.removeTap(onBus: 0); tapInstalled = false; self.engine = nil; try? writer.finish(); self.writer = nil; try? FileManager.default.removeItem(at: url); throw error }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.seconds = now - self.started
                guard let telemetry = self.pipeline?.telemetry() else { return }
                self.level = min(1, telemetry.rms * 12)
                if self.pipeline?.error != nil { self.silenceReached?(); return }
                if self.engine?.isRunning == false || now - telemetry.receivedAt > 5 {
                    self.captureFailure = OSprError.message("Microphone audio stopped. Check the device connection; partial audio was kept.")
                    self.silenceReached?(); return
                }
                if self.seconds >= 300 || (self.autoStop > 0 && telemetry.hasVoice && now - telemetry.voiceAt > self.autoStop) {
                    self.silenceReached?()
                }
            }
        }
        return url
    }
    func stop() throws -> URL? {
        timer?.invalidate(); timer = nil
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine?.stop(); engine = nil
        let writer = self.writer; self.writer = nil
        level = 0
        if let pipeline { try pipeline.finish() } else { try writer?.finish() }
        if let captureFailure { throw captureFailure }
        return url
    }
    func snapshot(incremental: Bool = false) throws -> URL? {
        guard let url else { return nil }
        let destination = url.deletingPathExtension().appendingPathExtension("preview.wav")
        let previewSamples = try pipeline?.snapshot(incremental: incremental) ?? []
        // WAV headers of the active recording are not finalized. Export a bounded
        // in-memory tail instead of reading the still-open file.
        guard !previewSamples.isEmpty, let format = AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(previewSamples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(previewSamples.count)
        previewSamples.withUnsafeBufferPointer { samples in buffer.floatChannelData![0].update(from: samples.baseAddress!, count: samples.count) }
        let writer = try PCMFileWriter(url: destination, format: format)
        try writer.write(buffer)
        try writer.close()
        return destination
    }
}

@MainActor struct InsertionTarget {
    let app: NSRunningApplication?
    let element: AXUIElement?
    let selectedText: String
    let secure: Bool
    var selectedRange: CFTypeRef? = nil
    static func capture() -> InsertionTarget {
        let app = NSWorkspace.shared.frontmostApplication
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        let element = focused.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeBitCast($0, to: AXUIElement.self) : nil }
        var selected: CFTypeRef?; var subrole: CFTypeRef?; var range: CFTypeRef?
        if let element {
            AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected)
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
            AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range)
        }
        return .init(app: app, element: element, selectedText: selected as? String ?? "", secure: subrole as? String == "AXSecureTextField", selectedRange: range)
    }
    func paste(_ text: String, restoreClipboard: Bool, allowUnverified: Bool = false) async throws {
        guard !secure else { throw OSprError.message("Dictation into password fields is disabled. The transcript is available in OSpr.") }
        guard AXIsProcessTrusted() else { throw OSprError.message("Allow OSpr Accessibility access to paste into other apps. The transcript is ready to copy.") }
        guard let app, !app.isTerminated, app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            throw OSprError.message("No external target is available. Copy the transcript from OSpr.")
        }
        // Do not steal focus or paste into a different field if the user switched.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw OSprError.message("You switched apps while transcribing. Copy the result from OSpr when ready.")
        }
        guard allowUnverified || (element != nil && selectedRange != nil) else {
            throw OSprError.message("The destination field or cursor could not be verified. Copy the transcript, or enable unverified-field fallback in Settings for this app.")
        }
        if let element {
            var current: CFTypeRef?
            AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &current)
            guard let current, CFEqual(current, element) else { throw OSprError.message("The focused field changed. Copy the result from OSpr.") }
            if let selectedRange {
                var currentRange: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &currentRange)
                guard let currentRange, CFEqual(currentRange, selectedRange) else { throw OSprError.message("The text cursor moved. Copy the result from OSpr.") }
            }
            if !selectedText.isEmpty {
                var currentText: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &currentText)
                guard currentText as? String == selectedText else { throw OSprError.message("The selected passage changed. Copy the result from OSpr.") }
            }
            if AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success { return }
        }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            throw OSprError.message("The paste shortcut could not be created. Copy the transcript from OSpr.")
        }
        ClipboardRestorer.shared.replace(with: text, restore: restoreClipboard)
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
}
