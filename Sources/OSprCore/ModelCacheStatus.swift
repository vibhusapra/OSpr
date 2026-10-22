import Foundation

public struct ModelCacheStatus: Identifiable {
    public let id: String
    public let repo: String
    public let revision: String
    public let requiredBytes: Int64
    public let verifiedBytes: Int64
    public let complete: Bool
    public let path: String?

    public init?(_ row: [String: Any]) {
        guard let id = row["id"] as? String, let repo = row["repo"] as? String,
              let revision = row["revision"] as? String,
              let required = row["required_bytes"] as? NSNumber,
              let verified = row["verified_bytes"] as? NSNumber,
              let complete = row["complete"] as? Bool,
              required.int64Value > 0, verified.int64Value >= 0, verified.int64Value <= required.int64Value else { return nil }
        self.id = id; self.repo = repo; self.revision = revision
        self.requiredBytes = required.int64Value; self.verifiedBytes = verified.int64Value
        self.complete = complete; self.path = row["path"] as? String
    }
    public var sizeLabel: String { ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file) }
    public var cacheLabel: String {
        if complete { return "Downloaded · \(sizeLabel)" }
        if verifiedBytes > 0 { return "Incomplete · \(ByteCountFormatter.string(fromByteCount: verifiedBytes, countStyle: .file)) verified / \(sizeLabel)" }
        return "Download · \(sizeLabel)"
    }
}
