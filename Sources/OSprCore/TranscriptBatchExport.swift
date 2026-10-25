import Darwin
import Foundation

/// Publish a complete private directory; never merge or replace a destination.
public enum TranscriptBatchExport {
    public struct Result: Sendable { public let directory: URL; public let count: Int }
    private struct Entry: Encodable { let id: UUID; let file: String; let source: String }

    static func write(to destination: URL, format: TranscriptFileFormat, query: String,
                      checkCancellation: @escaping () throws -> Void,
                      enumerate: (_ visit: (Transcript) throws -> Void) throws -> Void) throws -> Result {
        guard destination.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
        let fm = FileManager.default
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".ospr-export-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let payload = stage.appendingPathComponent("payload")
        try fm.createDirectory(at: payload, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let index = payload.appendingPathComponent("index.json")
        guard fm.createFile(atPath: index.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: index)
        defer { try? handle.close() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try handle.write(contentsOf: Data("{\"schema_version\":1,\"format\":\"\(format.rawValue)\",\"query\":".utf8))
        try handle.write(contentsOf: encoder.encode(query))
        try handle.write(contentsOf: Data(",\"records\":[".utf8))
        var count = 0
        try enumerate { record in
            try checkCancellation()
            let name = TranscriptExport.filename(record, format: format)
            try autoreleasepool {
                let file = payload.appendingPathComponent(name)
                try TranscriptExport.data(record, format: format).write(to: file, options: .withoutOverwriting)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                if count > 0 { try handle.write(contentsOf: Data(",".utf8)) }
                try handle.write(contentsOf: encoder.encode(Entry(id: record.id, file: name, source: record.sourceName)))
            }
            count += 1
        }
        try handle.write(contentsOf: Data("],\"count\":\(count),\"audio_included\":false}\n".utf8))
        try handle.synchronize(); try handle.close()
        try checkCancellation()
        // Exclusive rename also preserves a destination created during export.
        guard renameatx_np(AT_FDCWD, payload.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return Result(directory: destination, count: count)
    }
}
