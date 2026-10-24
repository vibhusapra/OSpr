import XCTest
@testable import OSprCore

final class NativeSpeechAssetTests: XCTestCase {
    private let expectedSHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    func testBoundedNativeAssetReaderRejectsSameSizeCorruptionTruncationAndExtraBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("model.mil")
        let entry = NativeSpeechAsset.Entry(path: "model.mil", size: 3, sha256: expectedSHA256)
        try Data("abc".utf8).write(to: file)
        XCTAssertNoThrow(try NativeSpeechAsset.verify(file, entry: entry))
        for bytes in ["abd", "ab", "abcd", ""] {
            try Data(bytes.utf8).write(to: file)
            XCTAssertThrowsError(try NativeSpeechAsset.verify(file, entry: entry))
        }
        try Data("abc".utf8).write(to: file)
        for size in [0, -1, 1_048_577] {
            XCTAssertThrowsError(try NativeSpeechAsset.verify(file, entry: .init(path: "model.mil", size: size, sha256: expectedSHA256)))
        }
    }
    func testNativeReaderSupportsReadOnlySharedBlobLinksAndRejectsUnknownModelDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blob = directory.appendingPathComponent("blob")
        try Data("abc".utf8).write(to: blob)
        let link = directory.appendingPathComponent("model.mil")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: blob)
        XCTAssertNoThrow(try NativeSpeechAsset.verify(link, entry: .init(path: "model.mil", size: 3, sha256: expectedSHA256)))
        XCTAssertEqual(try Data(contentsOf: blob), Data("abc".utf8))
        XCTAssertThrowsError(try NativeSpeechAsset.validate(directory))
    }
}
