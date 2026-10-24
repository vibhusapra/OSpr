import XCTest
@testable import OSprCore

private final class DocumentFixture: ProfileDocumentSource {
    var canRead = true
    var roles = [0: "AXTextArea", 1: "AXWebArea", 2: "AXGroup", 3: "AXWebArea", 4: "AXWindow"]
    var parents = [0: 1, 1: 2, 2: 3, 3: 4]
    var urls = [0: "https://link.invalid/", 1: "https://frame.invalid/", 3: "https://example.org/team?auth=secret#tab"]
    var documents = [4: "https://example.org/window"]
    var foreign = Set<Int>()
    var stopOnRole: Int?
    var urlReads: [Int] = [], documentReads: [Int] = []
    func isOwned(_ node: Int) -> Bool { !foreign.contains(node) }
    func role(_ node: Int) -> String? { if stopOnRole == node { canRead = false }; return roles[node] }
    func parent(_ node: Int) -> Int? { parents[node] }
    func url(_ node: Int) -> String? { urlReads.append(node); return urls[node] }
    func document(_ node: Int) -> String? { documentReads.append(node); return documents[node] }
}

final class ProfileDocumentReaderTests: XCTestCase {
    func testOuterWebAreaWinsWithoutReadingFrameOrLinkURLs() {
        let source = DocumentFixture(); source.roles[0] = "AXLink"
        XCTAssertEqual(ProfileDocumentReader.read(from: 0, source: source), source.urls[3])
        XCTAssertEqual(source.urlReads, [3]); XCTAssertTrue(source.documentReads.isEmpty)
    }

    func testUnavailableWebURLFallsBackToWindowDocument() {
        let source = DocumentFixture(); source.urls[3] = nil
        XCTAssertEqual(ProfileDocumentReader.read(from: 0, source: source), source.documents[4])
        XCTAssertEqual(source.urlReads, [3]); XCTAssertEqual(source.documentReads, [4])
    }

    func testWrongOwnerCycleAndIncompleteChainsReadNoURL() {
        for kind in 0..<3 {
            let source = DocumentFixture()
            if kind == 0 { source.foreign = [2] }
            else if kind == 1 { source.parents[2] = 0 }
            else { source.parents[3] = nil }
            XCTAssertNil(ProfileDocumentReader.read(from: 0, source: source))
            XCTAssertTrue(source.urlReads.isEmpty); XCTAssertTrue(source.documentReads.isEmpty)
        }
    }

    func testDepthAndReadAdmissionAreBounded() {
        let source = DocumentFixture()
        source.roles = Dictionary(uniqueKeysWithValues: (0...25).map { ($0, $0 == 25 ? "AXWindow" : "AXGroup") })
        source.parents = Dictionary(uniqueKeysWithValues: (0..<25).map { ($0, $0 + 1) })
        source.documents[25] = "https://example.org"
        XCTAssertNil(ProfileDocumentReader.read(from: 0, source: source)); XCTAssertTrue(source.documentReads.isEmpty)
        let stopped = DocumentFixture(); stopped.stopOnRole = 4
        XCTAssertNil(ProfileDocumentReader.read(from: 0, source: stopped))
        XCTAssertTrue(stopped.urlReads.isEmpty); XCTAssertTrue(stopped.documentReads.isEmpty)
    }

    func testURLFetchRequiresAnEnabledValidRuleForThisApp() {
        var settings = OSprSettings(), reads = 0
        func fetch() -> String? { reads += 1; return "https://example.org/team?secret=do-not-store" }
        XCTAssertNil(settings.profileDocument(for: "com.test.app", read: fetch)); XCTAssertEqual(reads, 0)
        settings.profiles = [.init(bundleID: "com.test.app", enabled: false, site: "https://example.org")]
        XCTAssertNil(settings.profileDocument(for: "com.test.app", read: fetch)); XCTAssertEqual(reads, 0)
        settings.profiles[0].enabled = true
        XCTAssertNil(settings.profileDocument(for: "com.test.other", read: fetch)); XCTAssertEqual(reads, 0)
        XCTAssertEqual(settings.profileDocument(for: "com.test.app", read: fetch)?.normalized, "https://example.org/team")
        XCTAssertEqual(reads, 1)
    }

    func testInvalidWebURLCannotSelectWindowRuleInstead() {
        var settings = OSprSettings()
        settings.profiles = [.init(bundleID: "com.test.app", mode: .code, site: "https://example.org")]
        let source = DocumentFixture(); source.urls[3] = "javascript:alert(1)"
        let document = settings.profileDocument(for: "com.test.app") { ProfileDocumentReader.read(from: 0, source: source) }
        XCTAssertNil(document); XCTAssertTrue(source.documentReads.isEmpty)
        XCTAssertEqual(settings.resolvedProfile(for: "com.test.app", document: document).mode, .clean)
    }
}
