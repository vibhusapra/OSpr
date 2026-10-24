import AppKit
import XCTest
@testable import OSpr

final class AccessibilityOwnerTests: XCTestCase {
    func testAXElementProcessOwnershipDoesNotDependOnItsRoleOrTrust() {
        let pid = getpid()
        let element = AXUIElementCreateApplication(pid)
        XCTAssertTrue(AccessibilityOwner.matches(element, pid: pid))
        XCTAssertFalse(AccessibilityOwner.matches(element, pid: pid + 1))
        XCTAssertFalse(AccessibilityOwner.matches(AXUIElementCreateSystemWide(), pid: pid))
    }
}
