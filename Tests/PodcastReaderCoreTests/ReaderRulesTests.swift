import Foundation
import Testing
@testable import PodcastReaderCore

struct ReaderRulesTests {
    @Test func speedsCycleInOrder() {
        #expect(PlaybackRules.speeds == [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2])
        #expect(PlaybackRules.nextSpeed(after: 1) == 1.25)
        #expect(PlaybackRules.nextSpeed(after: 2) == 0.5)
    }

    @Test func skipsStopAtBothEnds() {
        #expect(PlaybackRules.skipTarget(current: 5, delta: -10, duration: 100) == 0)
        #expect(PlaybackRules.skipTarget(current: 95, delta: 30, duration: 100) == 100)
        #expect(PlaybackRules.skipTarget(current: 50, delta: 10, duration: 100) == 60)
    }

    @Test func fontSizeIs5_5PercentClamped() {
        #expect(abs(CaptionMetrics.fontSize(forWidth: 1000) - 55) < 0.001)
        #expect(CaptionMetrics.fontSize(forWidth: 300) == 28)
        #expect(CaptionMetrics.fontSize(forWidth: 5000) == 110)
    }

    @Test func supportedAudioIgnoresExtensionCase() {
        for name in ["a.mp3", "a.MP3", "a.m4a", "a.Wav", "my lecture.v2.mp3"] {
            #expect(AudioImport.isSupported(URL(fileURLWithPath: "/tmp/\(name)")))
        }
        for name in ["a.txt", "a.mov", "mp3"] {
            #expect(!AudioImport.isSupported(URL(fileURLWithPath: "/tmp/\(name)")))
        }
    }

    @Test func timestamps() {
        #expect(TimeFormat.string(0) == "0:00")
        #expect(TimeFormat.string(65) == "1:05")
        #expect(TimeFormat.string(3723) == "1:02:03")
        #expect(TimeFormat.string(-1) == "0:00")
        #expect(TimeFormat.string(.nan) == "0:00")
    }

    let space: UInt16 = 49, left: UInt16 = 123, right: UInt16 = 124, esc: UInt16 = 53, b: UInt16 = 11, f: UInt16 = 3

    @Test func playbackKeys() {
        #expect(ReaderKeys.command(keyCode: space, modifiers: [], isTyping: false) == .togglePlay)
        #expect(ReaderKeys.command(keyCode: left, modifiers: [], isTyping: false) == .skip(-5))
        #expect(ReaderKeys.command(keyCode: right, modifiers: [], isTyping: false) == .skip(5))
        #expect(ReaderKeys.command(keyCode: left, modifiers: .shift, isTyping: false) == .skip(-30))
        #expect(ReaderKeys.command(keyCode: right, modifiers: .shift, isTyping: false) == .skip(30))
        #expect(ReaderKeys.command(keyCode: b, modifiers: [], isTyping: false) == .addBookmark)
    }

    @Test func panelKeys() {
        #expect(ReaderKeys.command(keyCode: f, modifiers: .command, isTyping: false) == .openSearch)
        #expect(ReaderKeys.command(keyCode: b, modifiers: .command, isTyping: false) == .openBookmarks)
        #expect(ReaderKeys.command(keyCode: esc, modifiers: [], isTyping: false) == .closePanel)
    }

    @Test func typingLeavesPlaybackKeysAlone() {
        for key in [space, left, right, b] {
            #expect(ReaderKeys.command(keyCode: key, modifiers: [], isTyping: true) == nil)
        }
        #expect(ReaderKeys.command(keyCode: left, modifiers: .shift, isTyping: true) == nil)
        #expect(ReaderKeys.command(keyCode: esc, modifiers: [], isTyping: true) == .closePanel)
        #expect(ReaderKeys.command(keyCode: f, modifiers: .command, isTyping: true) == .openSearch)
    }

    @Test func otherModifiersPassThrough() {
        #expect(ReaderKeys.command(keyCode: f, modifiers: [.command, .control], isTyping: false) == nil)
        #expect(ReaderKeys.command(keyCode: left, modifiers: .command, isTyping: false) == nil)
    }
}
