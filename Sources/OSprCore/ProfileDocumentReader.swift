/// Narrow access to one focused field's ancestor chain. No descendants, titles,
/// address-bar values or page text are read. A complete same-process chain to a
/// window is required, so an embedded frame cannot masquerade as the outer page.
public protocol ProfileDocumentSource {
    associatedtype Node: Hashable
    var canRead: Bool { get }
    func isOwned(_ node: Node) -> Bool
    func role(_ node: Node) -> String?
    func parent(_ node: Node) -> Node?
    func url(_ node: Node) -> String?
    func document(_ node: Node) -> String?
}

public enum ProfileDocumentReader {
    public static func read<S: ProfileDocumentSource>(from start: S.Node, source: S) -> String? {
        var node = start, visited = Set<S.Node>(), webArea: S.Node?
        for _ in 0..<24 {
            guard source.canRead, source.isOwned(node), visited.insert(node).inserted,
                  let role = source.role(node) else { return nil }
            if role == "AXWebArea" { webArea = node }
            if role == "AXWindow" {
                if let webArea, source.canRead, let value = source.url(webArea) { return value }
                return source.canRead ? source.document(node) : nil
            }
            guard source.canRead, let next = source.parent(node) else { return nil }
            node = next
        }
        return nil
    }
}
