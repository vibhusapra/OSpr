import XCTest
@testable import OSprCore

final class FunctionShortcutTests: XCTestCase {
    func testHoldEmitsOnePressAndOneRelease() {
        var gesture = FunctionShortcutGesture()
        XCTAssertEqual(gesture.receive(.functionDown(eligible: true)), [.arm])
        XCTAssertEqual(gesture.receive(.delayElapsed), [.press])
        XCTAssertEqual(gesture.receive(.functionUp), [.cancelTimer, .release])
        XCTAssertFalse(gesture.active)
    }
    func testQuickTapSettlesInOrderWithoutALateTimerPress() {
        var gesture = FunctionShortcutGesture()
        _ = gesture.receive(.functionDown(eligible: true))
        XCTAssertEqual(gesture.receive(.functionUp), [.cancelTimer, .press, .release])
        XCTAssertEqual(gesture.receive(.delayElapsed), [])
        XCTAssertEqual(gesture.receive(.functionUp), [])
    }
    func testFnCombinationBeforeDelayNeverStartsCapture() {
        var gesture = FunctionShortcutGesture()
        _ = gesture.receive(.functionDown(eligible: true))
        XCTAssertEqual(gesture.receive(.otherKey), [.cancelTimer])
        XCTAssertEqual(gesture.receive(.delayElapsed), [])
        XCTAssertEqual(gesture.receive(.functionDown(eligible: true)), [])
        XCTAssertEqual(gesture.receive(.functionUp), [.cancelTimer])
        XCTAssertEqual(gesture.receive(.functionDown(eligible: true)), [.arm])
    }
    func testCombinationAfterPressCancelsOnceAndDoesNotEmitARelease() {
        var gesture = FunctionShortcutGesture()
        _ = gesture.receive(.functionDown(eligible: true)); _ = gesture.receive(.delayElapsed)
        XCTAssertEqual(gesture.receive(.otherKey), [.cancelTimer, .cancelRecording])
        XCTAssertEqual(gesture.receive(.otherKey), [])
        XCTAssertEqual(gesture.receive(.functionUp), [.cancelTimer])
    }
    func testFnPressedWithAnotherModifierIsBlockedUntilRelease() {
        var gesture = FunctionShortcutGesture()
        XCTAssertEqual(gesture.receive(.functionDown(eligible: false)), [.cancelTimer])
        XCTAssertEqual(gesture.receive(.delayElapsed), [])
        XCTAssertEqual(gesture.receive(.functionDown(eligible: true)), [])
        XCTAssertEqual(gesture.receive(.functionUp), [.cancelTimer])
    }
    func testLostReleaseOrPermissionResetCancelsOnce() {
        var gesture = FunctionShortcutGesture()
        _ = gesture.receive(.functionDown(eligible: true)); _ = gesture.receive(.delayElapsed)
        XCTAssertEqual(gesture.receive(.reset), [.cancelTimer, .cancelRecording])
        XCTAssertEqual(gesture.receive(.reset), [.cancelTimer])
        XCTAssertFalse(gesture.active)
    }
    func testRepeatedDownAndTimersDoNotToggleRecordingRepeatedly() {
        var gesture = FunctionShortcutGesture()
        _ = gesture.receive(.functionDown(eligible: true))
        XCTAssertEqual(gesture.receive(.functionDown(eligible: true)), [])
        _ = gesture.receive(.delayElapsed)
        XCTAssertEqual(gesture.receive(.delayElapsed), [])
        XCTAssertEqual(gesture.receive(.functionDown(eligible: true)), [])
        XCTAssertEqual(gesture.receive(.functionUp), [.cancelTimer, .release])
    }
    func testPendingGestureResetCannotBeginCaptureLater() {
        var gesture = FunctionShortcutGesture()
        _ = gesture.receive(.functionDown(eligible: true))
        XCTAssertEqual(gesture.receive(.reset), [.cancelTimer])
        XCTAssertEqual(gesture.receive(.delayElapsed), [])
        XCTAssertEqual(gesture.receive(.functionUp), [])
    }
    func testLegacyPreferencesKeepModifiedShortcutAndFnRoundTrips() throws {
        let legacy = try JSONDecoder().decode(OSprSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(legacy.hotkeyFnOnly)
        XCTAssertEqual(legacy.hotkeyCode, 49); XCTAssertEqual(legacy.hotkeyModifiers, 6144)
        var value = legacy; value.hotkeyFnOnly = true
        let decoded = try JSONDecoder().decode(OSprSettings.self, from: JSONEncoder().encode(value))
        XCTAssertTrue(decoded.hotkeyFnOnly)
        XCTAssertEqual(decoded.hotkeyCode, 49); XCTAssertEqual(decoded.hotkeyModifiers, 6144)
    }
    func testRandomEventSequencesNeverProduceDuplicatePressesOrUnpairedStops() {
        var gesture = FunctionShortcutGesture(), pressed = false, seed: UInt64 = 20261022
        let inputs: [FunctionShortcutGesture.Input] = [.functionDown(eligible: true), .functionDown(eligible: false), .functionUp, .otherKey, .delayElapsed, .reset]
        for _ in 0..<10_000 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            for effect in gesture.receive(inputs[Int(seed % UInt64(inputs.count))]) {
                switch effect {
                case .press: XCTAssertFalse(pressed); pressed = true
                case .release, .cancelRecording: XCTAssertTrue(pressed); pressed = false
                default: break
                }
            }
        }
    }
}
