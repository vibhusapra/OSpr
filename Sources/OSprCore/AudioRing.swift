import Foundation

/// Fixed-capacity audio tail. The caller owns synchronization; append copies at
/// most two spans and never reallocates or shifts the existing 12-second tail.
public struct AudioRing {
    private var storage: [Float]
    private var cursor = 0
    private var count = 0
    public init(capacity: Int) { storage = [Float](repeating: 0, count: max(1, capacity)) }
    public mutating func append(_ samples: UnsafeBufferPointer<Float>) {
        let length = min(samples.count, storage.count)
        guard length > 0, let base = samples.baseAddress else { return }
        let source = base.advanced(by: samples.count - length)
        let first = min(length, storage.count - cursor)
        storage.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.advanced(by: cursor).update(from: source, count: first)
            if first < length { buffer.baseAddress!.update(from: source.advanced(by: first), count: length - first) }
        }
        cursor = (cursor + length) % storage.count
        count = min(storage.count, count + length)
    }
    public func snapshot(last limit: Int? = nil) -> [Float] {
        let length = min(count, max(0, limit ?? count))
        guard length > 0 else { return [] }
        let start = (cursor - length + storage.count) % storage.count
        let first = min(length, storage.count - start)
        return Array(storage[start..<(start + first)]) + Array(storage[0..<(length - first)])
    }
}
