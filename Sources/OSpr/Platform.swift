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
    var pressed: (() -> Void)?
    var released: (() -> Void)?
    func register(code: UInt32, modifiers: UInt32) throws {
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
                let owner = Unmanaged<Hotkey>.fromOpaque(context).takeUnretainedValue()
                let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                MainActor.assumeIsolated { if down { owner.pressed?() } else { owner.released?() } }
                return noErr
            }, events.count, &events, pointer, &handler)
        }
        var replacement: EventHotKeyRef?
        let status = RegisterEventHotKey(code, modifiers, EventHotKeyID(signature: 0x4F535052, id: 1),
                                        GetApplicationEventTarget(), 0, &replacement)
        guard status == noErr else { throw OSprError.message("That shortcut is already in use. The previous shortcut remains active; choose another in Settings.") }
        if let reference { UnregisterEventHotKey(reference) }
        reference = replacement; combination = (code, modifiers)
    }
    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}

@MainActor final class Capture: ObservableObject {
    @Published var level: Float = 0
    @Published var seconds: Double = 0
    var silenceReached: (() -> Void)?
    private var engine: AVAudioEngine?
    private var writer: AudioSink?
    private var timer: Timer?
    private var started = Date()
    private var url: URL?
    private let lock = NSLock()
    private var lastVoice = Date()
    private var hasVoice = false
    private var autoStop = 0.0
    private var threshold: Float = 0.003
    private var tapInstalled = false
    private var previewRing = AudioRing(capacity: 1)
    private var inputRate: Double = 48000
    private var capturedFrames = 0
    private var previewFrames = 0
    private var monoScratch = [Float](repeating: 0, count: 8192)
    private var captureGeneration = UUID()
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
        self.threshold = Float(threshold); hasVoice = false
        self.inputRate = format.sampleRate; self.previewRing = AudioRing(capacity: Int(format.sampleRate * 12))
        self.capturedFrames = 0; self.previewFrames = 0
        started = Date(); lastVoice = started; seconds = 0
        let captureToken = UUID(); lock.lock(); captureGeneration = captureToken; lock.unlock()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, writer] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            guard self.captureGeneration == captureToken else { self.lock.unlock(); return }
            writer.enqueue(buffer)
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0,
                  buffer.frameLength <= 8192 else { self.lock.unlock(); return }
            let frames = Int(buffer.frameLength)
            let rms = self.monoScratch.withUnsafeMutableBufferPointer { mono in
                let rms = AudioMath.downmix(channels: channels, channelCount: Int(buffer.format.channelCount),
                    frames: frames, interleaved: buffer.format.isInterleaved, destination: mono)
                self.previewRing.append(UnsafeBufferPointer(start: mono.baseAddress, count: frames))
                return rms
            }
            self.capturedFrames += frames
            self.lock.unlock()
            DispatchQueue.main.async {
                guard self.captureGeneration == captureToken else { return }
                self.level = min(1, rms * 12)
                if rms > self.threshold { self.lastVoice = Date(); self.hasVoice = true }
            }
        }
        tapInstalled = true
        do { try engine.start() } catch { input.removeTap(onBus: 0); tapInstalled = false; self.engine = nil; try? writer.finish(); self.writer = nil; try? FileManager.default.removeItem(at: url); throw error }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seconds = Date().timeIntervalSince(self.started)
                if self.writer?.error != nil { self.silenceReached?(); return }
                if self.seconds >= 300 || (self.autoStop > 0 && self.hasVoice && Date().timeIntervalSince(self.lastVoice) > self.autoStop) {
                    self.silenceReached?()
                }
            }
        }
        return url
    }
    func stop() throws -> URL? {
        lock.lock(); captureGeneration = UUID(); lock.unlock()
        timer?.invalidate(); timer = nil
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine?.stop(); engine = nil
        let writer = self.writer; self.writer = nil
        level = 0
        try writer?.finish()
        return url
    }
    func snapshot(incremental: Bool = false) throws -> URL? {
        guard let url else { return nil }
        let destination = url.deletingPathExtension().appendingPathExtension("preview.wav")
        lock.lock()
        let delta = capturedFrames - previewFrames
        let overflow = incremental && delta > Int(inputRate * 12)
        let previewSamples = overflow ? [] : previewRing.snapshot(last: incremental ? delta : nil)
        if incremental && !overflow { previewFrames = capturedFrames }
        lock.unlock()
        if overflow { throw OSprError.message("Streaming preview fell behind. Final transcription will use the complete recording.") }
        // WAV headers of the active recording are not finalized. Export a bounded
        // in-memory tail instead of reading the still-open file.
        guard !previewSamples.isEmpty, let format = AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(previewSamples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(previewSamples.count)
        previewSamples.withUnsafeBufferPointer { samples in buffer.floatChannelData![0].update(from: samples.baseAddress!, count: samples.count) }
        let writer = try AVAudioFile(forWriting: destination, settings: format.settings)
        try writer.write(from: buffer)
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
    func paste(_ text: String, restoreClipboard: Bool) async throws {
        guard !secure else { throw OSprError.message("Dictation into password fields is disabled. The transcript is available in OSpr.") }
        guard AXIsProcessTrusted() else { throw OSprError.message("Allow OSpr Accessibility access to paste into other apps. The transcript is ready to copy.") }
        guard let app, !app.isTerminated, app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            throw OSprError.message("No external target is available. Copy the transcript from OSpr.")
        }
        // Do not steal focus or paste into a different field if the user switched.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw OSprError.message("You switched apps while transcribing. Copy the result from OSpr when ready.")
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
            if AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success { return }
        }
        let board = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        board.clearContents(); board.setString(text, forType: .string)
        let version = board.changeCount
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
        if restoreClipboard {
            try? await Task.sleep(for: .milliseconds(700))
            if board.changeCount == version {
                board.clearContents()
                board.writeObjects(saved.map { data in let item = NSPasteboardItem(); for (type, value) in data { item.setData(value, forType: type) }; return item })
            }
        }
    }
}
