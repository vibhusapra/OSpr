import XCTest
import Darwin
@testable import OSprCore

final class WorkerLifetimeTests: XCTestCase {
    private func decoderFixture() throws -> (Process, pid_t) {
        let child = Process(), pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-u", "-c", """
        import os, signal, subprocess, sys, time
        decoder = subprocess.Popen([sys.executable, '-u', '-c', "import os,signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);print(os.getpid(),flush=True);time.sleep(120)"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE)
        print(decoder.stdout.readline().decode().strip(), flush=True)
        time.sleep(120)
        """]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = pipe
        child.standardError = FileHandle.nullDevice
        try child.run()
        let data = pipe.fileHandleForReading.availableData
        let pid = try XCTUnwrap(pid_t(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        return (child, pid)
    }

    private func cleanup(_ child: Process, _ descendant: WorkerProcessIdentity?) {
        descendant?.signal(SIGKILL)
        if child.isRunning { child.terminate(); kill(child.processIdentifier, SIGKILL) }
    }

    func testGroupSnapshotIncludesLeaderAndDescendantThenEscalatesAfterLeaderExits() async throws {
        let (child, decoder) = try decoderFixture()
        let descendant = try XCTUnwrap(WorkerProcessIdentity(decoder))
        defer { cleanup(child, descendant) }
        let group = try XCTUnwrap(OwnedWorkerGroup(child.processIdentifier))
        let members = group.members().map(\.pid)
        XCTAssertTrue(members.contains(child.processIdentifier))
        XCTAssertTrue(members.contains(decoder))
        let finished = expectation(description: "Identity-checked escalation completed")
        group.terminate { finished.fulfill() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(child.isRunning)
        XCTAssertTrue(descendant.stillMatches(), "Fixture must exercise a child which outlives TERM and its leader")
        await fulfillment(of: [finished], timeout: 3)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(descendant.stillMatches())
    }

    func testGuardianCleansDescendantWhenWorkerExitsFirst() async throws {
        let (child, decoder) = try decoderFixture()
        let descendant = try XCTUnwrap(WorkerProcessIdentity(decoder))
        defer { cleanup(child, descendant) }
        let helper = Process(), pipe = Pipe()
        helper.executableURL = try XCTUnwrap(WorkerGuardian.executableURL())
        helper.arguments = [String(getpid()), String(child.processIdentifier)]
        helper.environment = [:]
        helper.standardInput = FileHandle.nullDevice; helper.standardOutput = pipe; helper.standardError = FileHandle.nullDevice
        try helper.run()
        defer { if helper.isRunning { helper.terminate() } }
        XCTAssertEqual(pipe.fileHandleForReading.availableData, Data("READY\n".utf8))
        kill(child.processIdentifier, SIGKILL)
        let until = Date().addingTimeInterval(3)
        while helper.isRunning && Date() < until { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(helper.isRunning)
        XCTAssertEqual(helper.terminationStatus, 0)
        XCTAssertFalse(descendant.stillMatches())
    }

    func testGuardianRejectsInvalidOrUnownedTargetsWithoutSignallingThem() throws {
        for arguments in [["invalid", "2"], ["0", "0"], [String(getpid()), String(getpid())], [String(getppid()), String(getpid())]] {
            let helper = Process()
            helper.executableURL = try XCTUnwrap(WorkerGuardian.executableURL())
            helper.arguments = arguments
            helper.standardInput = FileHandle.nullDevice; helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
            try helper.run(); helper.waitUntilExit()
            XCTAssertEqual(helper.terminationStatus, 2)
        }
        XCTAssertNotNil(WorkerProcessIdentity(getpid()))
        XCTAssertNil(OwnedWorkerGroup(1))
        XCTAssertNil(OwnedWorkerGroup(getpid()))
    }
}
