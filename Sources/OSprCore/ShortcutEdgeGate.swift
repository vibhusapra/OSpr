/// Carbon can deliver repeated presses or queued edges from an older binding.
public struct ShortcutEdgeGate: Sendable {
    public enum Edge: Equatable, Sendable { case press, release }
    private var registration: UInt32?
    private var down = false
    public init() {}
    public mutating func activate(_ id: UInt32) { registration = id; down = false }
    public mutating func clear() { registration = nil; down = false }
    public mutating func receive(id: UInt32, pressed: Bool) -> Edge? {
        guard registration == id, down != pressed else { return nil }
        down = pressed
        return pressed ? .press : .release
    }
}
