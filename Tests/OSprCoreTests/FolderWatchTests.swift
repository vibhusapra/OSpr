import XCTest
@testable import OSprCore

final class FolderWatchTests: XCTestCase {
    func testStabilityChangesRetryBackoffAndRestartDeduplication() {
        let now = Date()
        var queue = FolderWatchQueue()
        let file = MediaCandidate(url: URL(fileURLWithPath: "/fixture/audio.wav"), bytes: 100, modified: now.addingTimeInterval(-10))
        XCTAssertTrue(queue.ready([file], now: now).isEmpty)
        XCTAssertEqual(queue.ready([file], now: now), [file])
        queue.finish(file, success: false, now: now)
        XCTAssertTrue(queue.ready([file], now: now.addingTimeInterval(30)).isEmpty)
        XCTAssertEqual(queue.ready([file], now: now.addingTimeInterval(61)), [file])
        queue.finish(file, success: true, now: now)
        var restarted = FolderWatchQueue(completed: queue.completed)
        XCTAssertTrue(restarted.ready([file], now: now).isEmpty)
        XCTAssertTrue(restarted.ready([file], now: now).isEmpty)
        let changed = MediaCandidate(url: file.url, bytes: 200, modified: now)
        XCTAssertTrue(restarted.ready([changed], now: now).isEmpty)
        XCTAssertTrue(restarted.ready([changed], now: now.addingTimeInterval(1)).isEmpty)
        XCTAssertEqual(restarted.ready([changed], now: now.addingTimeInterval(3)), [changed])
    }
    func testScannerDoesNotTraverseDirectoriesHiddenFilesOrSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("audio.WAV"))
        try Data([1]).write(to: root.appendingPathComponent(".hidden.wav"))
        try Data([1]).write(to: root.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested.wav"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.wav"), withDestinationURL: root.appendingPathComponent("audio.WAV"))
        XCTAssertEqual(try MediaCandidate.scan(directory: root).map { $0.url.lastPathComponent }, ["audio.WAV"])
    }
}
