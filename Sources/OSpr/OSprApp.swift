import SwiftUI
import AppKit
import OSprCore
import Darwin

@main struct OSprApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    init() {
        let current = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "app.ospr.mac"
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter {
            $0.processIdentifier != current && $0.executableURL?.lastPathComponent == "OSpr"
        }
        // Older builds did not take the file lock. Prefer a finished GUI before
        // creating any model, history writer, audio reconciler or global shortcut.
        if let running = existing.first(where: \.isFinishedLaunching) {
            _ = running.activate(options: [])
            exit(EXIT_SUCCESS)
        }
        do {
            // Explicit launch profiles allow isolated QA without touching the
            // normal archive, global shortcuts, watcher or credential scopes.
            let profile = ProcessInfo.processInfo.environment["OSPR_DATA_DIRECTORY"]
                ?? Bundle.main.object(forInfoDictionaryKey: "OSprDataDirectory") as? String
            if let profile, !profile.hasPrefix("/") { fatalError("OSPR_DATA_DIRECTORY must be an absolute path") }
            let directory = profile.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? LocalStore.applicationDirectory
            let lock = try AppInstanceLock(directory: directory)
            let value = AppModel(instanceLock: lock, directory: directory,
                enableServices: ProcessInfo.processInfo.environment["OSPR_DISABLE_BACKGROUND_SERVICES"] != "1"
                    && Bundle.main.object(forInfoDictionaryKey: "OSprDisableBackgroundServices") as? Bool != true)
            _model = StateObject(wrappedValue: value)
            appDelegate.model = value
        } catch AppInstanceLock.Failure.alreadyRunning {
            if let running = existing.first { _ = running.activate(options: []) }
            exit(EXIT_SUCCESS)
        } catch { fatalError("Cannot open OSpr data folder: \(error.localizedDescription)") }
    }
    var body: some Scene {
        Window("OSpr", id: "workspace") {
            WorkspaceView(model: model)
                .frame(minWidth: 940, minHeight: 680)
                .tint(.osprPurple)
        }
        .defaultSize(width: 1120, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) { Button("Import audio or video…") { model.importFiles() }.keyboardShortcut("o") }
            CommandMenu("Dictation") {
                Button(model.phase == "recording" ? "Finish dictation" : "Start dictation") { model.toggle() }.keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Cancel current operation") { model.cancel() }.keyboardShortcut(.escape, modifiers: []).disabled(!model.busy)
            }
        }
        MenuBarExtra("OSpr", systemImage: model.phase == "recording" ? "mic.fill" : "waveform") {
            Text(model.status)
            Button(model.phase == "recording" ? "Finish dictation" : "Start dictation") { model.toggle() }.disabled(model.busy && model.phase != "recording")
            Button("Show OSpr") { openWindow(id: "workspace"); NSApp.activate(ignoringOtherApps: true) }
            Button("Import files…") { model.importFiles() }.disabled(model.busy)
            Divider()
            Button("Quit OSpr") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
}
