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
    @MainActor func testObserversDistinguishSupersessionAndVerifiedRichRestoration() {
        let board = NSPasteboard(name: NSPasteboard.Name("OSpr-test-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("original", forType: .string); item.setString("<b>original</b>", forType: .html)
        item.setData(Data([0, 1, 255]), forType: NSPasteboard.PasteboardType("app.ospr.test-binary"))
        board.clearContents(); board.writeObjects([item])
        let restorer = ClipboardRestorer(board: board, delay: .seconds(30))
        var first: [ClipboardRestorer.Outcome] = [], second: [ClipboardRestorer.Outcome] = []
        let old = restorer.replace(with: "first", restore: true, completion: { first.append($0) })
        let current = restorer.replace(with: "second", restore: true, completion: { second.append($0) })
        XCTAssertEqual(first, [.superseded]); XCTAssertTrue(second.isEmpty)
        restorer.restoreIfStillOwned(version: old); XCTAssertTrue(second.isEmpty)
        restorer.restoreIfStillOwned(version: current)
        XCTAssertEqual(second, [.restored]); XCTAssertEqual(board.string(forType: .html), "<b>original</b>")
        XCTAssertEqual(board.data(forType: NSPasteboard.PasteboardType("app.ospr.test-binary")), Data([0, 1, 255]))
        restorer.restorePending(); XCTAssertEqual(second, [.restored])
    }
    @MainActor func testObserverReportsNewUserCopyAndOptOutWithoutClaimingRestoration() {
        let board = NSPasteboard(name: NSPasteboard.Name("OSpr-test-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.clearContents(); board.setString("before", forType: .string)
        let restorer = ClipboardRestorer(board: board, delay: .seconds(30))
        var outcomes: [ClipboardRestorer.Outcome] = []
        let version = restorer.replace(with: "test", restore: true, completion: { outcomes.append($0) })
        board.clearContents(); board.setString("user copy", forType: .string)
        restorer.restoreIfStillOwned(version: version)
        XCTAssertEqual(outcomes, [.userChanged]); XCTAssertEqual(board.string(forType: .string), "user copy")
        restorer.replace(with: "keep", restore: false, completion: { outcomes.append($0) })
        XCTAssertEqual(outcomes, [.userChanged, .notRequested])
        restorer.restorePending(); XCTAssertEqual(board.string(forType: .string), "keep")
    }
    @MainActor func testRestorationCallbackMaySafelyStartAnotherLease() {
        let board = NSPasteboard(name: NSPasteboard.Name("OSpr-test-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.clearContents(); board.setString("original", forType: .string)
        let restorer = ClipboardRestorer(board: board, delay: .seconds(30))
        var next: Int?
        let version = restorer.replace(with: "first", restore: true, completion: { outcome in
            XCTAssertEqual(outcome, .restored)
            next = restorer.replace(with: "next", restore: true)
        })
        restorer.restoreIfStillOwned(version: version)
        XCTAssertEqual(board.string(forType: .string), "next")
        XCTAssertNotNil(next)
        if let next { restorer.restoreIfStillOwned(version: next) }
        XCTAssertEqual(board.string(forType: .string), "original")
    }
    @MainActor func testTimerNotifiesOnlyAfterItRestoresTheClipboard() async throws {
        let board = NSPasteboard(name: NSPasteboard.Name("OSpr-test-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.clearContents(); board.setString("original", forType: .string)
        let restorer = ClipboardRestorer(board: board, delay: .milliseconds(10))
        var observed: ClipboardRestorer.Outcome?
        restorer.replace(with: "test", restore: true, completion: { outcome in
            XCTAssertEqual(board.string(forType: .string), "original"); observed = outcome
        })
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while observed == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(observed, .restored)
    }
}
