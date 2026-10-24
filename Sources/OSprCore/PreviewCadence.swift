/// A monotonic preview schedule. Work that fits between ticks does not move
/// the next tick; an overrun admits one immediate update and starts a new
/// interval, rather than queuing requests for every missed tick.
public struct PreviewCadence: Sendable {
    private let interval: Duration
    private var next: ContinuousClock.Instant

    public init(interval: Duration, startingAt start: ContinuousClock.Instant) {
        precondition(interval > .zero)
        self.interval = interval
        next = start.advanced(by: interval)
    }

    public mutating func nextDeadline(at now: ContinuousClock.Instant) -> ContinuousClock.Instant {
        let deadline = max(next, now)
        next = deadline.advanced(by: interval)
        return deadline
    }
}
