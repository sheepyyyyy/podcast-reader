import Foundation

public enum PlaybackRules {
    public static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    /// The next speed in the cycle, wrapping back to the slowest after the fastest.
    public static func nextSpeed(after speed: Double) -> Double {
        speeds.first { $0 > speed } ?? speeds[0]
    }

    /// Where a skip lands. Skips stop at the start and end of the audio.
    public static func skipTarget(current: TimeInterval, delta: TimeInterval, duration: TimeInterval) -> TimeInterval {
        min(max(current + delta, 0), duration)
    }
}

public enum CaptionMetrics {
    /// Text size follows the width of the captions area: 5.5%, between 28 and 110 points.
    public static func fontSize(forWidth width: Double) -> Double {
        min(max(width * 0.055, 28), 110)
    }
}

public enum ImportKind: Equatable, Sendable {
    case audio
    case document
}

public enum AudioImport {
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "wav"]

    public static func kind(of url: URL) -> ImportKind? {
        let fileExtension = url.pathExtension.lowercased()
        if audioExtensions.contains(fileExtension) { return .audio }
        return fileExtension == "pdf" ? .document : nil
    }

    public static func isSupported(_ url: URL) -> Bool {
        kind(of: url) != nil
    }
}

public enum TimeFormat {
    /// `m:ss`, or `h:mm:ss` from one hour up.
    public static func string(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = total / 60 % 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}

public enum ReaderCommand: Equatable, Sendable {
    case togglePlay
    case skip(TimeInterval)
    case addBookmark
    case openSearch
    case openBookmarks
    case closePanel
}

public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let command = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let option = KeyModifiers(rawValue: 1 << 3)
}

/// Maps key presses to reader commands. While typing in a text field, only the
/// panel shortcuts apply, so Space, B and the arrow keys keep their normal meaning.
public enum ReaderKeys {
    private enum Key {
        static let space: UInt16 = 49
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let escape: UInt16 = 53
        static let b: UInt16 = 11
        static let f: UInt16 = 3
    }

    public static func command(keyCode: UInt16, modifiers: KeyModifiers, isTyping: Bool) -> ReaderCommand? {
        switch (keyCode, modifiers) {
        case (Key.f, .command): return .openSearch
        case (Key.b, .command): return .openBookmarks
        case (Key.escape, []): return .closePanel
        default: break
        }
        guard !isTyping else { return nil }

        switch (keyCode, modifiers) {
        case (Key.space, []): return .togglePlay
        case (Key.left, []): return .skip(-5)
        case (Key.right, []): return .skip(5)
        case (Key.left, .shift): return .skip(-30)
        case (Key.right, .shift): return .skip(30)
        case (Key.b, []): return .addBookmark
        default: return nil
        }
    }
}
