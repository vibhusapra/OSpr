import Foundation

/// Prepare inside a private directory on the destination volume, then publish.
/// Large audio copies use FileManager's file copy, without loading them into RAM.
public enum PrivateFileExport {
    public static func write(_ data: Data, to destination: URL) throws {
        try publish(to: destination) { try data.write(to: $0, options: .withoutOverwriting) }
    }

    public static func copy(_ source: URL, to destination: URL) throws {
        try publish(to: destination) { try FileManager.default.copyItem(at: source, to: $0) }
    }

    private static func publish(to destination: URL, prepare: (URL) throws -> Void) throws {
        guard destination.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".ospr-export-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let payload = staging.appendingPathComponent("payload")
        try prepare(payload)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: payload.path)
        if fm.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileWriteInvalidFileName) }
            _ = try fm.replaceItemAt(destination, withItemAt: payload, backupItemName: nil, options: .usingNewMetadataOnly)
        } else {
            try fm.moveItem(at: payload, to: destination)
        }
    }
}
