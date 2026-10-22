import Foundation
import OSprCore

@MainActor final class FolderWatcher: ObservableObject {
    @Published var settings = FolderWatchSettings()
    @Published var status = "Disabled"
    private var queue = FolderWatchQueue()
    private var timer: Timer?
    private var scanning = false
    private var store: LocalStore
    private var epoch = UUID()
    var loadError = ""
    var canProcess: () -> Bool = { false }
    var pauseReason: () -> String? = { nil }
    var process: ((URL) async -> Bool)?
    var reportError: (String) -> Void = { _ in }

    init(directory: URL) throws {
        store = try LocalStore(directory: directory)
        do {
            settings = try store.read(FolderWatchSettings.self, name: "watch-settings.json") ?? settings
            queue = FolderWatchQueue(completed: try store.read([String: Date].self, name: "watch-completed.json") ?? [:])
        } catch {
            settings.enabled = false
            loadError = "Watched-folder state could not be read. Original files were preserved; automation is paused."
        }
    }
    func save(reset: Bool = false) throws {
        if reset { queue = FolderWatchQueue() }
        if settings.enabled && !settings.directory.isEmpty && settings.ignoreExisting && reset {
            queue.ignore(try MediaCandidate.scan(directory: URL(fileURLWithPath: settings.directory)))
        }
        try store.write(settings, name: "watch-settings.json")
        try store.write(queue.completed, name: "watch-completed.json")
        start()
    }
    func start() {
        timer?.invalidate(); timer = nil; epoch = UUID()
        guard settings.enabled, !settings.directory.isEmpty else { status = "Disabled"; return }
        status = "Waiting for stable new files"
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.scan() }
        }
    }
    private func scan() async {
        guard !scanning else { return }
        if let reason = pauseReason() { status = reason; return }
        guard canProcess(), let process else { return }
        scanning = true; defer { scanning = false }
        let directory = URL(fileURLWithPath: settings.directory), token = epoch
        do {
            let files = try await Task.detached(priority: .utility) { try MediaCandidate.scan(directory: directory) }.value
            guard epoch == token else { return }
            let ready = queue.ready(files)
            guard let candidate = ready.first else { status = "Waiting for stable new files"; return }
            status = "Transcribing \(candidate.url.lastPathComponent)"
            let success = await process(candidate.url)
            guard epoch == token else { return }
            queue.finish(candidate, success: success)
            try store.write(queue.completed, name: "watch-completed.json")
            status = success ? "Processed \(candidate.url.lastPathComponent)" : "Failed; retrying after one minute"
        } catch { status = "Folder unavailable"; reportError(error.localizedDescription) }
    }
    deinit { timer?.invalidate() }
}
