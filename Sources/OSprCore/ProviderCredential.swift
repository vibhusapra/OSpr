import Foundation
import CryptoKit

public enum ProviderCredentialKind: String, Sendable { case transcription, rewrite }

/// Credentials belong to an origin and purpose. A changed endpoint must never
/// receive a key retained from the previously selected provider.
public struct ProviderCredentialScope: Equatable, Sendable {
    public let kind: ProviderCredentialKind
    public let origin: String
    public var account: String { kind.rawValue + "." + SHA256.hash(data: Data(origin.utf8)).map { String(format: "%02x", $0) }.joined() }
    public init?(kind: ProviderCredentialKind, base: String) {
        guard let url = try? ProviderClient.endpoint(base: base, path: ""), let scheme = url.scheme?.lowercased(),
              let hostname = url.host?.lowercased() else { return nil }
        let host = hostname.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65535).contains(port) else { return nil }
        self.kind = kind
        origin = scheme + "://" + (host.contains(":") ? "[\(host)]" : host) + ":\(port)"
    }
    public static func checkedKey(_ key: String, boundTo scope: ProviderCredentialScope?, kind: ProviderCredentialKind, base: String) throws -> String {
        if key.isEmpty { return "" }
        guard let expected = ProviderCredentialScope(kind: kind, base: base), scope == expected else {
            throw OSprError.message("This API key belongs to a different provider endpoint. Select or enter a key for the current endpoint in Settings.")
        }
        return key
    }
}
