import Darwin
import Foundation
import SQLite3
import XCTest
@testable import OSprCore

final class HistorySessionTests: XCTestCase {
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-session-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }
    private func record(_ text: String, audio: String? = nil) -> Transcript {
        var value = Transcript(rawText: text, text: text, model: "fixture", mode: .clean, duration: 1, latencyMS: 2,
            segments: [Segment(start: 0, end: 1, text: text, speaker: 2)],
            words: [Segment(start: 0.125, end: 0.875, text: text, speaker: 2, overlapSpeakers: [1, 2])])
        value.audioFile = audio
        value.notes = try! MeetingNotes(source: text, excerpts: [NoteExcerpt(id: 0, text: text)], model: "fixture")
        return value
    }
    private func canonical(_ record: Transcript) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(record)
    }
    private func sql(_ statement: String, path: URL) throws {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.appendingPathComponent(HistoryDatabase.fileName).path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, statement, nil, nil, nil), SQLITE_OK)
    }
    private func repository(_ path: URL, boundary: SessionBoundary) -> HistoryRepository {
        HistoryRepository(open: { try HistoryDatabase(directory: path) }, reset: { try HistoryDatabase.reset(directory: path) },
            hasPersistentData: { try HistoryDatabase.storageExists(directory: path) }, beforeTransition: { try boundary.check($0) })
    }

    func testPureMemoryStoreAndSnapshotPreserveAllDetailsAndSeparateTheirLifetimes() throws {
        let memory = try HistoryDatabase.inMemory()
        let item = record("Memory Ω C++ 日本語")
        try memory.upsert([item]); let copy = try memory.memoryCopy()
        XCTAssertEqual(try canonical(XCTUnwrap(copy.record(id: item.id))), try canonical(item))
        XCTAssertEqual(try copy.page(query: "C++").rows.map(\.id), [item.id])
        try memory.clear()
        XCTAssertEqual(try copy.statistics().records, 1)
        try copy.verifyIntegrity()
    }

    func testSnapshotHandlesNondefaultPageSizeAndDurableRoundTrip() throws {
        let sourcePath = try directory(), targetPath = try directory()
        try sql("PRAGMA page_size=8192", path: sourcePath)
        let source = try HistoryDatabase(directory: sourcePath), items = (0..<12).map { record("Round trip \($0)") }
        try source.upsert(items)
        let memory = try source.memoryCopy(), target = try HistoryDatabase(directory: targetPath)
        try memory.copyContents(to: target)
        XCTAssertEqual(try target.page().rows.map(\.id), items.reversed().map(\.id))
        for item in items { XCTAssertEqual(try canonical(XCTUnwrap(target.record(id: item.id))), try canonical(item)) }
        try target.verifyIntegrity()
    }

    func testFailedBackupLeavesTheDestinationAndSourceIntact() throws {
        let path = try directory(), source = try HistoryDatabase.inMemory(), target = try HistoryDatabase(directory: path)
        let original = record("Original target"), replacement = record("Replacement source")
        try source.upsert([replacement]); try target.upsert([original])
        var blocker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.appendingPathComponent(HistoryDatabase.fileName).path, &blocker), SQLITE_OK)
        defer { sqlite3_close(blocker) }
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try source.copyContents(to: target))
        XCTAssertEqual(sqlite3_exec(blocker, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try target.page().rows.map(\.id), [original.id])
        XCTAssertEqual(try source.page().rows.map(\.id), [replacement.id])
        try source.copyContents(to: target)
        XCTAssertEqual(try target.page().rows.map(\.id), [replacement.id])
        XCTAssertThrowsError(try source.copyContents(to: source))
    }

    func testDisablingSavingKeepsAllPagedRecordsAndPendingEditsButPurgesDiskAndAudioLinks() async throws {
        let path = try directory(), value = HistoryRepository(directory: path)
        let marker = "ZXQ_LIVE_SESSION_SENTINEL_5027648"
        var items = (0..<240).map { record("\(marker) record \($0)", audio: "\($0).wav") }
        for item in items { value.submit(item, delay: 60) }
        try await value.flushAsync()
        let occupiedBytes = try Data(contentsOf: path.appendingPathComponent(HistoryDatabase.fileName)).count
        value.updateText(id: items[0].id, text: "Pending edit", delay: 60)
        value.setSaving(false)
        var fresh = record("Fresh session only", audio: "never-retain.wav")
        value.submit(fresh, delay: 60); try await value.flushAsync()
        var cursor: Int64?, ids: [UUID] = []
        repeat {
            let page = try await value.page(before: cursor, limit: 37)
            ids += page.rows.map(\.id); cursor = page.next
        } while cursor != nil
        XCTAssertEqual(ids, [fresh.id] + items.reversed().map(\.id))
        items[0].text = "Pending edit"; items[0].audioFile = nil; fresh.audioFile = nil
        let edited = try await value.record(id: items[0].id), latest = try await value.record(id: fresh.id)
        XCTAssertEqual(try canonical(XCTUnwrap(edited)), try canonical(items[0]))
        XCTAssertEqual(try canonical(XCTUnwrap(latest)), try canonical(fresh))
        let audio = try await value.audioFiles()
        XCTAssertTrue(audio.isEmpty)
        let disk = try HistoryDatabase(directory: path)
        XCTAssertEqual(try disk.statistics(), HistoryStatistics(records: 0, words: 0))
        XCTAssertTrue(try disk.page(query: marker).rows.isEmpty)
        let bytes = try Data(contentsOf: path.appendingPathComponent(HistoryDatabase.fileName))
        XCTAssertNil(bytes.range(of: Data(marker.utf8)))
        XCTAssertNil(bytes.range(of: Data("Fresh session only".utf8)))
        XCTAssertLessThan(bytes.count, occupiedBytes / 2)
        try disk.verifyIntegrity()
    }

    func testFreshSessionOnlyStartupCreatesNoHistoryFileAndDoesNotShareSessionContent() async throws {
        let path = try directory(), value = HistoryRepository(directory: path, saveHistory: false)
        let item = record("Only this session")
        value.submit(item, delay: 60); try await value.flushAsync()
        value.updateText(id: item.id, text: "Session edit", delay: 60); try await value.flushAsync()
        let first = try await value.page()
        XCTAssertEqual(first.rows.map(\.id), [item.id])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: path.path).isEmpty)
        let nextSession = HistoryRepository(directory: path, saveHistory: false)
        let second = try await nextSession.page()
        XCTAssertTrue(second.rows.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: path.path).isEmpty)
    }

    func testSessionOnlyLaunchSnapshotsAndClearsLegacyJSON() async throws {
        let path = try directory(), items = (0..<8).map { record("Legacy session \($0)") }
        try LocalStore(directory: path).write(items, name: "history.json")
        let value = HistoryRepository(directory: path, saveHistory: false)
        let page = try await value.page()
        XCTAssertEqual(page.rows.map(\.id), items.map(\.id)) // Legacy array order.
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent("history.json").path))
        let disk = try HistoryDatabase(directory: path)
        XCTAssertEqual(try disk.statistics().records, 0)
        let detail = try await value.record(id: items[0].id)
        XCTAssertEqual(try canonical(XCTUnwrap(detail)), try canonical(items[0]))
    }

    func testReenablingSavingPersistsTheCompleteSessionAndAllDetailsAcrossRestart() async throws {
        let path = try directory(), value = HistoryRepository(directory: path, saveHistory: false)
        let items = (0..<250).map { record("Session record \($0)") }
        for item in items { value.submit(item, delay: 60) }
        try await value.flushAsync()
        value.updateText(id: items[0].id, text: "Edited while off", delay: 60)
        value.setSaving(true); try await value.flushAsync()
        let restarted = HistoryRepository(directory: path)
        let stats = try await restarted.statistics()
        XCTAssertEqual(stats.records, 250)
        let detail = try await restarted.record(id: items[0].id)
        XCTAssertEqual(detail?.text, "Edited while off")
        XCTAssertEqual(detail?.words, items[0].words)
        XCTAssertEqual(detail?.notes?.excerpts, items[0].notes?.excerpts)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: path.path).allSatisfy { !$0.hasSuffix("-journal") && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") })
        let permissions = try FileManager.default.attributesOfItem(atPath: path.appendingPathComponent(HistoryDatabase.fileName).path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testFailedSnapshotFreezesDiskWritesAndRetainsPendingContentForRetry() async throws {
        let path = try directory(), boundary = SessionBoundary(), value = repository(path, boundary: boundary)
        let original = record("Original saved"), fresh = record("Must not reach disk")
        value.submit(original, delay: 60); try await value.flushAsync()
        boundary.failure = .snapshotMemory
        let failed = expectation(description: "snapshot failure")
        value.setSaving(false) { result in if result.failure != nil { failed.fulfill() } }
        await fulfillment(of: [failed], timeout: 2)
        value.submit(fresh, delay: 60)
        do { try await value.flushAsync(); XCTFail("Expected snapshot failure") } catch {}
        let pending = try await value.record(id: fresh.id)
        XCTAssertEqual(pending?.text, fresh.text)
        let disk = try HistoryDatabase(directory: path)
        XCTAssertEqual(try disk.page().rows.map(\.id), [original.id])
        boundary.failure = nil; try await value.flushAsync()
        let page = try await value.page()
        XCTAssertEqual(page.rows.map(\.id), [fresh.id, original.id])
        XCTAssertEqual(try disk.statistics().records, 0)
    }

    func testFailedPurgeKeepsReadableSessionAndNeverWritesLaterContentToDisk() async throws {
        let path = try directory(), boundary = SessionBoundary(), value = repository(path, boundary: boundary)
        let original = record("Existing saved record", audio: "old.wav"), fresh = record("Later private session")
        value.submit(original, delay: 60); try await value.flushAsync()
        boundary.failure = .purgeDisk
        let failed = expectation(description: "purge failure")
        value.setSaving(false) { result in if result.failure != nil { failed.fulfill() } }
        await fulfillment(of: [failed], timeout: 2)
        value.submit(fresh, delay: 60)
        do { try await value.flushAsync(); XCTFail("Expected purge failure") } catch {}
        let page = try await value.page()
        XCTAssertEqual(page.rows.map(\.id), [fresh.id, original.id])
        let disk = try HistoryDatabase(directory: path)
        XCTAssertEqual(try disk.page().rows.map(\.id), [original.id])
        XCTAssertNil(try disk.record(id: fresh.id))
        boundary.failure = nil
        let removed = try await value.flushAsync()
        XCTAssertEqual(removed, ["old.wav"])
        XCTAssertEqual(try disk.statistics().records, 0)
    }

    func testFailedDurableTransferKeepsTheSessionAndDoesNotAcknowledgePersistence() async throws {
        let path = try directory(), boundary = SessionBoundary(), value = repository(path, boundary: boundary)
        value.setSaving(false); let first = record("First session")
        value.submit(first, delay: 60); try await value.flushAsync()
        boundary.failure = .persistSession
        let failed = expectation(description: "persist failure")
        value.setSaving(true) { result in if result.failure != nil { failed.fulfill() } }
        await fulfillment(of: [failed], timeout: 2)
        let latest = record("Latest unsaved session")
        value.submit(latest, delay: 60)
        do { try await value.flushAsync(); XCTFail("Expected durable transfer failure") } catch {}
        let page = try await value.page()
        XCTAssertEqual(page.rows.map(\.id), [latest.id, first.id])
        XCTAssertFalse(try HistoryDatabase.storageExists(directory: path))
        boundary.failure = nil; try await value.flushAsync()
        let disk = try HistoryDatabase(directory: path)
        XCTAssertEqual(try disk.page().rows.map(\.id), [latest.id, first.id])
    }

    func testUnparseableLegacyArchiveIsPreservedWhileSavingIsOffUntilExplicitClear() async throws {
        let path = try directory(), legacy = path.appendingPathComponent("history.json")
        let bytes = Data("Unreadable original".utf8); try bytes.write(to: legacy)
        let value = HistoryRepository(directory: path, saveHistory: false), fresh = record("Pending private text")
        value.submit(fresh, delay: 60)
        do { try await value.flushAsync(); XCTFail("Expected unreadable migration") } catch {}
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        value.clear(); value.submit(fresh, delay: 60); try await value.flushAsync()
        let page = try await value.page()
        XCTAssertEqual(page.rows.map(\.id), [fresh.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        let disk = try HistoryDatabase(directory: path)
        XCTAssertEqual(try disk.statistics().records, 0)
    }

    func testAudioCleanupReceiptsSurviveFailedPurgeAndLaterTextEdits() async throws {
        let path = try directory(), boundary = SessionBoundary(), value = repository(path, boundary: boundary)
        value.submit(record("Saved first"), delay: 60); try await value.flushAsync()
        boundary.failure = .purgeDisk
        value.setSaving(false)
        let item = record("New audio before privacy change", audio: "pending.wav")
        value.submit(item, delay: 60)
        do { try await value.flushAsync(); XCTFail("Expected purge failure") } catch {}
        value.updateText(id: item.id, text: "Edited after failed purge", delay: 60)
        do { try await value.flushAsync(); XCTFail("Expected purge failure") } catch {}
        boundary.failure = nil
        let removed = try await value.flushAsync()
        XCTAssertEqual(removed, ["pending.wav"])
        let detail = try await value.record(id: item.id)
        XCTAssertNil(detail?.audioFile)
        XCTAssertEqual(detail?.text, "Edited after failed purge")
    }

    func testAudioCleanupReceiptsSurviveFailedPersistenceAndProtectNewOwners() async throws {
        for reuse in [false, true] {
            let path = try directory(), boundary = SessionBoundary(), value = repository(path, boundary: boundary)
            value.setSaving(false); try await value.flushAsync()
            boundary.failure = .persistSession; value.setSaving(true)
            let original = record("Original audio owner", audio: "shared.wav")
            value.submit(original, delay: 60)
            do { try await value.flushAsync(); XCTFail("Expected persistence failure") } catch {}
            value.remove(ids: [original.id])
            do { try await value.flushAsync(); XCTFail("Expected persistence failure") } catch {}
            if reuse { value.submit(record("New owner", audio: "shared.wav"), delay: 60) }
            boundary.failure = nil
            let removed = try await value.flushAsync()
            XCTAssertEqual(removed, reuse ? [] : ["shared.wav"])
            let audio = try await value.audioFiles()
            XCTAssertEqual(audio, reuse ? ["shared.wav"] : [])
        }
    }

    func testSparseMemorySnapshotReclaimsFreePagesWithoutChangingItsSource() throws {
        let path = try directory(), destination = try directory(), source = try HistoryDatabase(directory: path)
        let sentence = String(repeating: "Storage snapshot C++ API Ω. ", count: 25)
        let items = (0..<1200).map { record("\($0) " + sentence) }
        try source.upsert(items)
        try source.remove(ids: Array(items.dropFirst()).map(\.id))
        let original = try Data(contentsOf: path.appendingPathComponent(HistoryDatabase.fileName))
        let memory = try source.memoryCopy(), disk = try HistoryDatabase(directory: destination)
        try memory.copyContents(to: disk)
        let compact = try Data(contentsOf: destination.appendingPathComponent(HistoryDatabase.fileName))
        XCTAssertLessThan(compact.count, original.count / 2)
        XCTAssertEqual(try Data(contentsOf: path.appendingPathComponent(HistoryDatabase.fileName)), original)
        XCTAssertEqual(try canonical(XCTUnwrap(memory.record(id: items[0].id))), try canonical(items[0]))
        try memory.verifyIntegrity()
    }

    func testSessionCompactionAndQueriesNeverOpenAFileThroughSQLiteVFS() throws {
        let probe = try MemoryVFSProbe()
        let memory = try HistoryDatabase(memoryPageSize: 4096, vfs: probe.name)
        defer { memory.close() }
        let sentence = String(repeating: "Private snapshot API Ω. ", count: 30)
        let items = (0..<1200).map { record("\($0) " + sentence) }
        try memory.upsert(items)
        XCTAssertEqual(try memory.page(query: "API").rows.count, 100)
        try memory.remove(ids: Array(items.dropFirst()).map(\.id))
        try memory.reclaimUnusedPages()
        try memory.verifyIntegrity()
        XCTAssertEqual(try canonical(XCTUnwrap(memory.record(id: items[0].id))), try canonical(items[0]))
        XCTAssertEqual(probe.openedFiles, [])
        // Positive control: the same probe must see an actual file open.
        let control = try directory().appendingPathComponent("positive-control.sqlite3")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(control.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, probe.name), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection, "CREATE TABLE control(value INTEGER)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(connection)
        XCTAssertTrue(probe.openedFiles.contains { $0.hasSuffix("/positive-control.sqlite3") })
        withExtendedLifetime(probe) {}
    }
    func testSummaryAndExtractiveNotesSurviveMemorySnapshotAndDurableTransfer() throws {
        let memory = try HistoryDatabase.inMemory()
        var item = record("Do not ship Friday.")
        item.summary = try MeetingSummary(source: item.rawText,
            items: [.init(section: .decisions, text: "Hold the Friday release.", sourceIDs: [0])],
            excerpts: [.init(id: 0, text: item.rawText)], model: "fixture", chunks: 1)
        try memory.upsert([item]); let snapshot = try memory.memoryCopy()
        try memory.clear()
        XCTAssertEqual(try canonical(XCTUnwrap(snapshot.record(id: item.id))), try canonical(item))
        let path = try directory()
        do { let disk = try HistoryDatabase(directory: path); try snapshot.copyContents(to: disk); try disk.verifyIntegrity() }
        let restarted = try HistoryDatabase(directory: path)
        XCTAssertEqual(try canonical(XCTUnwrap(restarted.record(id: item.id))), try canonical(item))
    }

}

/// A nondefault VFS forwards real opens to SQLite's original VFS, while recording
/// attempts. Other connections keep their normal VFS; this does not patch global
/// file IO or change production SQLite. Even a transient/unlinked file counts.
private final class MemoryVFSProbe {
    let name = "OSpr-memory-io-probe-" + UUID().uuidString
    private let wrapper: UnsafeMutablePointer<sqlite3_vfs>
    private let allocatedName: UnsafeMutablePointer<CChar>
    private static let registry = VFSProbeRegistry()
    var openedFiles: [String] { Self.registry.files(wrapper) }
    init() throws {
        guard let original = sqlite3_vfs_find(nil) else { throw OSprError.message("Missing test VFS") }
        wrapper = .allocate(capacity: 1); wrapper.initialize(to: original.pointee)
        allocatedName = strdup(name)!
        wrapper.pointee.zName = UnsafePointer(allocatedName); wrapper.pointee.pNext = nil
        Self.registry.add(wrapper, original: original)
        wrapper.pointee.xOpen = { vfs, filename, file, flags, output in
            guard let vfs, let original = MemoryVFSProbe.registry.open(vfs, filename: filename) else { return SQLITE_CANTOPEN }
            return original.pointee.xOpen!(original, filename, file, flags, output)
        }
        guard sqlite3_vfs_register(wrapper, 0) == SQLITE_OK else { throw OSprError.message("Cannot register test VFS") }
    }
    deinit {
        sqlite3_vfs_unregister(wrapper); Self.registry.remove(wrapper)
        wrapper.deinitialize(count: 1); wrapper.deallocate(); free(allocatedName)
    }
}

private final class VFSProbeRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UInt: (UnsafeMutablePointer<sqlite3_vfs>, [String])] = [:]
    func add(_ wrapper: UnsafeMutablePointer<sqlite3_vfs>, original: UnsafeMutablePointer<sqlite3_vfs>) {
        lock.lock(); defer { lock.unlock() }; entries[UInt(bitPattern: wrapper)] = (original, [])
    }
    func open(_ wrapper: UnsafeMutablePointer<sqlite3_vfs>, filename: UnsafePointer<CChar>?) -> UnsafeMutablePointer<sqlite3_vfs>? {
        lock.lock(); defer { lock.unlock() }; let key = UInt(bitPattern: wrapper)
        guard var entry = entries[key] else { return nil }
        entry.1.append(filename.map { String(cString: $0) } ?? "<unnamed temporary file>"); entries[key] = entry
        return entry.0
    }
    func files(_ wrapper: UnsafeMutablePointer<sqlite3_vfs>) -> [String] {
        lock.lock(); defer { lock.unlock() }; return entries[UInt(bitPattern: wrapper)]?.1 ?? []
    }
    func remove(_ wrapper: UnsafeMutablePointer<sqlite3_vfs>) {
        lock.lock(); defer { lock.unlock() }; entries.removeValue(forKey: UInt(bitPattern: wrapper))
    }
}

private final class SessionBoundary: @unchecked Sendable {
    private let lock = NSLock()
    private var value: HistoryRepository.Transition?
    var failure: HistoryRepository.Transition? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
    func check(_ transition: HistoryRepository.Transition) throws {
        lock.lock(); defer { lock.unlock() }
        if value == transition { throw OSprError.message("Simulated storage transition failure") }
    }
}
