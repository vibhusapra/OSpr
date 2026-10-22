import AVFoundation
import AudioToolbox
import OSprCore

/// Explicit disposal flushes PCM data and its WAV header before another decoder
/// receives the URL, with no dependence on a convenience object's lifetime.
final class PCMFileWriter {
    private var reference: ExtAudioFileRef?
    let format: AVAudioFormat
    init(url: URL, format: AVAudioFormat) throws {
        self.format = format
        var client = format.streamDescription.pointee
        guard client.mFormatID == kAudioFormatLinearPCM else { throw OSprError.message("Capture requires PCM audio.") }
        var output = client
        if output.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
            output.mBytesPerFrame *= output.mChannelsPerFrame
            output.mBytesPerPacket *= output.mChannelsPerFrame
            output.mFormatFlags &= ~kAudioFormatFlagIsNonInterleaved
        }
        output.mFormatFlags &= ~kAudioFormatFlagIsBigEndian
        var file: ExtAudioFileRef?
        let opened = ExtAudioFileCreateWithURL(url as CFURL, kAudioFileWAVEType, &output, nil, AudioFileFlags.eraseFile.rawValue, &file)
        guard opened == noErr, let file else { throw OSprError.message("Could not create capture WAV (\(opened)).") }
        let configured = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard configured == noErr else { ExtAudioFileDispose(file); throw OSprError.message("Unsupported capture format (\(configured)).") }
        reference = file
        do { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        catch { try? close(); throw error }
    }
    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let reference else { throw OSprError.message("Capture writer is closed.") }
        let status = ExtAudioFileWrite(reference, buffer.frameLength, buffer.audioBufferList)
        guard status == noErr else { throw OSprError.message("Capture audio write failed (\(status)).") }
    }
    func close() throws {
        guard let reference else { return }
        self.reference = nil
        let status = ExtAudioFileDispose(reference)
        guard status == noErr else { throw OSprError.message("Capture audio could not be finalized (\(status)).") }
    }
    deinit { if let reference { ExtAudioFileDispose(reference) } }
}
