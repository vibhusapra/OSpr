import Foundation
import Darwin

/// Revalidate process start time before every signal, including escalation.
struct WorkerProcessIdentity: Equatable {
    let pid: pid_t
    let parent: pid_t
    let uid: uid_t
    let seconds: UInt64
    let microseconds: UInt64

    init?(_ pid: pid_t) {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        self.pid = pid; parent = pid_t(info.pbi_ppid); uid = info.pbi_uid
        seconds = info.pbi_start_tvsec; microseconds = info.pbi_start_tvusec
    }
    func stillMatches() -> Bool {
        guard let current = Self(pid) else { return false }
        // Reparenting is expected after an owner exits.
        return current.uid == uid && current.seconds == seconds && current.microseconds == microseconds
    }
    func signal(_ value: Int32) { if stillMatches() { kill(pid, value) } }
}

/// Only captures an already established worker group, never the owner's group.
/// Snapshot identities before TERM, then escalate those identities even if the
/// leader has exited. No delayed signal to a bare PID or process-group number.
struct OwnedWorkerGroup {
    let leader: WorkerProcessIdentity

    init?(_ pid: pid_t) {
        guard pid != getpid(), let identity = WorkerProcessIdentity(pid),
              identity.uid == getuid(), getpgid(pid) == pid else { return nil }
        leader = identity
    }
    func members() -> [WorkerProcessIdentity] {
        if let current = WorkerProcessIdentity(leader.pid),
           current.seconds != leader.seconds || current.microseconds != leader.microseconds || current.uid != leader.uid { return [] }
        var capacity = 64
        while capacity <= 65_536 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let returned = pids.withUnsafeMutableBytes { proc_listpgrppids(leader.pid, $0.baseAddress, Int32($0.count)) }
            guard returned > 0 else { return [] }
            // libproc returns a PID count here (unlike proc_listpids bytes).
            let count = Int(returned)
            if count >= capacity { capacity *= 2; continue }
            return pids.prefix(count).compactMap { pid in
                guard pid != getpid(), getpgid(pid) == leader.pid, let identity = WorkerProcessIdentity(pid),
                      identity.uid == leader.uid,
                      (identity.seconds, identity.microseconds) >= (leader.seconds, leader.microseconds) else { return nil }
                return identity
            }
        }
        return []
    }
    func terminate(completion: @escaping @Sendable () -> Void = {}) {
        var owned = members()
        // Enumeration failure must still stop the verified leader.
        if leader.stillMatches(), getpgid(leader.pid) == leader.pid, !owned.contains(where: { $0.pid == leader.pid }) {
            owned.append(leader)
        }
        let snapshot = owned
        snapshot.forEach { $0.signal(SIGTERM) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            // An identity that still belongs to this group anchors another
            // snapshot, including descendants created while TERM was handled.
            let anchored = snapshot.contains { $0.stillMatches() && getpgid($0.pid) == leader.pid }
            let remaining = anchored ? members() : snapshot
            remaining.forEach { $0.signal(SIGKILL) }
            completion()
        }
    }
}

private final class WorkerImage: NSObject {}

/// A separate, idle native process watches kernel exit events. This code never
/// loads models, receives transcript text, or depends on the Python GIL.
public enum WorkerGuardian {
    public static func executableURL() -> URL? {
        var candidates = [URL]()
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("ospr-worker-guardian"))
        }
        let image = Bundle(for: WorkerImage.self)
        if image.bundleURL.pathExtension == "xctest" {
            candidates.append(image.bundleURL.deletingLastPathComponent().appendingPathComponent("ospr-worker-guardian"))
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static func run(arguments: [String]) -> Never {
        guard arguments.count == 2, let ownerPID = pid_t(arguments[0]), let workerPID = pid_t(arguments[1]),
              ownerPID == getppid(), ownerPID != workerPID,
              let owner = WorkerProcessIdentity(ownerPID), owner.uid == getuid(),
              let group = OwnedWorkerGroup(workerPID), group.leader.parent == ownerPID else { exit(2) }
        let queue = DispatchQueue(label: "app.ospr.worker-lifetime")
        let ownerExit = DispatchSource.makeProcessSource(identifier: ownerPID, eventMask: .exit, queue: queue)
        let workerExit = DispatchSource.makeProcessSource(identifier: workerPID, eventMask: .exit, queue: queue)
        var stopping = false // Accessed only on queue.
        let stop = {
            guard !stopping else { return }
            stopping = true
            group.terminate { exit(0) }
        }
        var registered = 0 // Accessed only on queue.
        let ready = {
            registered += 1
            guard registered == 2, !stopping else { return }
            // READY is emitted only after both kernel observers are registered.
            guard owner.stillMatches(), group.leader.stillMatches(), getppid() == ownerPID else { stop(); return }
            do { try FileHandle.standardOutput.write(contentsOf: Data("READY\n".utf8)) }
            catch { stop(); return }
            try? FileHandle.standardOutput.close()
        }
        ownerExit.setEventHandler(handler: stop)
        workerExit.setEventHandler(handler: stop)
        ownerExit.setRegistrationHandler(handler: ready)
        workerExit.setRegistrationHandler(handler: ready)
        ownerExit.resume(); workerExit.resume()
        withExtendedLifetime((ownerExit, workerExit)) { dispatchMain() }
    }
}
