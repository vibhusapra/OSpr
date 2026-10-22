import CryptoKit
import Foundation

/// Streams the legacy top-level JSON array one complete object at a time.
/// Structural scanning never interprets UTF-8 bytes inside strings; JSONDecoder
/// validates each resulting object. Delimiters, trailing bytes and EOF are strict.
final class HistoryJSONStream {
    private let file: FileHandle
    private var buffer = Data()
    private var offset = 0
    private var hash = SHA256()
    private var started = false
    private var ended = false
    private var first = true
    private(set) var sha256 = ""

    init(url: URL) throws { file = try FileHandle(forReadingFrom: url) }
    func close() { try? file.close() }
    deinit { close() }

    func next() throws -> Data? {
        guard !ended else { return nil }
        if !started {
            guard try significant() == 91 else { throw invalid() } // [
            started = true
        }
        var next = try significant()
        if !first {
            if next == 93 { return try finish() } // ]
            guard next == 44 else { throw invalid() } // ,
            next = try significant()
        } else if next == 93 { return try finish() }
        guard next == 123 else { throw invalid() } // {
        first = false
        var result = Data([123]), depth = 1, quoted = false, escaped = false
        while depth > 0 {
            guard let byte = try byte() else { throw invalid() }
            result.append(byte)
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 { depth += 1 }
            else if byte == 125 || byte == 93 { depth -= 1 }
        }
        return result
    }

    private func finish() throws -> Data? {
        guard try significant() == nil else { throw invalid() }
        ended = true
        sha256 = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return nil
    }
    private func significant() throws -> UInt8? {
        while let value = try byte() {
            if ![UInt8(32), 9, 10, 13].contains(value) { return value }
        }
        return nil
    }
    private func byte() throws -> UInt8? {
        if offset == buffer.count {
            buffer = try file.read(upToCount: 65536) ?? Data(); offset = 0
            if buffer.isEmpty { return nil }
            hash.update(data: buffer)
        }
        defer { offset += 1 }; return buffer[offset]
    }
    private func invalid() -> OSprError {
        OSprError.message("Saved history is unreadable. The original archive was preserved.")
    }
}
