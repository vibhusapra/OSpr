import XCTest
@testable import OSprCore

final class AppInstanceLockTests: XCTestCase {
    private func directory() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OSpr-instance-test-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testSecondOwnerIsRejectedAndLockFileIsPrivate() throws {
        let root = directory(), owner = try AppInstanceLock(directory: root)
        try withExtendedLifetime(owner) {
            XCTAssertThrowsError(try AppInstanceLock(directory: root))
            let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(".instance.lock").path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
        }
    }
    func testReleaseAllowsAnotherOwnerWithoutDeletingTheLockFile() throws {
        let root = directory()
        do { let owner = try AppInstanceLock(directory: root); withExtendedLifetime(owner) {} }
        XCTAssertNoThrow(try AppInstanceLock(directory: root))
    }
    func testSymlinkLockEntryDoesNotModifyItsTarget() throws {
        let root = directory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".instance.lock"), withDestinationURL: target)
        XCTAssertThrowsError(try AppInstanceLock(directory: root))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
    }
    func testASeparateProcessCannotAcquireTheHeldStore() throws {
        let root = directory(), owner = try AppInstanceLock(directory: root)
        try withExtendedLifetime(owner) {
            let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            child.arguments = ["-c", "import fcntl,sys\nf=open(sys.argv[1],'a')\ntry:\n fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept BlockingIOError:\n sys.exit(73)\nsys.exit(0)", root.appendingPathComponent(".instance.lock").path]
            try child.run(); child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, 73)
        }
    }
}
