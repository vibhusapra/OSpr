import Foundation

public enum AudioMath {
    /// Match final audio normalization: average channels into a reusable mono
    /// buffer. Supports planar and interleaved Float32 input, without allocating.
    public static func downmix(channels: UnsafePointer<UnsafeMutablePointer<Float>>, channelCount: Int,
        frames: Int, interleaved: Bool, destination: UnsafeMutableBufferPointer<Float>) -> Float {
        guard channelCount > 0, frames > 0, frames <= destination.count else { return 0 }
        var power: Float = 0
        for frame in 0..<frames {
            var sample: Float = 0
            for channel in 0..<channelCount {
                sample += interleaved ? channels[0][frame * channelCount + channel] : channels[channel][frame]
            }
            sample /= Float(channelCount)
            destination[frame] = sample; power += sample * sample
        }
        return sqrt(power / Float(frames))
    }
}
