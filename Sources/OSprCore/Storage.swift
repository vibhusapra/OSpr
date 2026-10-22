import Foundation

public final class LocalStore {
    public let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    public init(directory: URL) throws {
        self.directory = directory
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    public func read<T: Decodable>(_ type: T.Type, name: String) throws -> T? {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(type, from: Data(contentsOf: url))
    }
    public func write<T: Encodable>(_ value: T, name: String) throws {
        let url = directory.appendingPathComponent(name)
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func retained(_ items: [Transcript], days: Int, now: Date = Date()) -> [Transcript] {
        pruning(items, days: days, now: now).items
    }
    public static func pruning(_ items: [Transcript], days: Int, now: Date = Date()) -> (items: [Transcript], expiredAudio: Set<String>) {
        guard days > 0 else { return (items, []) }
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        var expiredAudio = Set<String>()
        let kept = items.filter { record in
            if record.date >= cutoff { return true }
            if let file = record.audioFile { expiredAudio.insert(file) }
            return false
        }
        return (kept, expiredAudio)
    }
}
