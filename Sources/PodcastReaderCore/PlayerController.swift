@preconcurrency import AVFoundation
import Foundation
import Observation

public enum PlayerError: Error, Equatable {
    case unplayable
}

/// Plays one audio file with precise timing, so a clicked word lands on that word
/// even in a variable-bitrate MP3.
@MainActor
@Observable
public final class PlayerController {
    private static let endTolerance: TimeInterval = 0.05

    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var isPlaying = false
    public private(set) var rate: Double = 1

    /// Called about 30 times a second during playback, and at once after a seek.
    @ObservationIgnored public var onTick: (@MainActor (TimeInterval) -> Void)?

    @ObservationIgnored private let asset: AVURLAsset
    @ObservationIgnored private let player: AVPlayer
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
    /// While a seek is in flight, the player can still report the old time.
    @ObservationIgnored private var pendingSeeks = 0

    public init(url: URL, isMuted: Bool = false) {
        asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        player = AVPlayer(playerItem: item)
        player.isMuted = isMuted
        player.actionAtItemEnd = .pause

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.handleTick(time.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleEnd() }
        }
    }

    isolated deinit {
        stop()
    }

    /// Loads the file's real duration. Throws if it can't be played.
    public func waitUntilReady() async throws {
        let playable = try await asset.load(.isPlayable)
        guard playable else { throw PlayerError.unplayable }
        let loaded = try await asset.load(.duration).seconds
        guard loaded.isFinite, loaded > 0 else { throw PlayerError.unplayable }
        duration = loaded
    }

    /// Starts playing at the current speed, restarting from the beginning if at the end.
    public func play() {
        if duration > 0, currentTime >= duration - Self.endTolerance {
            seek(to: 0)
        }
        player.defaultRate = Float(rate)
        player.play()
        isPlaying = true
    }

    public func pause() {
        player.pause()
        isPlaying = false
    }

    public func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    public func seek(to time: TimeInterval) {
        let target = min(max(time, 0), duration)
        currentTime = target
        pendingSeeks += 1
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 44_100),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.pendingSeeks -= 1 }
            }
        }
        onTick?(target)
    }

    public func skip(by delta: TimeInterval) {
        seek(to: PlaybackRules.skipTarget(current: currentTime, delta: delta, duration: duration))
    }

    /// Changes speed without starting a paused player.
    public func setRate(_ newRate: Double) {
        rate = newRate
        player.defaultRate = Float(newRate)
        if isPlaying {
            player.rate = Float(newRate)
        }
    }

    /// Ends playback for good. Call when leaving the lecture.
    public func stop() {
        player.pause()
        isPlaying = false
        onTick = nil
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func handleTick(_ time: TimeInterval) {
        guard pendingSeeks == 0, time.isFinite else { return }
        currentTime = time
        onTick?(time)
    }

    private func handleEnd() {
        isPlaying = false
        currentTime = duration
        onTick?(duration)
    }
}
