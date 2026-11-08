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

    /// How often playback reports in when nothing has asked for a tick sooner. Each report
    /// wakes the processor, so this is as seldom as the time shown can stand.
    public static let tickInterval: TimeInterval = 0.25

    /// The time as of the last tick or seek. Use `exactTime` for where playback is now.
    @ObservationIgnored public private(set) var currentTime: TimeInterval = 0
    /// The time for the screen. It changes when the second shown changes, or when the
    /// progress bar would move, rather than on every tick, so views redraw only then.
    public private(set) var displayTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var isPlaying = false
    public private(set) var rate: Double = 1

    /// Called at each time asked for with `tick(at:)`, every `tickInterval` during playback,
    /// and at once after a seek.
    @ObservationIgnored public var onTick: (@MainActor (TimeInterval) -> Void)?

    @ObservationIgnored private let asset: AVURLAsset
    @ObservationIgnored private let player: AVPlayer
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var boundaryObserver: Any?
    @ObservationIgnored private var boundaryTime: TimeInterval?
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
            forInterval: CMTime(seconds: Self.tickInterval, preferredTimescale: 600),
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
        let stoppedAt = exactTime
        player.pause()
        isPlaying = false
        currentTime = stoppedAt
        showTime(stoppedAt, always: true)
    }

    /// Where playback really is, including between ticks.
    public var exactTime: TimeInterval {
        guard isPlaying, pendingSeeks == 0 else { return currentTime }
        let time = player.currentTime().seconds
        return time.isFinite ? min(max(time, 0), duration) : currentTime
    }

    /// The time asked for with `tick(at:)`, if one is waiting.
    public var requestedTick: TimeInterval? {
        boundaryTime
    }

    /// Asks for a tick when playback reaches this time, such as the start of the next word,
    /// so that a highlight moves on time without checking many times a second. Replaces
    /// the time asked for before. A seek doesn't count as reaching it.
    public func tick(at time: TimeInterval?) {
        guard time != boundaryTime else { return }
        if let boundaryObserver {
            player.removeTimeObserver(boundaryObserver)
            self.boundaryObserver = nil
        }
        boundaryTime = time
        guard let time, timeObserver != nil else { return }
        boundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: time, preferredTimescale: 44_100))],
            queue: .main
        ) { [weak self] in
            MainActor.assumeIsolated { self?.reachedBoundary(time) }
        }
    }

    public func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    public func seek(to time: TimeInterval) {
        let target = min(max(time, 0), duration)
        currentTime = target
        showTime(target, always: true)
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
        seek(to: PlaybackRules.skipTarget(current: exactTime, delta: delta, duration: duration))
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
        tick(at: nil)
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
        showTime(time)
        onTick?(time)
    }

    /// The player can report a moment short of the time it was asked to stop at, which
    /// would leave the highlight on the word before, so this counts as that time at least.
    private func reachedBoundary(_ time: TimeInterval) {
        guard pendingSeeks == 0, isPlaying, time == boundaryTime else { return }
        handleTick(max(exactTime, time))
    }

    private func handleEnd() {
        isPlaying = false
        currentTime = duration
        showTime(duration, always: true)
        onTick?(duration)
    }

    /// Moves `displayTime` only when a view would show the difference: the whole second
    /// shown changes, or the progress bar would move by a pixel or so.
    private func showTime(_ time: TimeInterval, always: Bool = false) {
        let barStep = duration / 1_000
        if always || floor(time) != floor(displayTime) || abs(time - displayTime) >= barStep {
            displayTime = time
        }
    }
}
