import AppKit
import OSprCore

enum AccessibilityOwner {
    static func matches(_ element: AXUIElement, pid: pid_t) -> Bool {
        var actual: pid_t = 0
        return AXUIElementGetPid(element, &actual) == .success && actual == pid
    }
}

struct ContextAXNode: Hashable {
    let element: AXUIElement
    static func == (a: Self, b: Self) -> Bool { CFEqual(a.element, b.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

struct ContextAXSource: ProfileDocumentSource {
    let pid: pid_t
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(80))
    var canRead: Bool { ContinuousClock.now < deadline }
    func isOwned(_ node: ContextAXNode) -> Bool { AccessibilityOwner.matches(node.element, pid: pid) }
    private func value(_ node: ContextAXNode, _ attribute: String) -> CFTypeRef? {
        guard canRead else { return nil }
        // This timeout is attached only to the queried element, not the system
        // wide AX object. The deadline also bounds ancestor admission.
        guard AXUIElementSetMessagingTimeout(node.element, 0.01) == .success else { return nil }
        // Return to the process default before this object can be used for an
        // insertion. A short metadata-read timeout must not affect later writes.
        defer { AXUIElementSetMessagingTimeout(node.element, 0) }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node.element, attribute as CFString, &value) == .success, canRead else { return nil }
        return value
    }
    func role(_ node: ContextAXNode) -> String? { value(node, kAXRoleAttribute) as? String }
    func parent(_ node: ContextAXNode) -> ContextAXNode? {
        guard let value = value(node, kAXParentAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return .init(element: unsafeBitCast(value, to: AXUIElement.self))
    }
    func url(_ node: ContextAXNode) -> String? {
        let raw = value(node, kAXURLAttribute)
        return (raw as? URL)?.absoluteString ?? raw as? String
    }
    func document(_ node: ContextAXNode) -> String? { value(node, kAXDocumentAttribute) as? String }
}

extension InsertionTarget {
    func profileDocument() -> String? {
        guard focusConsistent, !secure, let app, let element else { return nil }
        return ProfileDocumentReader.read(from: ContextAXNode(element: element), source: ContextAXSource(pid: app.processIdentifier))
    }
}
