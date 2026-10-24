import XCTest
@testable import OSprCore

final class ProviderCredentialTests: XCTestCase {
    func testOriginScopingCanonicalizesHostPortsAndKeepsSeparatePurposes() throws {
        let first = try XCTUnwrap(ProviderCredentialScope(kind: .transcription, base: "https://API.example.com/v1"))
        let same = try XCTUnwrap(ProviderCredentialScope(kind: .transcription, base: "https://api.example.com:443/openai/v1"))
        XCTAssertEqual(first, same)
        XCTAssertEqual(first.account, same.account)
        XCTAssertNotEqual(first, ProviderCredentialScope(kind: .rewrite, base: "https://api.example.com/v1"))
        XCTAssertNotEqual(first, ProviderCredentialScope(kind: .transcription, base: "https://api.example.com:8443/v1"))
        XCTAssertNotEqual(first, ProviderCredentialScope(kind: .transcription, base: "https://other.example.com/v1"))
        XCTAssertFalse(first.account.contains("example"))
    }
    func testStaleCredentialCannotBeSentAfterAnEndpointOrPurposeSwitch() throws {
        let prior = ProviderCredentialScope(kind: .transcription, base: "https://previous.example.com/v1")
        XCTAssertThrowsError(try ProviderCredentialScope.checkedKey("synthetic-old-key", boundTo: prior, kind: .transcription, base: "https://next.example.com/v1"))
        XCTAssertThrowsError(try ProviderCredentialScope.checkedKey("synthetic-old-key", boundTo: prior, kind: .rewrite, base: "https://previous.example.com/v1"))
        XCTAssertEqual(try ProviderCredentialScope.checkedKey("synthetic-old-key", boundTo: prior, kind: .transcription, base: "https://previous.example.com/compatible/v1"), "synthetic-old-key")
        XCTAssertEqual(try ProviderCredentialScope.checkedKey("", boundTo: nil, kind: .rewrite, base: "http://127.0.0.1:11434/v1"), "")
    }
    func testInsecureOrCredentialBearingBaseCannotAcquireAScope() {
        for base in ["http://remote.example.com/v1", "https://user:password@example.com/v1", "https://example.com/v1?api_key=secret", "/relative"] {
            XCTAssertNil(ProviderCredentialScope(kind: .transcription, base: base))
        }
    }
}
