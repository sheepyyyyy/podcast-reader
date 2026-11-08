import AppKit
import PodcastReaderCore
import SwiftUI

/// Playback controls and the progress bar along the bottom of the reader.
struct ControlBar: View {
    /// Columns narrower than this, such as beside the side panel in a small window,
    /// use smaller controls so that everything still fits.
    nonisolated static let compactBelowWidth = 600.0

    let model: ReaderModel
    let isCompact: Bool

    private var buttonSize: Double {
        isCompact ? 34 : 42
    }

    var body: some View {
        VStack(spacing: 6) {
            ProgressBar(model: model)

            HStack(spacing: 2) {
                ControlButton(symbol: "magnifyingglass", label: "Search", size: buttonSize) {
                    model.openPanel(.search)
                }
                ControlButton(symbol: "bookmark", label: "Add bookmark", size: buttonSize) {
                    model.addBookmark()
                }
                ControlButton(symbol: "list.bullet", label: "Bookmarks", size: buttonSize) {
                    model.openPanel(.bookmarks)
                }

                Spacer(minLength: 8)

                ControlButton(symbol: "gobackward.30", label: "Back 30 seconds", size: buttonSize) {
                    model.perform(.skip(-30))
                }
                ControlButton(symbol: "gobackward.5", label: "Back 5 seconds", size: buttonSize) {
                    model.perform(.skip(-5))
                }
                PlayButton(model: model, size: isCompact ? 44 : 52)
                    .padding(.horizontal, isCompact ? 4 : 6)
                ControlButton(symbol: "goforward.5", label: "Forward 5 seconds", size: buttonSize) {
                    model.perform(.skip(5))
                }
                ControlButton(symbol: "goforward.30", label: "Forward 30 seconds", size: buttonSize) {
                    model.perform(.skip(30))
                }

                Spacer(minLength: 8)

                SpeedButton(model: model, width: isCompact ? 46 : 54, height: buttonSize)
                ControlButton(
                    symbol: model.isFullScreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right",
                    label: model.isFullScreen ? "Exit full screen" : "Full screen",
                    size: buttonSize
                ) {
                    (NSApp.mainWindow ?? NSApp.keyWindow)?.toggleFullScreen(nil)
                }
            }
        }
        .padding(.horizontal, isCompact ? 12 : 24)
        .padding(.top, 44)
        .padding(.bottom, 14)
        .background {
            LinearGradient(
                stops: [
                    .init(color: Palette.scrim.opacity(0), location: 0),
                    .init(color: Palette.scrim.opacity(0.9), location: 0.55),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

private struct ControlButton: View {
    let symbol: String
    let label: String
    let size: Double
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(.white.opacity(isHovering ? 0.14 : 0), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct PlayButton: View {
    let model: ReaderModel
    let size: Double

    var body: some View {
        let isPlaying = model.player.isPlaying
        Button { model.togglePlay() } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(Palette.navy)
                .frame(width: size, height: size)
                .background(.white, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(isPlaying ? "Pause" : "Play")
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}

private struct SpeedButton: View {
    let model: ReaderModel
    let width: Double
    let height: Double

    @State private var isHovering = false

    var body: some View {
        Button { model.cycleSpeed() } label: {
            Text(String(format: "%g×", model.player.rate))
                .font(.system(size: 14, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: width, height: height)
                .background(.white.opacity(isHovering ? 0.14 : 0), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Playback speed")
        .accessibilityLabel("Playback speed")
        .accessibilityValue(String(format: "%g times", model.player.rate))
    }
}

/// Kept separate so only this view redraws as the time shown changes.
private struct ProgressBar: View {
    let model: ReaderModel

    private var duration: TimeInterval {
        model.player.duration
    }

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let time = model.player.displayTime
                let fraction = duration > 0 ? min(max(time / duration, 0), 1) : 0

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.22))
                        .frame(height: 4)
                    Capsule()
                        .fill(.white)
                        .frame(width: width * fraction, height: 4)

                    if duration > 0 {
                        ForEach(model.lecture.bookmarks) { bookmark in
                            BookmarkTick(label: TimeFormat.string(bookmark.time)) {
                                model.jump(toWord: bookmark.wordIndex)
                            }
                            .offset(x: width * bookmark.time / duration - BookmarkTick.width / 2)
                        }
                    }
                }
                .frame(width: width, height: 18)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard width > 0 else { return }
                            model.player.seek(to: value.location.x / width * duration)
                        }
                )
            }
            .frame(height: 18)
            .accessibilityElement()
            .accessibilityLabel("Progress")
            .accessibilityValue(TimeFormat.string(model.player.displayTime))

            HStack {
                Text(TimeFormat.string(model.player.displayTime))
                Spacer()
                Text(TimeFormat.string(duration))
            }
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(Palette.upcoming)
        }
    }
}

private struct BookmarkTick: View {
    static let width = 13.0

    let label: String
    let action: () -> Void

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Palette.bookmarkTick)
            .frame(width: 3, height: 14)
            .frame(width: Self.width, height: 18)
            .contentShape(.rect)
            .onTapGesture(perform: action)
            .help("Bookmark at \(label)")
    }
}
