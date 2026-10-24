import XCTest
@testable import OSpr

final class AccessibilityAncestryTests: XCTestCase {
    @MainActor func testWebAncestorChoosesPasteAndNativeTreeKeepsAccessibility() throws {
        for (roles, expected) in [(["AXTextArea", "AXGroup", "AXWebArea", "AXWindow"], true),
                                  (["AXTextArea", "AXScrollArea", "AXWindow", "AXApplication"], false)] {
            var read: [Int] = []
            XCTAssertEqual(try AccessibilityAncestry.isWebContent(0, same: ==, role: {
                read.append($0); return roles[$0]
            }, parent: { $0 + 1 < roles.count ? $0 + 1 : nil }), expected)
            XCTAssertEqual(read.count, 3)
        }
    }

    @MainActor func testUnreadableCyclicAndUnboundedTreesStopWithoutChoosingTransport() {
        enum Failure: Error { case unavailable }
        var rolesRead = 0
        XCTAssertThrowsError(try AccessibilityAncestry.isWebContent(0, same: ==,
            role: { _ in throw Failure.unavailable }, parent: { _ in nil }))
        XCTAssertThrowsError(try AccessibilityAncestry.isWebContent(0, same: ==,
            role: { _ in "AXTextArea" }, parent: { _ in throw Failure.unavailable }))
        XCTAssertThrowsError(try AccessibilityAncestry.isWebContent(0, same: ==,
            role: { _ in rolesRead += 1; return "AXGroup" }, parent: { _ in 0 }))
        XCTAssertEqual(rolesRead, 1)
        rolesRead = 0
        XCTAssertThrowsError(try AccessibilityAncestry.isWebContent(0, same: ==,
            role: { _ in rolesRead += 1; return "AXGroup" }, parent: { $0 + 1 }))
        XCTAssertEqual(rolesRead, 32)
    }
}
