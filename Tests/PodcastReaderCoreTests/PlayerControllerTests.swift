import AVFoundation
import Foundation
import Testing
@testable import PodcastReaderCore

@MainActor
struct PlayerControllerTests {
    func ready(_ name: String = "sample.mp3") async throws -> PlayerController {
        let player = PlayerController(url: fixture(name), isMuted: true)
        try await player.waitUntilReady()
        return player
    }

    /// Waits for a condition instead of guessing how long playback needs.
    func wait(upTo seconds: Double = 3, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func loadsDuration() async throws {
        #expect(try await ready().duration > 1)
    }

    @Test func nonAudioThrowsWhenLoading() async {
        let player = PlayerController(url: fixture("notaudio.mp3"), isMuted: true)
        await #expect(throws: (any Error).self) {
            try await player.waitUntilReady()
        }
    }

    @Test func vbrDurationMatchesDecoder() async throws {
        let file = try AVAudioFile(forReading: fixture("sample_vbr.mp3"))
        let decoded = Double(file.length) / file.processingFormat.sampleRate
        #expect(abs(try await ready("sample_vbr.mp3").duration - decoded) < 0.1)
    }

    @Test func vbrSeekLandsExactly() async throws {
        // The first tick comes from AVPlayer's own clock, so this proves where it really
        // landed, unlike currentTime, which a seek sets straight away.
        let player = try await ready("sample_vbr.mp3")
        player.seek(to: 3.21)
        var ticks: [TimeInterval] = []
        player.onTick = { ticks.append($0) }
        player.play()
        try await wait { !ticks.isEmpty }
        let first = try #require(ticks.first)
        #expect(abs(first - 3.21) < 0.25)
    }

    @Test func seekReportsTheNewTimeWhilePaused() async throws {
        let player = try await ready()
        var ticks: [TimeInterval] = []
        player.onTick = { ticks.append($0) }
        player.seek(to: 2)
        #expect(ticks.last == 2)
        #expect(!player.isPlaying)
    }

    @Test func skipStopsAtBothEnds() async throws {
        let player = try await ready()
        player.skip(by: -30)
        #expect(player.currentTime == 0)
        player.skip(by: 9_999)
        #expect(player.currentTime == player.duration)
    }

    @Test func changingSpeedWhilePausedStaysPaused() async throws {
        let player = try await ready()
        player.setRate(1.5)
        #expect(player.rate == 1.5)
        #expect(!player.isPlaying)
    }

    @Test func speedSurvivesPauseAndPlay() async throws {
        let player = try await ready()
        player.play()
        player.setRate(2)
        #expect(player.isPlaying)
        player.pause()
        player.play()
        #expect(player.rate == 2)
        #expect(player.isPlaying)
    }

    @Test func playAfterEndRestartsFromBeginning() async throws {
        let player = try await ready()
        player.seek(to: player.duration)
        player.play()
        #expect(player.isPlaying)
        #expect(player.currentTime < 1)
    }

    @Test func reachingTheEndStopsPlayback() async throws {
        let player = try await ready()
        player.seek(to: player.duration - 0.2)
        player.play()
        try await wait { !player.isPlaying }
        #expect(!player.isPlaying)
        #expect(abs(player.currentTime - player.duration) < 0.1)
    }

    @Test func tickReportsIncreasingTimeWhilePlaying() async throws {
        let player = try await ready()
        var ticks: [TimeInterval] = []
        player.onTick = { ticks.append($0) }
        player.play()
        try await wait { ticks.count >= 3 }
        #expect(ticks.count >= 3)
        #expect(zip(ticks, ticks.dropFirst()).allSatisfy { $0 <= $1 })
    }

    /// Without the tick asked for, the first one after 1.37 s would be the routine one at 1.5.
    /// The margin allows for other tests keeping the main thread busy for a moment.
    @Test func aTickAskedForArrivesOnTime() async throws {
        let player = try await ready()
        var ticks: [TimeInterval] = []
        player.onTick = { ticks.append($0) }
        player.seek(to: 1)
        player.tick(at: 1.37)
        player.play()
        try await wait { ticks.contains { $0 >= 1.37 } }
        player.stop()
        let arrived = try #require(ticks.first { $0 >= 1.37 })
        #expect(arrived < 1.45, "first tick after 1.37 s came at \(arrived)")
    }

    @Test func ticksAreFewWhenNothingIsAskedFor() async throws {
        let player = try await ready()
        var ticks = 0
        player.onTick = { _ in ticks += 1 }
        player.play()
        try await Task.sleep(for: .seconds(1))
        player.stop()
        #expect(ticks <= 8, "\(ticks) ticks in a second")
    }

    @Test func theTimeShownChangesOnlyWhenItWouldShow() async throws {
        let player = try await ready()
        var shown = [player.displayTime]
        player.play()
        let end = Date().addingTimeInterval(1)
        while Date() < end {
            try await Task.sleep(for: .milliseconds(5))
            if player.displayTime != shown.last { shown.append(player.displayTime) }
        }
        player.stop()
        // An 8-second file moves the bar a thousandth every 8 ms, so it changes at every tick,
        // but no more often than that.
        #expect(shown.count <= 9, "\(shown.count - 1) changes in a second")
        #expect(shown.count >= 3)
    }

    @Test func pausingKeepsTheExactTime() async throws {
        let player = try await ready()
        player.play()
        try await Task.sleep(for: .milliseconds(600))
        let before = player.exactTime
        player.pause()
        #expect(abs(player.currentTime - before) < 0.05)
        #expect(player.displayTime == player.currentTime)
    }

    @Test func stopHaltsPlaybackAndTicks() async throws {
        let player = try await ready()
        var ticks = 0
        player.onTick = { _ in ticks += 1 }
        player.play()
        try await wait { ticks > 0 }
        player.stop()
        let after = ticks
        try await Task.sleep(for: .milliseconds(200))
        #expect(!player.isPlaying)
        #expect(ticks == after)
    }
}
