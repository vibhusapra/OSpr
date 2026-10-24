import Foundation
import OSprCore

/// Main-actor capture lifetime. A late preparation/timer/cleanup operation
/// cannot end a newer session after the user cancels and starts again.
struct CaptureSessionLease {
    private(set) var current: UUID?
    mutating func begin() throws -> UUID {
        guard current == nil else { throw OSprError.message("A microphone session is already starting or recording.") }
        let id = UUID(); current = id; return id
    }
    func matches(_ id: UUID) -> Bool { current == id }
    @discardableResult mutating func end(matching id: UUID? = nil) -> Bool {
        if let id, !matches(id) { return false }
        current = nil; return true
    }
}
