import XCTest
@testable import OSprCore

final class ShortcutEdgeGateTests: XCTestCase {
    func testHeldKeyPressesDoNotToggleRepeatedly() {
        var gate = ShortcutEdgeGate(); gate.activate(1)
        XCTAssertEqual(gate.receive(id: 1, pressed: true), .press)
        for _ in 0..<20 { XCTAssertNil(gate.receive(id: 1, pressed: true)) }
        XCTAssertEqual(gate.receive(id: 1, pressed: false), .release)
        XCTAssertNil(gate.receive(id: 1, pressed: false))
    }
    func testRebindingRejectsQueuedOldReleaseDuringANewCapture() {
        var gate = ShortcutEdgeGate(); gate.activate(1)
        _ = gate.receive(id: 1, pressed: true)
        gate.activate(2)
        XCTAssertEqual(gate.receive(id: 2, pressed: true), .press)
        XCTAssertNil(gate.receive(id: 1, pressed: false))
        XCTAssertEqual(gate.receive(id: 2, pressed: false), .release)
    }
    func testUnpairedReleaseAndOtherRegistrationsAreIgnored() {
        var gate = ShortcutEdgeGate(); gate.activate(3)
        XCTAssertNil(gate.receive(id: 3, pressed: false))
        XCTAssertNil(gate.receive(id: 4, pressed: true))
        XCTAssertEqual(gate.receive(id: 3, pressed: true), .press)
    }
    func testSwitchingAwayInvalidatesBothPendingEdges() {
        var gate = ShortcutEdgeGate(); gate.activate(1)
        _ = gate.receive(id: 1, pressed: true); gate.clear()
        XCTAssertNil(gate.receive(id: 1, pressed: false))
        XCTAssertNil(gate.receive(id: 1, pressed: true))
    }
}
