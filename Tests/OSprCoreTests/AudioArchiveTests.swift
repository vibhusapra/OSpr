import XCTest
@testable import OSprCore

final class AudioArchiveTests: XCTestCase {
    private func archive() throws -> AudioArchive {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-audio-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try AudioArchive(directory: directory)
    }
    private func prepared(_ archive: AudioArchive, size: Int) async throws -> URL {
        let url = try await archive.newStagingURL()
        try Data(repeating: 37, count: size).write(to: url)
        return url
    }
    func testPreparedAudioIsPrivateAndBoundToItsRecordID() async throws {
        let archive = try archive(), id = UUID()
        let staging = try await prepared(archive, size: 80)
        let copy = try await archive.adoptPrepared(staging, id: id, limitBytes: 100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        let resolved = try await archive.resolve(name: copy.name, id: id)
        XCTAssertEqual(resolved, copy.url)
        let wrongID = try await archive.resolve(name: copy.name, id: UUID())
        let traversal = try await archive.resolve(name: "../" + copy.name, id: id)
        XCTAssertNil(wrongID); XCTAssertNil(traversal)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: copy.url.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: archive.directory.path)[.posixPermissions] as? Int, 0o700)
        try await archive.finishLease(copy.name, keep: false)
        let gone = try await archive.resolve(name: copy.name, id: id)
        XCTAssertNil(gone)
    }
    func testQuotaEvictsOldestAndNeverDestroysActiveInputs() async throws {
        let archive = try archive()
        let a = try await archive.adoptPrepared(prepared(archive, size: 20), id: UUID(), limitBytes: 100)
        try await archive.finishLease(a.name, keep: true)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: a.url.path)
        let b = try await archive.adoptPrepared(prepared(archive, size: 30), id: UUID(), limitBytes: 100)
        try await archive.finishLease(b.name, keep: true)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: b.url.path)
        let c = try await archive.adoptPrepared(prepared(archive, size: 60), id: UUID(), limitBytes: 100)
        XCTAssertEqual(c.evicted, [a.name])
        let bytes = try await archive.bytesUsed()
        XCTAssertEqual(bytes, 90)
        do { _ = try await archive.trimToBudget(20); XCTFail("Active input must survive") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.url.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: c.url.path))
        let oversized = try await prepared(archive, size: 50)
        do { _ = try await archive.adoptPrepared(oversized, id: UUID(), limitBytes: 100); XCTFail("Active lease cannot fit") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.url.path))
        try await archive.finishLease(c.name, keep: true)
        let removed = try await archive.trimToBudget(20)
        XCTAssertEqual(removed, [b.name, c.name])
    }
    func testRestartPrunesOrphansAndOwnedStagingButKeepsReferencedAudio() async throws {
        let archive = try archive()
        let a = try await archive.adoptPrepared(prepared(archive, size: 20), id: UUID(), limitBytes: 100)
        let b = try await archive.adoptPrepared(prepared(archive, size: 20), id: UUID(), limitBytes: 100)
        let staging = try await prepared(archive, size: 10)
        let unrelated = archive.directory.appendingPathComponent("not-ospr.txt")
        try Data("preserve".utf8).write(to: unrelated)
        let restarted = try AudioArchive(directory: archive.directory)
        let removed = try await restarted.reconcile(keeping: [a.name], limitBytes: 100)
        XCTAssertEqual(removed, [b.name])
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.url.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        try await restarted.eraseAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.url.path))
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "preserve")
    }
    func testStagingCannotEscapeArchiveOrFollowSymlinks() async throws {
        let archive = try archive()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside".utf8).write(to: outside)
        do { _ = try await archive.adoptPrepared(outside, id: UUID(), limitBytes: 100); XCTFail("Reject outside path") } catch {}
        do { try await archive.discardStaging(outside); XCTFail("Reject outside deletion") } catch {}
        let staging = try await archive.newStagingURL()
        try FileManager.default.createSymbolicLink(at: staging, withDestinationURL: outside)
        do { _ = try await archive.adoptPrepared(staging, id: UUID(), limitBytes: 100); XCTFail("Reject symlink") } catch {}
        try await archive.discardStaging(staging)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside")
        let id = UUID()
        let name = id.uuidString.lowercased() + ".wav"
        let linked = archive.directory.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        let resolved = try await archive.resolve(name: name, id: id)
        XCTAssertNil(resolved)
    }
    func testDuplicateIDCannotReplaceExistingAudio() async throws {
        let archive = try archive(), id = UUID()
        let existing = try await archive.adoptPrepared(prepared(archive, size: 20), id: id, limitBytes: 100)
        try await archive.finishLease(existing.name, keep: true)
        let duplicate = try await prepared(archive, size: 30)
        do { _ = try await archive.adoptPrepared(duplicate, id: id, limitBytes: 100); XCTFail("Reject duplicate ID") } catch {}
        XCTAssertEqual(try Data(contentsOf: existing.url).count, 20)
        XCTAssertTrue(FileManager.default.fileExists(atPath: duplicate.path))
    }
    func testUnavailableOptionalArchivePreservesTheObstructingFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-audio-blocked-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("preserve this file".utf8).write(to: directory)
        let archive = try AudioArchive(directory: directory)
        do { _ = try await archive.newStagingURL(); XCTFail("A regular file is not an archive directory") } catch {}
        XCTAssertEqual(try String(contentsOf: directory, encoding: .utf8), "preserve this file")
    }
    func testCompressedUploadSnapshotKeepsOriginalFormatAndIsNotRetainedHistory() async throws {
        let archive = try archive()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("original compressed bytes".utf8).write(to: source)
        let copied = try await archive.snapshotUploadSource(source, limitBytes: 100)
        let snapshot = try XCTUnwrap(copied)
        XCTAssertEqual(snapshot.pathExtension, "m4a")
        try Data("changed source".utf8).write(to: source)
        XCTAssertEqual(try String(contentsOf: snapshot, encoding: .utf8), "original compressed bytes")
        let bytes = try await archive.bytesUsed()
        XCTAssertEqual(bytes, 0) // Private upload copy is temporary, not retained audio.
        try await archive.discardUploadSource(snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
        let oversized = try await archive.snapshotUploadSource(source, limitBytes: 1)
        XCTAssertNil(oversized)
    }
    func testLegacyHistoryAndAudioSettingsRemainOptIn() throws {
        let original = Transcript(rawText: "original", text: "edited", model: "fixture", mode: .clean, duration: 1, latencyMS: 1)
        let data = try JSONEncoder().encode(original)
        XCTAssertNil(try JSONDecoder().decode(Transcript.self, from: data).audioFile)
        let settings = try JSONDecoder().decode(OSprSettings.self, from: Data(#"{"saveHistory":true}"#.utf8))
        XCTAssertFalse(settings.keepAudio); XCTAssertEqual(settings.audioBudgetMB, 1024)
        var invalid = settings; invalid.audioBudgetMB = -1
        XCTAssertEqual(invalid.validated().audioBudgetMB, 64)
        invalid.audioBudgetMB = Int.max
        XCTAssertEqual(invalid.validated().audioBudgetMB, 8192)
    }
    func testTimelineRejectsInvalidPositions() {
        XCTAssertEqual(AudioTimeline.clamp(.nan, duration: 10), 0)
        XCTAssertEqual(AudioTimeline.clamp(100, duration: 10), 10)
        XCTAssertEqual(AudioTimeline.clamp(-2, duration: 10), 0)
        XCTAssertEqual(AudioTimeline.label(.infinity), "0:00")
        XCTAssertEqual(AudioTimeline.label(3661), "1:01:01")
    }
    func testRetentionCollectsOnlyExpiredAudioReferences() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var old = Transcript(rawText: "old", text: "old", model: "fixture", mode: .verbatim, duration: 1, latencyMS: 1)
        old.date = now.addingTimeInterval(-86401); old.audioFile = old.id.uuidString + ".wav"
        var boundary = old; boundary.id = UUID(); boundary.date = now.addingTimeInterval(-86400); boundary.audioFile = boundary.id.uuidString + ".wav"
        let result = LocalStore.pruning([old, boundary], days: 1, now: now)
        XCTAssertEqual(result.items.map(\.id), [boundary.id])
        XCTAssertEqual(result.expiredAudio, [old.audioFile!])
        XCTAssertTrue(LocalStore.pruning([old, boundary], days: 0, now: now).expiredAudio.isEmpty)
    }
    func testReprocessingCopySurvivesDeletionOfTheOriginalHistoryAudio() async throws {
        let archive = try archive(), id = UUID()
        let audio = try await archive.adoptPrepared(prepared(archive, size: 64), id: id, limitBytes: 100)
        try await archive.finishLease(audio.name, keep: true)
        let copy = try await archive.copyForReprocessing(name: audio.name, id: id)
        try await archive.remove([audio.name])
        XCTAssertEqual(try Data(contentsOf: copy).count, 64)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.url.path))
        try await archive.discardStaging(copy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }
    func testLiveTemporaryCopiesSurvivePreferencesReconciliation() async throws {
        let archive = try archive(), id = UUID()
        let audio = try await archive.adoptPrepared(prepared(archive, size: 20), id: id, limitBytes: 100)
        try await archive.finishLease(audio.name, keep: true)
        let staging = try await prepared(archive, size: 10)
        let replay = try await archive.copyForReprocessing(name: audio.name, id: id)
        let original = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: original) }
        let bytes = Data("public compressed fixture".utf8); try bytes.write(to: original)
        let copied = try await archive.snapshotUploadSource(original, limitBytes: 100)
        let upload = try XCTUnwrap(copied)
        _ = try await archive.reconcile(keeping: [audio.name], limitBytes: 100)
        XCTAssertEqual(try Data(contentsOf: staging).count, 10)
        XCTAssertEqual(try Data(contentsOf: replay).count, 20)
        XCTAssertEqual(try Data(contentsOf: upload), bytes)
        try await archive.discardStaging(staging); try await archive.discardStaging(replay)
        try await archive.discardUploadSource(upload)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: archive.directory.path)), [audio.name])
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }

    func testRestartPrunesTemporaryLeasesInsteadOfRestoringThem() async throws {
        let archive = try archive(), id = UUID()
        let audio = try await archive.adoptPrepared(prepared(archive, size: 20), id: id, limitBytes: 100)
        try await archive.finishLease(audio.name, keep: true)
        let staging = try await prepared(archive, size: 10)
        let replay = try await archive.copyForReprocessing(name: audio.name, id: id)
        let original = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: original) }
        try Data("public compressed fixture".utf8).write(to: original)
        let copied = try await archive.snapshotUploadSource(original, limitBytes: 100)
        let upload = try XCTUnwrap(copied)
        let restarted = try AudioArchive(directory: archive.directory)
        _ = try await restarted.reconcile(keeping: [audio.name], limitBytes: 100)
        for url in [staging, replay, upload] { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: archive.directory.path)), [audio.name])
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testExplicitEraseRemovesActiveTemporaryCopiesAndKeepsUnrelatedFiles() async throws {
        let archive = try archive(), staging = try await prepared(archive, size: 10)
        let original = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: original) }
        try Data("public compressed fixture".utf8).write(to: original)
        let copied = try await archive.snapshotUploadSource(original, limitBytes: 100)
        let upload = try XCTUnwrap(copied)
        let unrelated = archive.directory.appendingPathComponent("keep.txt")
        try Data("preserve".utf8).write(to: unrelated)
        try await archive.eraseAll()
        for url in [staging, upload] { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("preserve".utf8))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: archive.directory.path)), ["keep.txt"])
    }

    func testDirectoryURLHintCannotRejectOwnedStagingOrUploadCleanup() async throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = package.appendingPathComponent(".build/audio-url-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = URL(fileURLWithPath: root.appendingPathComponent("Audio").path, isDirectory: false)
        let archive = try AudioArchive(directory: directory)
        let staging = try await prepared(archive, size: 20)
        let audio = try await archive.adoptPrepared(staging, id: UUID(), limitBytes: 100)
        try await archive.finishLease(audio.name, keep: true)
        let source = root.appendingPathComponent("source.m4a")
        try Data("public compressed bytes".utf8).write(to: source)
        let value = try await archive.snapshotUploadSource(source, limitBytes: 100)
        let snapshot = try XCTUnwrap(value)
        try await archive.discardUploadSource(snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
        XCTAssertEqual(try Data(contentsOf: source), Data("public compressed bytes".utf8))
        XCTAssertEqual(try Data(contentsOf: audio.url).count, 20)
    }

    func testDirectoryHintHandlingStillRejectsASymbolicArchiveRoot() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-audio-link-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let outside = parent.appendingPathComponent("outside"), link = parent.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let original = outside.appendingPathComponent("keep.txt"); try Data("preserve".utf8).write(to: original)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let archive = try AudioArchive(directory: link)
        do { _ = try await archive.newStagingURL(); XCTFail("A symbolic archive root must still be refused") } catch {}
        XCTAssertEqual(try Data(contentsOf: original), Data("preserve".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["keep.txt"])
    }

}
