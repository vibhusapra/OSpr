import XCTest
import AppKit
@testable import OSpr

final class ClipboardTests: XCTestCase {
    @MainActor func testOverlappingPastesRestoreTheOriginalRichClipboard() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("OSpr-test-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem(); item.setString("original", forType: .string); item.setString("<b>original</b>", forType: .html)
        board.clearContents(); board.writeObjects([item])
        let restorer = ClipboardRestorer(board: board, delay: .seconds(30))
        let first = restorer.replace(with: "first dictation", restore: true)
        let second = restorer.replace(with: "second dictation", restore: true)
        restorer.restoreIfStillOwned(version: first)
        XCTAssertEqual(board.string(forType: .string), "second dictation")
        restorer.restoreIfStillOwned(version: second)
        XCTAssertEqual(board.string(forType: .string), "original")
        XCTAssertEqual(board.string(forType: .html), "<b>original</b>")
    }
    @MainActor func testAUserCopyDuringTheDelayIsNeverOverwritten() {
        let board = NSPasteboard(name: NSPasteboard.Name("OSpr-test-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.clearContents(); board.setString("original", forType: .string)
        let restorer = ClipboardRestorer(board: board, delay: .seconds(30))
        let version = restorer.replace(with: "dictation", restore: true)
        board.clearContents(); board.setString("new user copy", forType: .string)
        restorer.restoreIfStillOwned(version: version)
        XCTAssertEqual(board.string(forType: .string), "new user copy")
    }
    @MainActor func testOptingOutLeavesTheTranscriptAndCancelsAnEarlierLease() {
        let board = NSPasteboard(name: NSPasteboard.Name("OSpr-test-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.clearContents(); board.setString("original", forType: .string)
        let restorer = ClipboardRestorer(board: board, delay: .seconds(30))
        let earlier = restorer.replace(with: "first", restore: true)
        restorer.replace(with: "keep this", restore: false)
        restorer.restoreIfStillOwned(version: earlier)
        XCTAssertEqual(board.string(forType: .string), "keep this")
    }
}
