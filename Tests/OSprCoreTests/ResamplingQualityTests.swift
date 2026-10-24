import XCTest
import AVFoundation
@testable import OSprCore

final class ResamplingQualityTests: XCTestCase {
    func testResearchPoliciesReadBackTheirExplicitSettings() throws {
        for policy in SpeechResamplingPolicy.allCases {
            let converter = try StreamingSpeechResampler(sampleRate: 48000, policy: policy)
            let state = converter.diagnostics
            if policy == .systemDefault { continue } // OS-defined; never assume its value across releases.
            XCTAssertEqual(state["quality"] as? Int, policy == .normalHigh ? 96 : 127)
            let algorithm = policy == .masteringMax ? AVSampleRateConverterAlgorithm_Mastering :
                policy == .minimumPhaseMax ? AVSampleRateConverterAlgorithm_MinimumPhase : AVSampleRateConverterAlgorithm_Normal
            XCTAssertEqual(state["algorithm"] as? String, algorithm)
        }
    }
    func testSixteenKHzIdentityBypassesEveryResearchPolicy() throws {
        let source = (0..<23117).map { Float(sin(Double($0) * 0.23)) * 0.3 }
        for policy in SpeechResamplingPolicy.allCases {
            let (values, state) = try convert(source, rate: 16000, policy: policy, packets: [1, 256, 8192, 317])
            XCTAssertEqual(values, source)
            XCTAssertEqual(state["passthrough"] as? Bool, true)
        }
    }
    func testNativeRatePoliciesPreserveWholeTrackPCMAndTailAcrossPartitions() throws {
        for rate in [44100.0, 48000.0] {
            let count = Int(rate * 1.137)
            let source: [Float] = (0..<count).map { index in
                let value = sin(Double(index) * 0.031) + 0.1 * cos(Double(index) * 0.37)
                return Float(value) * 0.3
            }
            for policy in SpeechResamplingPolicy.allCases {
                let expected = try whole(source, rate: rate, policy: policy)
                for packets in [[1024], [128, 8192, 317, 256]] {
                    let (actual, _) = try convert(source, rate: rate, policy: policy, packets: packets)
                    XCTAssertLessThanOrEqual(abs(Double(actual.count) - Double(source.count) * 16000 / rate), 1)
                    XCTAssertEqual(actual, expected, "\(rate) / \(policy) / \(packets)")
                }
            }
        }
    }
    func testFractionalNativeFrameCountsMatchWholeConversionWithoutCeilAssumption() throws {
        for rate in [44100.0, 48000.0] {
            for count in [1, 17, 128, 44099, 44101, 460184, 500867] {
                let source: [Float] = (0..<count).map { Float(sin(Double($0) * 0.013)) * 0.3 }
                for policy in SpeechResamplingPolicy.allCases {
                    let expected = try whole(source, rate: rate, policy: policy)
                    let (actual, _) = try convert(source, rate: rate, policy: policy, packets: [1024])
                    XCTAssertEqual(actual, expected, "\(rate) / \(count) / \(policy)")
                    XCTAssertLessThanOrEqual(abs(Double(actual.count) - Double(count) * 16000 / rate), 1)
                }
            }
        }
    }
    private func convert(_ source: [Float], rate: Double, policy: SpeechResamplingPolicy,
                         packets: [Int]) throws -> ([Float], [String: Any]) {
        let converter = try StreamingSpeechResampler(sampleRate: rate, policy: policy)
        let buffer = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: 8192)!
        var position = 0, index = 0, result = [Float]()
        while position < source.count {
            let count = min(packets[index % packets.count], source.count - position)
            buffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count { buffer.floatChannelData![0][i] = source[position + i] }
            try converter.process(buffer) { result += $0 }
            position += count; index += 1
        }
        try converter.finish { result += $0 }
        return (result, converter.diagnostics)
    }
    private func whole(_ source: [Float], rate: Double, policy: SpeechResamplingPolicy) throws -> [Float] {
        let inputFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)!
        // Independent explicit reference settings; do not invoke policy.configure.
        switch policy {
        case .systemDefault: break
        case .normalHigh: converter.sampleRateConverterQuality = 96; converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        case .normalMax: converter.sampleRateConverterQuality = 127; converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        case .masteringMax: converter.sampleRateConverterQuality = 127; converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        case .minimumPhaseMax: converter.sampleRateConverterQuality = 127; converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_MinimumPhase
        }
        let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(source.count))!
        input.frameLength = AVAudioFrameCount(source.count)
        for i in source.indices { input.floatChannelData![0][i] = source[i] }
        let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(ceil(Double(source.count) * 16000 / rate)) + 4096)!
        var offered = false, result = [Float]()
        for _ in 0..<8 {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if !offered { offered = true; state.pointee = .haveData; return input }
                state.pointee = .endOfStream; return nil
            }
            if let error { throw error }
            XCTAssertNotEqual(status, .error)
            result += UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))
            if status == .endOfStream { return result }
        }
        throw OSprError.message("Whole-track quality reference did not finish")
    }
}
