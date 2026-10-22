/// Fn-only gestures must not turn ordinary Fn combinations into dictation.
public struct FunctionShortcutGesture: Sendable {
    public enum Input: Sendable { case functionDown(eligible: Bool), functionUp, otherKey, delayElapsed, reset }
    public enum Effect: Equatable, Sendable { case arm, cancelTimer, press, release, cancelRecording }
    private enum Phase: Sendable { case idle, waiting, pressed, blocked }
    private var phase: Phase = .idle
    public var active: Bool { phase != .idle }
    public init() {}

    public mutating func receive(_ input: Input) -> [Effect] {
        switch input {
        case .functionDown(let eligible):
            if !eligible {
                let cancel = phase == .pressed
                phase = .blocked
                return cancel ? [.cancelTimer, .cancelRecording] : [.cancelTimer]
            }
            guard phase == .idle else { return [] }
            phase = .waiting
            return [.arm]
        case .delayElapsed:
            guard phase == .waiting else { return [] }
            phase = .pressed
            return [.press]
        case .otherKey:
            guard phase != .idle && phase != .blocked else { return [] }
            let cancel = phase == .pressed
            phase = .blocked
            return cancel ? [.cancelTimer, .cancelRecording] : [.cancelTimer]
        case .functionUp:
            let previous = phase
            phase = .idle
            switch previous {
            case .waiting: return [.cancelTimer, .press, .release]
            case .pressed: return [.cancelTimer, .release]
            case .blocked: return [.cancelTimer]
            case .idle: return []
            }
        case .reset:
            let cancel = phase == .pressed
            phase = .idle
            return cancel ? [.cancelTimer, .cancelRecording] : [.cancelTimer]
        }
    }
}
