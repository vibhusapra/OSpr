import AVFoundation

/// One continuous mono conversion session, owned by the inference queue. Never
/// recreate it for each hardware block; doing so resets the filter at each seam.
final class StreamingSpeechResampler {
    let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let output: AVAudioPCMBuffer
    private var finished = false
    init(sampleRate: Double) throws {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate),
              let inputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let destination = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let output = AVAudioPCMBuffer(pcmFormat: destination, frameCapacity: 4096) else {
            throw OSprError.message("Unsupported microphone rate for neural speech detection. Stop manually.")
        }
        self.inputFormat = inputFormat; self.output = output
        if sampleRate == 16_000 { converter = nil }
        else {
            guard let converter = AVAudioConverter(from: inputFormat, to: destination) else {
                throw OSprError.message("Could not prepare continuous microphone resampling.")
            }
            self.converter = converter
        }
    }
    func process(_ input: AVAudioPCMBuffer, consume: (UnsafeBufferPointer<Float>) throws -> Void) throws {
        guard !finished, input.format.isEqual(inputFormat), input.frameLength > 0,
              input.frameLength <= 8192, let values = input.floatChannelData else {
            throw OSprError.message("Invalid microphone block in speech resampling.")
        }
        guard UnsafeBufferPointer(start: values[0], count: Int(input.frameLength)).allSatisfy(\.isFinite) else {
            throw OSprError.message("Non-finite microphone input in speech detection.")
        }
        guard converter != nil else {
            try consume(UnsafeBufferPointer(start: values[0], count: Int(input.frameLength))); return
        }
        try convert(input, final: false, consume: consume)
    }
    func finish(consume: (UnsafeBufferPointer<Float>) throws -> Void) throws {
        guard !finished else { throw OSprError.message("Speech resampling is already finished.") }
        finished = true
        if converter != nil { try convert(nil, final: true, consume: consume) }
    }
    private func convert(_ input: AVAudioPCMBuffer?, final: Bool,
                         consume: (UnsafeBufferPointer<Float>) throws -> Void) throws {
        guard let converter else { return }
        var offered = false
        // At the minimum admitted rate an 8192-frame block produces 16384
        // output frames. The bounded drain also detects a converter that stalls.
        for _ in 0..<16 {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if let input, !offered { offered = true; state.pointee = .haveData; return input }
                state.pointee = final ? .endOfStream : .noDataNow; return nil
            }
            if let error { throw error }
            guard status != .error else { throw OSprError.message("Continuous speech resampling failed.") }
            if output.frameLength > 0 {
                let values = UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))
                guard values.allSatisfy(\.isFinite) else { throw OSprError.message("Speech resampling returned invalid samples.") }
                try consume(values)
            }
            if status == .endOfStream || status == .inputRanDry { return }
            if output.frameLength == 0 { throw OSprError.message("Speech resampling stopped making progress.") }
        }
        throw OSprError.message("Speech resampling exceeded its bounded drain.")
    }
}
