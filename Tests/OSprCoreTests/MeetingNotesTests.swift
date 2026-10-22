import XCTest
@testable import OSprCore

final class MeetingNotesTests: XCTestCase {
    func testExcerptsMustBeExactOriginalTextAndKeepSourceFingerprint() throws {
        let source = "Do not ship today. It costs $12.50. 次は東京です。"
        let notes = try MeetingNotes(source: source, excerpts: [.init(id: 0, text: "Do not ship today."), .init(id: 2, text: "次は東京です。")], model: "fixture")
        XCTAssertTrue(notes.matches(source))
        XCTAssertFalse(notes.matches(source + " Changed."))
        XCTAssertTrue(notes.markdown.contains("Do not ship today."))
        XCTAssertThrowsError(try MeetingNotes(source: source, excerpts: [.init(id: 0, text: "Ship today.")], model: "fixture"))
        XCTAssertThrowsError(try MeetingNotes(source: source, excerpts: [.init(id: 0, text: "Do not ship today."), .init(id: 0, text: "Do not ship today.")], model: "fixture"))
        let decoded = try JSONDecoder().decode(MeetingNotes.self, from: JSONEncoder().encode(notes))
        XCTAssertEqual(decoded.excerpts, notes.excerpts)
        XCTAssertTrue(decoded.matches(source))
    }
}
