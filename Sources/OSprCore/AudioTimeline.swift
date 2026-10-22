import Foundation

public enum AudioTimeline {
    public static func clamp(_ seconds: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(duration, max(0, seconds.isFinite ? seconds : 0))
    }
    public static func label(_ seconds: Double) -> String {
        let bounded = seconds.isFinite ? min(359_999, max(0, seconds)) : 0
        let total = Int(bounded)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }
}
