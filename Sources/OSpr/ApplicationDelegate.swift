import AppKit

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            do {
                try await model.prepareForTermination()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "OSpr could not finish saving"
                alert.informativeText = error.localizedDescription + "\n\nKeep OSpr open to retry or export your transcript. Quitting now can lose unsaved changes."
                alert.addButton(withTitle: "Keep OSpr open")
                alert.addButton(withTitle: "Quit without saving")
                let quit = alert.runModal() == .alertSecondButtonReturn
                if !quit { model.cancelTermination() }
                terminating = false
                sender.reply(toApplicationShouldTerminate: quit)
            }
        }
        return .terminateLater
    }
}
