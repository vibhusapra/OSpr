import XCTest
@testable import OSprCore

final class ModelCacheStatusTests: XCTestCase {
    func testCacheStatusRejectsImpossibleSizesAndShowsIncompleteCache() throws {
        var row: [String: Any] = ["id": "fixture", "repo": "owner/model", "revision": String(repeating: "a", count: 40), "required_bytes": 1000, "verified_bytes": 900, "complete": false]
        let partial = try XCTUnwrap(ModelCacheStatus(row))
        XCTAssertTrue(partial.cacheLabel.hasPrefix("Incomplete"))
        XCTAssertNil(partial.path)
        row["verified_bytes"] = 1001
        XCTAssertNil(ModelCacheStatus(row))
        row["verified_bytes"] = -1
        XCTAssertNil(ModelCacheStatus(row))
        row["verified_bytes"] = 1000; row["complete"] = true
        XCTAssertTrue(try XCTUnwrap(ModelCacheStatus(row)).cacheLabel.hasPrefix("Downloaded"))
    }
}
