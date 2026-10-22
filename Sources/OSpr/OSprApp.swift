import SwiftUI
import AppKit

@main struct OSprApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow
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
