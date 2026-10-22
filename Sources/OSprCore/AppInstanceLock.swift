import Foundation
import Darwin

/// Hold for the GUI model's lifetime. CLI file transcription uses no shared store.
public final class AppInstanceLock: Sendable {
    public enum Failure: LocalizedError {
        case alreadyRunning
        case unavailable(Int32)
        public var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "Another OSpr process is using the data folder. Quit the older copy before opening this build."
            case .unavailable(let code): return "OSpr could not lock its data folder (\(code))."
            }
        }
    }
    private let descriptor: Int32
    public init(directory: URL) throws {
        guard directory.isFileURL else { throw Failure.unavailable(EINVAL) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(".instance.lock")
        let fd = Darwin.open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw Failure.unavailable(errno) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), fchmod(fd, mode_t(0o600)) == 0 else {
            let code = errno; Darwin.close(fd); throw Failure.unavailable(code == 0 ? EINVAL : code)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno; Darwin.close(fd)
            if code == EWOULDBLOCK || code == EAGAIN { throw Failure.alreadyRunning }
            throw Failure.unavailable(code)
        }
        descriptor = fd
    }
    deinit { Darwin.close(descriptor) }
}
