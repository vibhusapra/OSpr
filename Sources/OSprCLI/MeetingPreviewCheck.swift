import Foundation
import AVFoundation
import OSprCore

/// File-only replay of the production mixer. Arrival time is a simulated clock;
/// no microphone, desktop permission, wall-clock pacing or ASR is used here.
enum MeetingPreviewCheck {
    private struct Manifest: Decodable {
        struct Source: Decodable { let source: String; let path: String; let offset: Double }
        let sources: [Source]
        let packets: [Int]
        let interval: Double
        let jitter: Double
    }
    private struct Event {
        let source: MeetingPreviewSource
        let rate: Double, timestamp: Double, arrival: Double
        let samples: [Float]
    }
    static func run(manifest: URL, directory: URL) throws -> [String: Any] {
        let handle = try FileHandle(forReadingFrom: manifest); defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 65537) ?? Data()
        guard bytes.count <= 65536 else { throw OSprError.message("Meeting replay manifest exceeds 64 KiB.") }
        let fixture = try JSONDecoder().decode(Manifest.self, from: bytes)
        guard (1...2).contains(fixture.sources.count), Set(fixture.sources.map(\.source)).count == fixture.sources.count,
              !fixture.packets.isEmpty, fixture.packets.count <= 32, fixture.packets.allSatisfy({ (128...8192).contains($0) }),
              fixture.interval.isFinite, (0.1...3).contains(fixture.interval), fixture.jitter.isFinite,
              (0...0.1).contains(fixture.jitter), !FileManager.default.fileExists(atPath: directory.path) else {
            throw OSprError.message("Invalid meeting replay schedule or existing output directory.")
        }
        var events = [Event]()
        for (sourceIndex, source) in fixture.sources.enumerated() {
            guard let kind = MeetingPreviewSource(rawValue: source.source), source.path.hasPrefix("/"),
                  source.offset.isFinite, (0...3).contains(source.offset) else { throw OSprError.message("Invalid replay source.") }
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: source.path))
            let rate = file.processingFormat.sampleRate
            guard file.processingFormat.channelCount == 1, (8000...192000).contains(rate),
                  file.length > 0, file.length <= Int64(rate * 180),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else {
                throw OSprError.message("Replay accepts mono audio up to three minutes.")
            }
            var position = 0, packetIndex = 0
            while position < file.length {
                let requested = min(fixture.packets[packetIndex % fixture.packets.count], Int(file.length) - position)
                try file.read(into: buffer, frameCount: AVAudioFrameCount(requested))
                guard buffer.frameLength > 0, let channel = buffer.floatChannelData else { throw OSprError.message("Incomplete replay input.") }
                let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
                let timestamp = source.offset + Double(position) / rate
                // Nonnegative bounded delivery delay preserves each source's order.
                let arrival = source.offset + Double(position + samples.count) / rate + fixture.jitter * Double(sourceIndex)
                events.append(Event(source: kind, rate: rate, timestamp: timestamp, arrival: arrival, samples: samples))
                position += samples.count; packetIndex += 1
            }
        }
        events.sort { $0.arrival == $1.arrival ? $0.source.rawValue < $1.source.rawValue : $0.arrival < $1.arrival }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let mixer = try MeetingPreviewMixer(includeMicrophone: fixture.sources.contains { $0.source == "microphone" })
        let fullURL = directory.appendingPathComponent("full.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        var full: AVAudioFile? = try AVAudioFile(forWriting: fullURL, settings: format.settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fullURL.path)
        var rows = [[String: Any]](), samplesWritten = 0
        var nextSnapshot = fixture.interval
        func snapshot(at time: Double, final: Bool) throws -> Bool {
            let samples = try mixer.snapshot(incremental: true)
            guard !samples.isEmpty else { return false }
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
            let packet = directory.appendingPathComponent(String(format: "packet-%04d.wav", rows.count))
            do {
                let writer = try AVAudioFile(forWriting: packet, settings: format.settings)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: packet.path)
                try writer.write(from: buffer)
            }
            try full!.write(from: buffer)
            samplesWritten += samples.count
            rows.append(["file": packet.lastPathComponent, "samples": samples.count, "end_sample": samplesWritten,
                         "simulated_arrival_seconds": time, "final_drain": final])
            return true
        }
        for event in events {
            // Consumer ticks precede packets arriving after that tick.
            while nextSnapshot < event.arrival {
                _ = try snapshot(at: nextSnapshot, final: false); nextSnapshot += fixture.interval
            }
            try event.samples.withUnsafeBufferPointer {
                try mixer.append($0, source: event.source, sampleRate: event.rate, timestamp: 1000 + event.timestamp)
            }
        }
        mixer.finish()
        while try snapshot(at: events.last!.arrival, final: true) {}
        full = nil // Close the file before a caller can inspect its frame count.
        return ["packets": rows, "full_file": fullURL.lastPathComponent, "samples": samplesWritten,
                "start_time": mixer.startTime! - 1000, "buffered_input_samples": mixer.bufferedInputSamples,
                "allocated_sample_capacity": mixer.allocatedSampleCapacity, "input_events": events.count,
                "boundary": "Unpaced public-file production mixer replay. Synthetic source arrival clock; no capture, ASR, UI, latency, memory peak or energy measurement."]
    }
}
