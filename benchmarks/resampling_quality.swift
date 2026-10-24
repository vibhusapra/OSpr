import Foundation
import AVFoundation

/// JSON-lines file-only helper compiled with the actual Core resampler. Native
/// callback timings are local processing diagnostics, not capture/UI latency.
@main struct ResamplingQualityStudy {
    private struct Request: Decodable {
        let id: String
        let path: String
        let output: String
        let policy: String
        let packets: [Int]
        let repeats: Int
    }
    static func main() {
        while let line = readLine() {
            do {
                guard line.utf8.count <= 65536 else { throw OSprError.message("Request exceeds 64 KiB.") }
                let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
                let result = try run(request)
                emit(["id": request.id, "ok": true, "result": result])
            } catch { emit(["ok": false, "error": error.localizedDescription]) }
        }
    }
    private static func emit(_ result: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text); fflush(stdout) }
    }
    private static func run(_ request: Request) throws -> [String: Any] {
        guard let policy = SpeechResamplingPolicy(rawValue: request.policy),
              request.path.hasPrefix("/"), request.output.hasPrefix("/"),
              !FileManager.default.fileExists(atPath: request.output),
              !request.packets.isEmpty, request.packets.count <= 32,
              request.packets.allSatisfy({ (1...8192).contains($0) }), (1...5).contains(request.repeats) else {
            throw OSprError.message("Invalid resampling study request.")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: request.path))
        let rate = file.processingFormat.sampleRate
        guard file.processingFormat.channelCount == 1, (8000...192000).contains(rate),
              file.length > 0, file.length <= Int64(rate * 180),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else {
            throw OSprError.message("Study accepts mono audio of at most three minutes.")
        }
        var input = [Float]()
        while input.count < file.length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, Int(file.length) - input.count)))
            guard buffer.frameLength > 0, let values = buffer.floatChannelData else { throw OSprError.message("Incomplete study input.") }
            input += UnsafeBufferPointer(start: values[0], count: Int(buffer.frameLength))
        }
        var trials = [[String: Any]](), last = [Float]()
        for _ in 0..<request.repeats {
            let began = DispatchTime.now().uptimeNanoseconds
            let converter = try StreamingSpeechResampler(sampleRate: rate, policy: policy)
            let initialization = DispatchTime.now().uptimeNanoseconds - began
            let scratch = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: 8192)!
            var normalized = [Float](); normalized.reserveCapacity(Int(ceil(Double(input.count) * 16000 / rate)) + 4096)
            var position = 0, index = 0, firstOutputInputFrames: Int?
            var costs = [Double]()
            while position < input.count {
                let length = min(request.packets[index % request.packets.count], input.count - position)
                let clock = DispatchTime.now().uptimeNanoseconds
                scratch.frameLength = AVAudioFrameCount(length)
                input.withUnsafeBufferPointer { scratch.floatChannelData![0].update(from: $0.baseAddress!.advanced(by: position), count: length) }
                try converter.process(scratch) { normalized += $0 }
                costs.append(Double(DispatchTime.now().uptimeNanoseconds - clock) / 1e6)
                position += length; index += 1
                if firstOutputInputFrames == nil, !normalized.isEmpty { firstOutputInputFrames = position }
            }
            let liveFrames = normalized.count
            let flush = DispatchTime.now().uptimeNanoseconds
            try converter.finish { normalized += $0 }
            let finalCost = Double(DispatchTime.now().uptimeNanoseconds - flush) / 1e6
            if !last.isEmpty, last != normalized { throw OSprError.message("Conversion changed across identical repeats.") }
            last = normalized
            trials.append(["initialization_ms": Double(initialization) / 1e6, "process_ms": costs,
                           "flush_ms": finalCost, "live_output_frames": liveFrames, "output_frames": normalized.count,
                           "first_output_input_frames": firstOutputInputFrames ?? input.count,
                           "converter": converter.diagnostics])
        }
        // Independent whole-track conversion defines the native frame-count
        // and waveform contract. CoreAudio's fractional-frame rounding must
        // not be inferred from SciPy's ceil-length convention.
        let reference = try whole(input, rate: rate, policy: policy)
        guard last == reference else { throw OSprError.message("Packet conversion differs from whole-track reference.") }
        guard !last.isEmpty else { throw OSprError.message("No complete normalized frame was produced.") }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(last.count))!
        output.frameLength = AVAudioFrameCount(last.count)
        last.withUnsafeBufferPointer { output.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        do {
            let writer = try AVAudioFile(forWriting: URL(fileURLWithPath: request.output), settings: format.settings)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: request.output)
            try writer.write(from: output)
        }
        return ["policy": policy.rawValue, "input_rate": rate, "input_frames": input.count,
                "output_frames": last.count, "whole_reference_frames": reference.count,
                "exact_whole_reference": true, "trials": trials]
    }
    private static func whole(_ input: [Float], rate: Double, policy: SpeechResamplingPolicy) throws -> [Float] {
        if rate == 16000 { return input }
        let source = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let destination = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let converter = AVAudioConverter(from: source, to: destination)!
        policy.configure(converter)
        let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(input.count))!
        buffer.frameLength = AVAudioFrameCount(input.count)
        input.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        let output = AVAudioPCMBuffer(pcmFormat: destination, frameCapacity: AVAudioFrameCount(ceil(Double(input.count) * 16000 / rate)) + 4096)!
        var offered = false, result = [Float]()
        for _ in 0..<8 {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if !offered { offered = true; state.pointee = .haveData; return buffer }
                state.pointee = .endOfStream; return nil
            }
            if let error { throw error }
            guard status != .error else { throw OSprError.message("Whole-reference conversion failed.") }
            result += UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))
            if status == .endOfStream { return result }
        }
        throw OSprError.message("Whole-reference conversion failed to finish.")
    }
}
