import AVFoundation
import OSprCore

/// Bounded recording writer. The audio tap copies into preallocated slots;
/// filesystem writes happen on a separate serial queue. Overflow fails visibly.
final class AudioSink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.ospr.audio-writer", qos: .userInitiated)
    private let lock = NSLock()
    private let format: AVAudioFormat
    private var pool: [AVAudioPCMBuffer]
    private var file: PCMFileWriter?
    private var failure: Error?
    private var accepting = true
    init(url: URL, format: AVAudioFormat) throws {
        self.format = format
        pool = try (0..<16).map { _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw OSprError.message("Could not allocate capture buffers.") }
            return buffer
        }
        file = try PCMFileWriter(url: url, format: format)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func enqueue(_ source: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard accepting else {
            failure = OSprError.message("Audio arrived after the writer finished.")
            return
        }
        guard source.format.isEqual(format) else {
            failure = OSprError.message("Capture audio format changed. Recording stopped before copying incompatible data.")
            return
        }
        guard source.frameLength <= 8192, let destination = pool.popLast() else {
            failure = OSprError.message("Audio capture could not keep up with the device. Recording stopped to avoid silently losing speech.")
            return
        }
        destination.frameLength = source.frameLength
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let output = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard input.count == output.count, (0..<input.count).allSatisfy({ input[$0].mDataByteSize <= output[$0].mDataByteSize }) else {
            failure = OSprError.message("Capture audio buffer layout is invalid."); pool.append(destination); return
        }
        for index in 0..<input.count {
            if let from = input[index].mData, let to = output[index].mData {
                memcpy(to, from, Int(input[index].mDataByteSize))
            }
        }
        queue.async { [self] in
            do { try file?.write(destination) } catch { lock.lock(); failure = error; lock.unlock() }
            lock.lock(); pool.append(destination); lock.unlock()
        }
    }
    func silence(frames: Int) {
        guard frames > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        // A presentation-clock gap is real silence. One immutable zero buffer
        // is written on the disk queue; a long gap cannot exhaust the tap pool.
        queue.async { [self] in
            guard let file, let zeros = AVAudioPCMBuffer(pcmFormat: file.format, frameCapacity: 8192) else { return }
            zeros.frameLength = zeros.frameCapacity
            for buffer in UnsafeMutableAudioBufferListPointer(zeros.mutableAudioBufferList) {
                if let bytes = buffer.mData { memset(bytes, 0, Int(buffer.mDataByteSize)) }
            }
            var remaining = frames
            do {
                while remaining > 0 {
                    zeros.frameLength = AVAudioFrameCount(min(8192, remaining))
                    try file.write(zeros); remaining -= Int(zeros.frameLength)
                }
            } catch { lock.lock(); failure = error; lock.unlock() }
        }
    }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return failure }
    func finish() throws {
        // Every admitted enqueue schedules its write while holding this lock.
        // Close admission before draining, so a copy cannot race past finalization.
        lock.lock(); accepting = false; lock.unlock()
        queue.sync {
            do { try file?.close() } catch { lock.lock(); failure = error; lock.unlock() }
            file = nil
        }
        if let error { throw error }
    }
}
