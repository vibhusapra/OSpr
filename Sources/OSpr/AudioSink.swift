import AVFoundation
import OSprCore

/// Bounded recording writer. The audio tap copies into preallocated slots;
/// filesystem writes happen on a separate serial queue. Overflow fails visibly.
final class AudioSink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.ospr.audio-writer", qos: .userInitiated)
    private let lock = NSLock()
    private var pool: [AVAudioPCMBuffer]
    private var file: AVAudioFile?
    private var failure: Error?
    init(url: URL, format: AVAudioFormat) throws {
        pool = try (0..<16).map { _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw OSprError.message("Could not allocate capture buffers.") }
            return buffer
        }
        file = try AVAudioFile(forWriting: url, settings: format.settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func enqueue(_ source: AVAudioPCMBuffer) {
        lock.lock()
        guard let destination = pool.popLast(), source.frameLength <= destination.frameCapacity else {
            failure = OSprError.message("Audio capture could not keep up with the device. Recording stopped to avoid silently losing speech.")
            lock.unlock(); return
        }
        lock.unlock()
        destination.frameLength = source.frameLength
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let output = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        for index in 0..<min(input.count, output.count) {
            if let from = input[index].mData, let to = output[index].mData {
                memcpy(to, from, Int(input[index].mDataByteSize))
            }
        }
        queue.async { [self] in
            do { try file?.write(from: destination) } catch { lock.lock(); failure = error; lock.unlock() }
            lock.lock(); pool.append(destination); lock.unlock()
        }
    }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return failure }
    func finish() throws {
        queue.sync { file = nil }
        if let error { throw error }
    }
}
