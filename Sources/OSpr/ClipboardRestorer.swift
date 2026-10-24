import AppKit

/// Overlapping paste fallbacks share the original clipboard lease. A later
/// user copy wins. Restoring on a timer never keeps the dictation UI busy.
@MainActor final class ClipboardRestorer {
    enum Outcome: Equatable { case restored, userChanged, superseded, notRequested, failed }
    static let shared = ClipboardRestorer(board: .general)
    typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]
    private let board: NSPasteboard
    private var owned: (version: Int, saved: Snapshot, completion: ((Outcome) -> Void)?)?
    private var task: Task<Void, Never>?
    private let delay: Duration
    init(board: NSPasteboard, delay: Duration = .milliseconds(700)) { self.board = board; self.delay = delay }
    private func snapshot() -> Snapshot {
        (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
    }
    @discardableResult func replace(with text: String, restore: Bool, completion: ((Outcome) -> Void)? = nil) -> Int {
        let previous = owned
        let saved: Snapshot
        if let owned, board.changeCount == owned.version { saved = owned.saved }
        else { saved = snapshot() }
        task?.cancel(); task = nil
        board.clearContents(); board.setString(text, forType: .string)
        let version = board.changeCount
        owned = restore ? (version, saved, completion) : nil
        if restore {
            task = Task { [weak self, delay] in
                do { try await Task.sleep(for: delay) } catch { return }
                self?.restoreIfStillOwned(version: version)
            }
        }
        // State is committed before callbacks, which may start another lease.
        previous?.completion?(.superseded)
        if !restore { completion?(.notRequested) }
        return version
    }
    func restoreIfStillOwned(version: Int) {
        guard let owned, owned.version == version else { return }
        self.owned = nil; task?.cancel(); task = nil
        guard board.changeCount == version else { owned.completion?(.userChanged); return }
        board.clearContents()
        var written = true
        if !owned.saved.isEmpty {
            written = board.writeObjects(owned.saved.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            })
        }
        if owned.completion != nil { owned.completion?(written && snapshot() == owned.saved ? .restored : .failed) }
    }
    func restorePending() { if let owned { restoreIfStillOwned(version: owned.version) } }
}
