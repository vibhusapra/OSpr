import Foundation

/// A mouse-start delay owns only a timer, never a focused field or microphone.
/// The caller captures the destination when completion is delivered.
@MainActor final class DictationCountdown {
    typealias Wait = @Sendable () async throws -> Void
    private let wait: Wait
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(wait: @escaping Wait = { try await Task.sleep(for: .seconds(1)) }) {
        self.wait = wait
    }

    func start(seconds: Int = 3, tick: @escaping (Int) -> Void, completion: @escaping () -> Void) {
        cancel()
        guard (1...10).contains(seconds) else { return }
        let token = generation, wait = wait
        tick(seconds)
        guard generation == token else { return }
        task = Task { [weak self] in
            for remaining in (0..<seconds).reversed() {
                do { try await wait() } catch { return }
                guard self?.generation == token, !Task.isCancelled else { return }
                tick(remaining)
            }
            guard self?.generation == token, !Task.isCancelled else { return }
            self?.task = nil
            completion()
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel(); task = nil
    }

    deinit { task?.cancel() }
}
