import XCTest
import AVFoundation
@testable import OSpr

final class AudioReviewTests: XCTestCase {
    @MainActor func testStoppedLoadCannotRestoreOldPlaybackState() async throws {
        let player = AudioReviewPlayer()
        let started = expectation(description: "load admitted")
        let pending = Task { @MainActor in
            started.fulfill()
            await player.load(URL(fileURLWithPath: "/nonexistent-ospr-review-" + UUID().uuidString + ".wav"))
        }
        await fulfillment(of: [started], timeout: 2)
        player.stop()
        await pending.value
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(player.ready); XCTAssertFalse(player.loading); XCTAssertFalse(player.playing)
        XCTAssertEqual(player.duration, 0); XCTAssertTrue(player.error.isEmpty)
    }
    @MainActor func testLocalAudioAssetLoadsDurationAndRejectsExternalReferences() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-review-" + UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        buffer.frameLength = 16000
        for index in 0..<16000 { buffer.floatChannelData?[0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 16000) * 0.1) }
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        try file?.write(from: buffer); file = nil
        let asset = try AudioReviewPlayer.localAsset(url)
        XCTAssertEqual(asset.referenceRestrictions, .forbidAll)
        let duration = try await asset.load(.duration).seconds
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let video = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(duration, 1, accuracy: 0.005); XCTAssertEqual(audio.count, 1); XCTAssertTrue(video.isEmpty)
        XCTAssertThrowsError(try AudioReviewPlayer.localAsset(URL(string: "https://example.com/audio.wav")!))
    }
}
