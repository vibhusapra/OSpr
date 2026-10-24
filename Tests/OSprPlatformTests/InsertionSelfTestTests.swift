import XCTest
@testable import OSpr
@testable import OSprCore

private actor InsertionTestGate {
    private var pending: [CheckedContinuation<Void, Never>] = []
    var count: Int { pending.count }
    func wait() async { await withCheckedContinuation { pending.append($0) } }
    func release() { if !pending.isEmpty { pending.removeFirst().resume() } }
    func releaseAll() { let values = pending; pending.removeAll(); for value in values { value.resume() } }
}

final class InsertionSelfTestTests: XCTestCase {
    @MainActor func testPermissionFailureNeverCapturesOrSends() {
        var captured = false
        let test = InsertionSelfTest(permission: { false }, capture: { _ in
            captured = true; throw OSprError.message("Must not capture")
        })
        test.start(restoreClipboard: true, allowUnverified: false)
        test.confirm(); test.acknowledge(appeared: true)
        XCTAssertEqual(test.phase, .failed); XCTAssertTrue(test.requiresAccessibility)
        XCTAssertFalse(captured); XCTAssertNil(test.delivery)
        test.cancel(); XCTAssertFalse(test.isPresented)
    }
    @MainActor func testCapturesAtExpiryAndNeverSendsWithoutSeparateConfirmation() async throws {
        let gate = InsertionTestGate()
        var current = "first", sends = 0
        let test = InsertionSelfTest(wait: { await gate.wait() }, permission: { true }, capture: { _ in
            InsertionTestDestination(name: current, verified: true, replacesSelection: false, send: { text, restore, allow, _ in
                XCTAssertEqual(text, "OSpr is ready."); XCTAssertTrue(restore); XCTAssertFalse(allow)
                sends += 1; return .accessibility
            })
        })
        test.start(restoreClipboard: true, allowUnverified: false)
        XCTAssertEqual(test.remaining, 3); XCTAssertEqual(test.destinationName, "")
        test.confirm(); test.acknowledge(appeared: true); XCTAssertEqual(sends, 0)
        current = "chosen field"
        try await ready(test, gate: gate)
        XCTAssertEqual(test.destinationName, "chosen field"); XCTAssertEqual(sends, 0)
        test.acknowledge(appeared: true); XCTAssertEqual(test.phase, .ready)
        test.confirm(); test.confirm()
        try await settle { test.phase == .sent }
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(test.clipboardMessage, "Sent without using the clipboard.")
        XCTAssertNotEqual(test.phase, .confirmed)
        test.acknowledge(appeared: true); XCTAssertEqual(test.phase, .confirmed)
        test.cancel(); XCTAssertNil(test.delivery); XCTAssertEqual(test.destinationName, "")
    }
    @MainActor func testClipboardCompletionIsSeparateFromDeliveryAndHumanAcknowledgement() async throws {
        let gate = InsertionTestGate()
        var completion: ((ClipboardRestorer.Outcome) -> Void)?
        let test = InsertionSelfTest(wait: { await gate.wait() }, permission: { true }, capture: { allow in
            XCTAssertTrue(allow)
            return InsertionTestDestination(name: "Compatibility field", verified: false, replacesSelection: true, send: { _, restore, allow, callback in
                XCTAssertFalse(restore); XCTAssertTrue(allow); completion = callback; return .clipboard
            })
        })
        test.start(restoreClipboard: false, allowUnverified: true)
        try await ready(test, gate: gate)
        XCTAssertFalse(test.verified); XCTAssertTrue(test.replacesSelection)
        test.confirm(); try await settle { test.phase == .sent }
        XCTAssertNil(test.clipboardOutcome)
        completion?(.notRequested)
        XCTAssertEqual(test.clipboardMessage, "Clipboard restoration is off in your settings.")
        test.acknowledge(appeared: false)
        XCTAssertEqual(test.phase, .failed); XCTAssertNotNil(test.delivery)
    }
    @MainActor func testRevokedPermissionAndCaptureFailureCannotSend() async throws {
        let gate = InsertionTestGate()
        var allowed = true, sends = 0
        let test = InsertionSelfTest(wait: { await gate.wait() }, permission: { allowed }, capture: { _ in
            InsertionTestDestination(name: "Owned", verified: true, replacesSelection: false, send: { _, _, _, _ in
                sends += 1; return .accessibility
            })
        })
        test.start(restoreClipboard: true, allowUnverified: false)
        try await ready(test, gate: gate)
        allowed = false; test.confirm()
        XCTAssertEqual(test.phase, .failed); XCTAssertTrue(test.requiresAccessibility); XCTAssertEqual(sends, 0)
        test.cancel()
        let failed = InsertionSelfTest(wait: { await gate.wait() }, permission: { true }, capture: { _ in throw OSprError.message("Secure or unsupported field") })
        failed.start(restoreClipboard: true, allowUnverified: false)
        for _ in 0..<3 { try await settle { await gate.count == 1 }; await gate.release() }
        try await settle { failed.phase == .failed }
        failed.confirm(); XCTAssertNil(failed.delivery); XCTAssertEqual(failed.message, "Secure or unsupported field")
        failed.cancel()
    }
    @MainActor func testCancellationFencesNoncancellableCountdownAndReleasesTarget() async throws {
        final class Lease {}
        weak var capturedLease: Lease?
        let gate = InsertionTestGate()
        var captures = 0
        let test = InsertionSelfTest(wait: { await gate.wait() }, permission: { true }, capture: { _ in
            captures += 1
            let lease = Lease(); capturedLease = lease
            return InsertionTestDestination(name: "Field", verified: true, replacesSelection: false, send: { [lease] _, _, _, _ in
                _ = lease; return .accessibility
            })
        })
        test.start(restoreClipboard: true, allowUnverified: false)
        try await settle { await gate.count == 1 }; test.cancel(); await gate.release()
        try await Task.sleep(for: .milliseconds(5))
        XCTAssertEqual(test.phase, .idle); XCTAssertEqual(captures, 0)
        test.start(restoreClipboard: true, allowUnverified: false)
        try await ready(test, gate: gate)
        XCTAssertNotNil(capturedLease)
        test.cancel(); XCTAssertNil(capturedLease)
    }
    @MainActor func testReplacementFencesOldSendAndClipboardCallback() async throws {
        let clock = InsertionTestGate(), sending = InsertionTestGate()
        var completion: ((ClipboardRestorer.Outcome) -> Void)?
        var index = 0
        let test = InsertionSelfTest(wait: { await clock.wait() }, permission: { true }, capture: { _ in
            index += 1
            let value = index
            return InsertionTestDestination(name: "Field \(value)", verified: true, replacesSelection: false, send: { _, _, _, callback in
                completion = callback
                await sending.wait() // Deliberately ignores cancellation.
                return .clipboard
            })
        })
        test.start(restoreClipboard: true, allowUnverified: false)
        try await ready(test, gate: clock); test.confirm()
        try await settle { await sending.count == 1 }
        test.cancel(); test.start(restoreClipboard: true, allowUnverified: false)
        try await ready(test, gate: clock)
        completion?(.restored); await sending.release()
        try await Task.sleep(for: .milliseconds(5))
        XCTAssertEqual(test.phase, .ready); XCTAssertEqual(test.destinationName, "Field 2")
        XCTAssertNil(test.delivery); XCTAssertNil(test.clipboardOutcome)
        test.cancel()
    }
    @MainActor func testSendFailureNeverClaimsSuccessOrLeavesItsTarget() async throws {
        let gate = InsertionTestGate()
        let test = InsertionSelfTest(wait: { await gate.wait() }, permission: { true }, capture: { _ in
            InsertionTestDestination(name: "Moved", verified: true, replacesSelection: false, send: { _, _, _, _ in
                throw OSprError.message("Cursor moved")
            })
        })
        test.start(restoreClipboard: true, allowUnverified: false)
        try await ready(test, gate: gate); test.confirm()
        try await settle { test.phase == .failed }
        XCTAssertEqual(test.message, "Cursor moved"); XCTAssertNil(test.delivery)
        test.acknowledge(appeared: true); XCTAssertEqual(test.phase, .failed)
        test.cancel()
    }
    @MainActor func testAppRunsProbeWithoutEngineAndCancellationPreservesRecoveryFlag() async throws {
        let gate = InsertionTestGate()
        let probe = InsertionSelfTest(wait: { await gate.wait() }, permission: { true }, capture: { _ in
            InsertionTestDestination(name: "Owned test field", verified: true, replacesSelection: false, send: { _, _, _, _ in .accessibility })
        })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-insertion-model-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(directory: directory)
        var config = OSprSettings(); config.rootPath = directory.appendingPathComponent("missing-engine").path
        try store.write(config, name: "settings.json")
        let app = AppModel(instanceLock: try AppInstanceLock(directory: directory), directory: directory, enableServices: false, insertionTest: probe)
        try await settle { !app.busy }
        XCTAssertFalse(app.engineInstalled); XCTAssertFalse(app.ready)
        app.hasRecovery = true
        app.startInsertionTest(); XCTAssertTrue(app.busy); XCTAssertEqual(app.phase, "idle")
        try await ready(probe, gate: gate)
        app.start(); XCTAssertEqual(app.phase, "idle")
        probe.confirm(); try await settle { probe.phase == .sent }; probe.acknowledge(appeared: true)
        XCTAssertTrue(app.busy); XCTAssertNil(app.historyState.latest)
        app.cancel(); XCTAssertFalse(probe.isPresented); XCTAssertTrue(app.hasRecovery)
        app.hasRecovery = false
        app.phase = "warming"; app.startInsertionTest(); XCTAssertFalse(probe.isPresented)
        app.phase = "idle"; app.startInsertionTest()
        try await settle { await gate.count == 1 }
        try await app.prepareForTermination(); await gate.releaseAll()
        XCTAssertFalse(probe.isPresented); XCTAssertNil(app.historyState.latest)
    }
    @MainActor private func ready(_ test: InsertionSelfTest, gate: InsertionTestGate) async throws {
        for _ in 0..<3 { try await settle { await gate.count == 1 }; await gate.release() }
        try await settle { test.phase == .ready }
    }
    @MainActor private func settle(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw OSprError.message("Insertion fixture did not settle") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
