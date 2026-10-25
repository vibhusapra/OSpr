import XCTest
@testable import OSprCore

final class FileImportBatchTests: XCTestCase {
    func testRetryPreservesCompletedResultsAndOriginalURLs() {
        let urls = ["same.wav", "bad.wav", "same.wav"].map { URL(fileURLWithPath: "/tmp/" + $0) }
        var batch = FileImportBatch(urls: urls)
        let ids = batch.items.map(\.id), transcript = UUID()
        batch.begin(ids[0]); batch.finish(ids[0], transcriptID: transcript, message: nil)
        batch.begin(ids[1]); batch.finish(ids[1], transcriptID: nil, message: "Bad audio")
        batch.cancelRemaining()
        XCTAssertEqual(batch.completedCount, 1); XCTAssertEqual(batch.retryCount, 2)
        batch.prepareRetry()
        XCTAssertEqual(batch.remaining.map(\.id), [ids[1], ids[2]])
        XCTAssertEqual(batch.items[0].transcriptID, transcript)
        XCTAssertEqual(batch.items.map(\.url), urls)
    }

    func testCancellationAfterTranscriptAdmissionNeverRetriesItsSuccess() {
        var batch = FileImportBatch(urls: [URL(fileURLWithPath: "/tmp/ready.wav"), URL(fileURLWithPath: "/tmp/wait.wav")])
        let id = batch.items[0].id, transcript = UUID()
        batch.begin(id); batch.noteTranscript(id, transcriptID: transcript)
        batch.cancelRemaining()
        batch.finish(id, transcriptID: nil, message: "Late worker failure")
        XCTAssertEqual(batch.items[0].state, .warning)
        XCTAssertEqual(batch.items[0].transcriptID, transcript)
        batch.prepareRetry()
        XCTAssertEqual(batch.remaining.count, 1)
        XCTAssertEqual(batch.items[0].state, .warning)
    }

    func testPendingBatchCannotBeResetOrCompletedOutOfOrder() {
        var batch = FileImportBatch(urls: [URL(fileURLWithPath: "/tmp/one.wav")])
        let id = batch.items[0].id
        batch.finish(id, transcriptID: UUID(), message: nil)
        XCTAssertEqual(batch.items[0].state, .queued)
        batch.begin(id); batch.prepareRetry()
        XCTAssertEqual(batch.items[0].state, .processing)
        batch.finish(id, transcriptID: UUID(), message: "History could not be saved")
        XCTAssertEqual(batch.items[0].state, .warning); XCTAssertEqual(batch.retryCount, 0)
    }
}
