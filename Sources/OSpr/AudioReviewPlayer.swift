import AVFoundation
import Combine
import Foundation
import OSprCore

@MainActor final class AudioReviewPlayer: ObservableObject {
    @Published var position = 0.0
    @Published var duration = 0.0
    @Published var playing = false
    @Published var ready = false
    @Published var loading = false
    @Published var speed = 1.0
    @Published var error = ""
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var generation = UUID()
    private var seekRevision: UInt64 = 0
    private var transportRevision: UInt64 = 0
    private var seekPending = false
    private(set) var fileName: String?

    static func localAsset(_ url: URL) throws -> AVURLAsset {
        guard url.isFileURL else { throw OSprError.message("Audio review accepts local files only.") }
        return AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
    }
    func load(_ url: URL) async {
        guard !Task.isCancelled else { return }
        stop(); let token = generation; fileName = url.lastPathComponent; loading = true
        do {
            let asset = try Self.localAsset(url)
            let length = try await asset.load(.duration).seconds
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard generation == token, !Task.isCancelled else { return }
            guard length.isFinite, length > 0, !tracks.isEmpty else { throw OSprError.message("This retained file has no playable audio.") }
            duration = length
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer()
            self.player = player
            player.actionAtItemEnd = .pause
            player.allowsExternalPlayback = false
            statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let status = item.status
                let message = item.error?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.ready = status == .readyToPlay
                    if status != .unknown { self.loading = false }
                    if status == .failed { self.error = message ?? "Audio playback could not be prepared."; self.playing = false }
                }
            }
            player.replaceCurrentItem(with: item)
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.generation == token else { return }
                    self.playing = false; self.position = self.duration
                }
            }
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, self.generation == token else { return }
                    if !self.seekPending && time.seconds.isFinite { self.position = min(self.duration, max(0, time.seconds)) }
                    self.playing = self.player?.timeControlStatus == .playing
                }
            }
        } catch {
            if generation == token && !Task.isCancelled { self.error = error.localizedDescription; loading = false }
        }
    }
    func toggle() {
        guard ready, let player else { return }
        if playing { pause() }
        else if position >= duration - 0.05 { seek(to: 0, play: true) }
        else { transportRevision &+= 1; player.playImmediately(atRate: Float(speed)); playing = true }
    }
    func pause() { transportRevision &+= 1; player?.pause(); playing = false }
    func seek(to seconds: Double, play: Bool = false) {
        guard ready, let player else { return }
        let value = AudioTimeline.clamp(seconds, duration: duration)
        let token = generation
        seekRevision &+= 1; transportRevision &+= 1
        let seekToken = seekRevision, transportToken = transportRevision
        position = value; seekPending = true
        player.seek(to: CMTime(seconds: value, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.seekRevision == seekToken else { return }
                self.seekPending = false
                if completed, play, self.transportRevision == transportToken { self.player?.playImmediately(atRate: Float(self.speed)); self.playing = true }
            }
        }
    }
    func setSpeed(_ value: Double) {
        speed = min(2, max(0.5, value.isFinite ? value : 1))
        if playing { player?.rate = Float(speed) }
    }
    func stop() {
        generation = UUID(); seekRevision &+= 1; transportRevision &+= 1; seekPending = false; player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil; statusObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        player?.replaceCurrentItem(with: nil); player = nil
        position = 0; duration = 0; playing = false; ready = false; loading = false; error = ""
        fileName = nil
    }
    deinit {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }
}
