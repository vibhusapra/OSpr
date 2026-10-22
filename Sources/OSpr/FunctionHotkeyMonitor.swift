import AppKit
import OSprCore

/// Optional observer, installed only after the user selects Fn and AX is trusted.
/// Reads key codes/modifier flags, never characters; all events pass unchanged.
@MainActor final class FunctionHotkeyMonitor {
    @MainActor private final class Resources {
        var global: Any?
        var local: Any?
        var arm: Task<Void, Never>?
        var watchdog: Timer?
        func close() {
            arm?.cancel(); arm = nil
            watchdog?.invalidate(); watchdog = nil
            if let global { NSEvent.removeMonitor(global) }; global = nil
            if let local { NSEvent.removeMonitor(local) }; local = nil
        }
    }
    private let resources = Resources()
    private var gesture = FunctionShortcutGesture()
    var pressed: (() -> Void)?
    var released: (() -> Void)?
    var cancelled: (() -> Void)?
    var failed: ((String) -> Void)?

    init() throws {
        guard AXIsProcessTrusted() else {
            throw OSprError.message("Globe/Fn requires Accessibility access. Enable insertion access first, or keep a modified-key shortcut. The previous shortcut remains active.")
        }
        // Apple documents both monitor callbacks as main-thread callbacks:
        // developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html
        resources.global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.receive(event) }
        }
        resources.local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.receive(event) }
            return event
        }
        guard resources.global != nil, resources.local != nil else {
            resources.close()
            throw OSprError.message("macOS could not enable Globe/Fn monitoring. The previous shortcut remains active.")
        }
    }

    private func receive(_ event: NSEvent) {
        if event.type == .flagsChanged && event.keyCode == 63 {
            let down = event.modifierFlags.contains(.function)
            let other = !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            apply(down ? .functionDown(eligible: !other) : .functionUp)
        } else if gesture.active {
            apply(.otherKey)
        }
    }

    private func apply(_ input: FunctionShortcutGesture.Input) {
        for effect in gesture.receive(input) {
            switch effect {
            case .arm:
                resources.arm?.cancel()
                resources.arm = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                    guard let self, !Task.isCancelled else { return }
                    if !AXIsProcessTrusted() { self.interrupted(); return }
                    // A queued key-up is allowed to settle the gesture. Never
                    // turn a physically released/lost gesture into a late press.
                    if CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn) { self.apply(.delayElapsed) }
                }
            case .cancelTimer:
                resources.arm?.cancel(); resources.arm = nil
            case .press: pressed?()
            case .release: released?()
            case .cancelRecording: cancelled?()
            }
        }
        if !gesture.active {
            resources.watchdog?.invalidate(); resources.watchdog = nil
        } else if resources.watchdog == nil {
            resources.watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if !AXIsProcessTrusted() { self.interrupted() }
                    else if !CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn) { self.apply(.reset) }
                }
            }
        }
    }
    private func interrupted() {
        apply(.reset)
        failed?("Globe/Fn monitoring was interrupted. Check Accessibility access or choose a modified-key shortcut.")
    }
    func stop() { apply(.reset); resources.close() }
    deinit {
        let cleanup = resources
        Task { @MainActor in cleanup.close() }
    }
}
