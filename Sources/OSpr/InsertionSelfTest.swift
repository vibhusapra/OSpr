import AppKit
import Combine
import OSprCore

/// Confirmation must not move keyboard focus away from the captured field.
final class InsertionTestWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Carries no transcript or model state. The private sender owns the captured
/// field only until send/cancel; the UI sees the app name and selection flags.
@MainActor struct InsertionTestDestination {
    let name: String
    let verified: Bool
    let replacesSelection: Bool
    let send: (String, Bool, Bool, ((ClipboardRestorer.Outcome) -> Void)?) async throws -> InsertionDelivery

    static func capture(allowUnverified: Bool) throws -> Self {
        let target = InsertionTarget.capture()
        guard target.focusConsistent else { throw OSprError.message("Focus changed. Choose the intended field and try again.") }
        guard !target.secure else { throw OSprError.message("Password fields cannot receive the test phrase.") }
        guard let app = target.app, !app.isTerminated, app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            throw OSprError.message("Focus a field in another app during the countdown.")
        }
        let verified = target.element != nil && target.selectedRange != nil
        guard verified || allowUnverified else {
            throw OSprError.message("OSpr could not verify a text field and cursor. Focus an editable field and try again.")
        }
        return Self(name: app.localizedName ?? app.bundleIdentifier ?? "Destination app", verified: verified,
                    replacesSelection: !target.selectedText.isEmpty, send: { text, restore, allow, completion in
            try await target.paste(text, restoreClipboard: restore, allowUnverified: allow, clipboardCompletion: completion)
        })
    }
}

/// A setup check, not a dictation simulation. Sending requires a separate click
/// after capture; only the user's subsequent acknowledgement confirms delivery.
@MainActor final class InsertionSelfTest: ObservableObject {
    enum Phase: Equatable { case idle, countdown, ready, sending, sent, confirmed, failed }
    static let phrase = "OSpr is ready."
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var remaining: Int?
    @Published private(set) var destinationName = ""
    @Published private(set) var verified = false
    @Published private(set) var replacesSelection = false
    @Published private(set) var message = ""
    @Published private(set) var requiresAccessibility = false
    @Published private(set) var delivery: InsertionDelivery?
    @Published private(set) var clipboardOutcome: ClipboardRestorer.Outcome?
    var isPresented: Bool { phase != .idle }
    private let countdown: DictationCountdown
    private let permission: () -> Bool
    private let capture: (Bool) throws -> InsertionTestDestination
    private var destination: InsertionTestDestination?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var restoreClipboard = true
    private var allowUnverified = false

    init(wait: @escaping DictationCountdown.Wait = { try await Task.sleep(for: .seconds(1)) },
         permission: @escaping () -> Bool = { AXIsProcessTrusted() },
         capture: ((Bool) throws -> InsertionTestDestination)? = nil) {
        countdown = DictationCountdown(wait: wait); self.permission = permission
        self.capture = capture ?? { try InsertionTestDestination.capture(allowUnverified: $0) }
    }
    func start(restoreClipboard: Bool, allowUnverified: Bool) {
        cancel()
        self.restoreClipboard = restoreClipboard; self.allowUnverified = allowUnverified
        guard permission() else {
            requiresAccessibility = true; phase = .failed
            message = "Enable insertion access, then try again. This test does not need a microphone or model."
            return
        }
        let token = generation
        phase = .countdown; message = "Focus the text field you want to test."
        countdown.start(tick: { [weak self] remaining in
            guard let self, self.generation == token else { return }
            self.remaining = remaining
        }, completion: { [weak self] in
            guard let self, self.generation == token else { return }
            self.remaining = nil
            do {
                let target = try self.capture(allowUnverified)
                self.destination = target; self.destinationName = target.name
                self.verified = target.verified; self.replacesSelection = target.replacesSelection
                self.phase = .ready
                self.message = "Check the destination before sending the test phrase."
            } catch {
                self.destination = nil; self.phase = .failed; self.message = error.localizedDescription
            }
        })
    }
    func confirm() {
        guard phase == .ready, let destination else { return }
        guard permission() else {
            self.destination = nil; requiresAccessibility = true; phase = .failed
            message = "Insertion access is no longer available. Enable it, then try again."
            return
        }
        let token = generation, restore = restoreClipboard, allow = allowUnverified
        let send = destination.send
        self.destination = nil; phase = .sending; message = "Sending the test phrase…"
        task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let delivered = try await send(Self.phrase, restore, allow, { [weak self] outcome in
                    guard let self, self.generation == token, self.isPresented else { return }
                    self.clipboardOutcome = outcome
                })
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.delivery = delivered; self.phase = .sent
                self.message = "Check the field. Did the phrase appear?"
                self.task = nil
            } catch {
                guard let self, self.generation == token else { return }
                self.phase = .failed; self.message = error.localizedDescription; self.task = nil
            }
        }
    }
    func acknowledge(appeared: Bool) {
        guard phase == .sent else { return }
        phase = appeared ? .confirmed : .failed
        message = appeared ? "Text insertion confirmed." : "The phrase did not appear. Focus an editable field and try again."
    }
    func retry() { start(restoreClipboard: restoreClipboard, allowUnverified: allowUnverified) }
    func cancel() {
        generation = UUID(); countdown.cancel(); task?.cancel(); task = nil; destination = nil
        phase = .idle; remaining = nil; destinationName = ""; verified = false; replacesSelection = false
        message = ""; requiresAccessibility = false; delivery = nil; clipboardOutcome = nil
    }
    var clipboardMessage: String? {
        guard delivery != nil else { return nil }
        if delivery == .accessibility { return "Sent without using the clipboard." }
        switch clipboardOutcome {
        case .restored: return "Captured clipboard data restored."
        case .userChanged: return "Your newer clipboard content was kept."
        case .superseded: return "A later paste took over clipboard restoration."
        case .notRequested: return "Clipboard restoration is off in your settings."
        case .failed: return "Clipboard restoration could not be verified."
        case nil: return "Restoring clipboard…"
        }
    }
    deinit { task?.cancel() }
}
