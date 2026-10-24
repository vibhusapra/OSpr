import Foundation
import OSprCore

enum PreviewCadenceCheck {
    /// Deterministic request schedules under a fixed modeled work cost. This
    /// invokes the actual Core scheduler; it does not measure elapsed latency.
    static func run(intervalMS: Int, workMS: Int, stopMS: Int) throws -> [String: Any] {
        guard (1...10_000).contains(intervalMS), (0...10_000).contains(workMS),
              (1...600_000).contains(stopMS), stopMS / intervalMS <= 10_000 else {
            throw OSprError.message("Invalid preview schedule fixture bounds.")
        }
        let origin = ContinuousClock().now
        let end = origin.advanced(by: .milliseconds(stopMS))
        var schedules = [String: [Double]]()
        for policy in ["legacy", "deadline"] {
            var now = origin
            var cadence = PreviewCadence(interval: .milliseconds(intervalMS), startingAt: origin)
            var ticks = [Double]()
            while true {
                let next = policy == "legacy" ? now.advanced(by: .milliseconds(intervalMS)) : cadence.nextDeadline(at: now)
                guard next < end else { break }
                let parts = origin.duration(to: next).components
                ticks.append(Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15)
                now = next.advanced(by: .milliseconds(workMS))
            }
            schedules[policy] = ticks
        }
        return ["interval_ms": intervalMS, "work_ms": workMS, "stop_ms": stopMS, "schedules_ms": schedules,
                "boundary": "Actual Core scheduling with a synthetic monotonic clock progression and fixed processing cost. No sleeps, microphone, ASR, IPC, UI, latency or energy measurement."]
    }
}
