import AppKit

/// Overlapping paste fallbacks share the original clipboard lease. A later
/// user copy wins. Restoring on a timer never keeps the dictation UI busy.
@MainActor final class ClipboardRestorer {
    static let shared = ClipboardRestorer(board: .general)
    typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]
    private let board: NSPasteboard
    private var owned: (version: Int, saved: Snapshot)?
    private var task: Task<Void, Never>?
    private let delay: Duration
    init(board: NSPasteboard, delay: Duration = .milliseconds(700)) { self.board = board; self.delay = delay }
    @discardableResult func replace(with text: String, restore: Bool) -> Int {
        let saved: Snapshot
        if let owned, board.changeCount == owned.version { saved = owned.saved }
        else {
            saved = (board.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
            }
        }
        task?.cancel()
        board.clearContents(); board.setString(text, forType: .string)
        let version = board.changeCount
        owned = restore ? (version, saved) : nil
        if restore {
            task = Task { [weak self, delay] in
                do { try await Task.sleep(for: delay) } catch { return }
                self?.restoreIfStillOwned(version: version)
            }
        }
        return version
    }
    func restoreIfStillOwned(version: Int) {
        guard let owned, owned.version == version else { return }
        defer { self.owned = nil; task?.cancel(); task = nil }
        guard board.changeCount == version else { return }
        board.clearContents()
        if !owned.saved.isEmpty {
            board.writeObjects(owned.saved.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            })
        }
    }
    func restorePending() { if let owned { restoreIfStillOwned(version: owned.version) } }
}
