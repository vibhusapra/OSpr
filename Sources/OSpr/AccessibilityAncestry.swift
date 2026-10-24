import ApplicationServices
import OSprCore

/// Select a transport before attempting a write. Some web renderers acknowledge
/// AXSelectedText setters without changing their editor; a later retry can duplicate.
@MainActor enum AccessibilityAncestry {
    static func isWebContent(_ element: AXUIElement) throws -> Bool {
        try isWebContent(element, same: { CFEqual($0, $1) }, role: { node in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &value) == .success,
                  let role = value as? String else { throw unreadable() }
            return role
        }, parent: { node in
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &value)
            if result == .noValue || result == .attributeUnsupported { return nil }
            guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { throw unreadable() }
            return unsafeBitCast(value, to: AXUIElement.self)
        })
    }

    static func isWebContent<Node>(_ element: Node, same: (Node, Node) -> Bool,
                                   role: (Node) throws -> String,
                                   parent: (Node) throws -> Node?) throws -> Bool {
        var current = element, visited: [Node] = []
        // The walk reads roles and parents only, never field/document contents.
        for _ in 0..<32 {
            try Task.checkCancellation()
            guard !visited.contains(where: { same($0, current) }) else { throw unreadable() }
            visited.append(current)
            let currentRole = try role(current)
            if currentRole == "AXWebArea" { return true }
            if currentRole == "AXWindow" || currentRole == "AXApplication" { return false }
            guard let next = try parent(current) else { return false }
            current = next
        }
        throw unreadable()
    }

    private static func unreadable() -> OSprError {
        .message("The destination could not be checked. Focus the intended field and try again.")
    }
}
