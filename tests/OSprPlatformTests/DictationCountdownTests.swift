import XCTest
@testable import OSpr

private actor CountdownWaitGate {
    private var pending: [CheckedContinuation<Void, Never>] = []
    var count: Int { pending.count }
    func wait() async { await withCheckedContinuation { pending.append($0) } }
    func release() { pending.removeFirst().resume() }
}

final class DictationCountdownTests: XCTestCase {
    @MainActor private func settle(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()) && ContinuousClock.now < deadline { await Task.yield() }
        let settled = await predicate()
        XCTAssertTrue(settled)
    }

    @MainActor func testFiresOnlyAfterAllTicksAndDoesNotChooseTheDestinationEarly() async throws {
        let gate = CountdownWaitGate(), countdown = DictationCountdown(wait: { await gate.wait() })
        var ticks: [Int] = [], destination = "old field", captured: String?
        countdown.start(tick: { ticks.append($0) }, completion: { captured = destination })
        XCTAssertEqual(ticks, [3]); XCTAssertNil(captured)
        for count in [2, 1] {
            try await settle { await gate.count == 1 }; await gate.release()
            try await settle { ticks.last == count }
            XCTAssertNil(captured)
        }
        destination = "new focused field"
        try await settle { await gate.count == 1 }; await gate.release()
        try await settle { captured != nil }
        XCTAssertEqual(ticks, [3, 2, 1, 0]); XCTAssertEqual(captured, destination)
        countdown.cancel(); XCTAssertEqual(captured, "new focused field")
    }

    @MainActor func testCancelAndReplacementFenceAWaitThatIgnoresCancellation() async throws {
        let gate = CountdownWaitGate(), countdown = DictationCountdown(wait: { await gate.wait() })
        var ticks: [Int] = [], oldFired = false, newFired = 0
        countdown.start(tick: { ticks.append($0) }, completion: { oldFired = true })
        try await settle { await gate.count == 1 }
        countdown.cancel()
        countdown.start(seconds: 2, tick: { ticks.append($0) }, completion: { newFired += 1 })
        try await settle { await gate.count == 2 }
        await gate.release() // Resume the canceled timer after its replacement exists.
        try await settle { await gate.count == 1 }
        XCTAssertFalse(oldFired); XCTAssertEqual(ticks, [3, 2])
        await gate.release(); try await settle { ticks.last == 1 }
        try await settle { await gate.count == 1 }; await gate.release()
        try await settle { newFired == 1 }
        XCTAssertFalse(oldFired); XCTAssertEqual(ticks, [3, 2, 1, 0])
    }

    @MainActor func testOwnerCanDisappearDuringWaitWithoutFiring() async throws {
        let gate = CountdownWaitGate()
        var countdown: DictationCountdown? = DictationCountdown(wait: { await gate.wait() })
        weak var owner = countdown
        var completed = false
        countdown?.start(tick: { _ in }, completion: { completed = true })
        try await settle { await gate.count == 1 }
        countdown = nil
        XCTAssertNil(owner)
        await gate.release()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(completed)
    }

    @MainActor func testInitialTickCanCancelOrReplaceWithoutAdmittingTheOldTimer() async throws {
        let gate = CountdownWaitGate(), countdown = DictationCountdown(wait: { await gate.wait() })
        var oldFired = false, newFired = false
        countdown.start(tick: { _ in
            countdown.start(seconds: 1, tick: { _ in }, completion: { newFired = true })
        }, completion: { oldFired = true })
        try await settle { await gate.count == 1 }; await gate.release()
        try await settle { newFired }
        XCTAssertFalse(oldFired)
    }
}
