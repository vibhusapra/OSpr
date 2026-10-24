import XCTest
@testable import OSprCore

final class PreviewCadenceTests: XCTestCase {
    func testDecodeTimeDoesNotAccumulateBetweenTicks() {
        let start = ContinuousClock().now
        var cadence = PreviewCadence(interval: .milliseconds(320), startingAt: start)
        var now = start
        for tick in 1...100 {
            let deadline = cadence.nextDeadline(at: now)
            XCTAssertEqual(deadline, start.advanced(by: .milliseconds(tick * 320)))
            now = deadline.advanced(by: .milliseconds(120))
        }
    }

    func testOverrunAdmitsOneUpdateThenWaitsInsteadOfBursting() {
        let start = ContinuousClock().now
        var cadence = PreviewCadence(interval: .milliseconds(320), startingAt: start)
        XCTAssertEqual(cadence.nextDeadline(at: start), start.advanced(by: .milliseconds(320)))
        let late = start.advanced(by: .milliseconds(950))
        XCTAssertEqual(cadence.nextDeadline(at: late), late)
        XCTAssertEqual(cadence.nextDeadline(at: late.advanced(by: .milliseconds(10))),
                       late.advanced(by: .milliseconds(320)))
    }

    func testLongSuspensionDoesNotCreateARequestBacklog() {
        let start = ContinuousClock().now
        var cadence = PreviewCadence(interval: .milliseconds(320), startingAt: start)
        _ = cadence.nextDeadline(at: start)
        let resumed = start.advanced(by: .seconds(3600))
        XCTAssertEqual(cadence.nextDeadline(at: resumed), resumed)
        XCTAssertEqual(cadence.nextDeadline(at: resumed), resumed.advanced(by: .milliseconds(320)))
    }

    func testRollingPreviewUsesTheSameThreeSecondSchedule() {
        let start = ContinuousClock().now
        var cadence = PreviewCadence(interval: .seconds(3), startingAt: start)
        var now = start
        for tick in 1...10 {
            let deadline = cadence.nextDeadline(at: now)
            XCTAssertEqual(deadline, start.advanced(by: .seconds(tick * 3)))
            now = deadline.advanced(by: .milliseconds(900))
        }
    }

    func testLateWakeWithinTheIntervalKeepsTheNextTick() {
        let start = ContinuousClock().now
        var cadence = PreviewCadence(interval: .milliseconds(320), startingAt: start)
        _ = cadence.nextDeadline(at: start)
        XCTAssertEqual(cadence.nextDeadline(at: start.advanced(by: .milliseconds(580))),
                       start.advanced(by: .milliseconds(640)))
    }
}
