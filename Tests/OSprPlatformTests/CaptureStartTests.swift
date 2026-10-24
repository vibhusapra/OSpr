import XCTest
import AppKit
import ApplicationServices
@testable import OSpr
@testable import OSprCore

final class CaptureStartTests: XCTestCase {
    @MainActor func testRuntimeDetectorWarningIsVisibleOnlyDuringTheActiveRecording() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-capture-warning-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppModel(instanceLock: try AppInstanceLock(directory: directory), directory: directory, enableServices: false)
        app.phase = "recording"; app.error = ""
        app.capture.autoFinishUnavailable?("Injected detector failure; stop manually")
        XCTAssertEqual(app.error, "Injected detector failure; stop manually")
        XCTAssertEqual(app.status, "Listening · stop manually")
        XCTAssertEqual(app.phase, "recording", "A warning must not terminate the take")
        app.phase = "idle"; app.error = ""; app.status = "Idle fixture"
        app.capture.autoFinishUnavailable?("Late warning")
        XCTAssertEqual(app.error, ""); XCTAssertEqual(app.status, "Idle fixture")
        try await app.prepareForTermination()
    }
    func testLatePreparationAndTimerCannotEndANewerCaptureLease() throws {
        var lease = CaptureSessionLease()
        let first = try lease.begin()
        XCTAssertThrowsError(try lease.begin())
        XCTAssertTrue(lease.end(matching: first))
        let next = try lease.begin()
        XCTAssertNotEqual(first, next)
        XCTAssertFalse(lease.matches(first))
        XCTAssertFalse(lease.end(matching: first))
        XCTAssertTrue(lease.matches(next))
        XCTAssertTrue(lease.end(matching: next))
        XCTAssertNil(lease.current)
    }
    @MainActor func testRecordingPreflightRejectsSecureUnknownOrInconsistentDestinations() throws {
        let good = InsertionTarget(app: .current, element: nil, selectedText: "", secure: false)
        XCTAssertNoThrow(try good.validateRecordingStart(currentSnapshot: good))
        var bad = good; bad.focusConsistent = false
        XCTAssertThrowsError(try good.validateRecordingStart(currentSnapshot: bad))
        let secure = InsertionTarget(app: .current, element: nil, selectedText: "", secure: true)
        XCTAssertThrowsError(try good.validateRecordingStart(currentSnapshot: secure))
        let unknown = InsertionTarget(app: nil, element: nil, selectedText: "", secure: false)
        XCTAssertThrowsError(try unknown.validateRecordingStart(currentSnapshot: unknown))
    }
    @MainActor func testRecordingPreflightRechecksFieldIdentityAndSelectedPassage() throws {
        let app = NSRunningApplication.current
        let element = AXUIElementCreateApplication(app.processIdentifier)
        let target = InsertionTarget(app: app, element: element, selectedText: "fixture", secure: false)
        let same = InsertionTarget(app: app, element: AXUIElementCreateApplication(app.processIdentifier), selectedText: "fixture", secure: false)
        XCTAssertNoThrow(try target.validateRecordingStart(currentSnapshot: same))
        let moved = InsertionTarget(app: app, element: AXUIElementCreateSystemWide(), selectedText: "fixture", secure: false)
        XCTAssertThrowsError(try target.validateRecordingStart(currentSnapshot: moved))
        let edited = InsertionTarget(app: app, element: element, selectedText: "changed", secure: false)
        XCTAssertThrowsError(try target.validateRecordingStart(currentSnapshot: edited))
    }
}
