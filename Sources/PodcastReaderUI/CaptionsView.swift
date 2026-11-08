import PodcastReaderCore
import SwiftUI

/// The big scrolling captions. Follows the active line until the user scrolls away.
struct CaptionsView: View {
    /// How far down the window the active line sits.
    private static let anchor = 0.38

    /// Long enough for the scroll animation to finish.
    private static let correctionDelay = Duration.milliseconds(550)
    private static let correctionInterval = Duration.milliseconds(80)
    private static let maximumCorrections = 25
    private static let coordinateSpaceName = "captions"

    let model: ReaderModel

    @State private var correctionTask: Task<Void, Never>?
    @State private var tracker = ActiveRowTracker()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let fontSize = CaptionMetrics.fontSize(forWidth: geometry.size.width)
            ScrollViewReader { proxy in
                ScrollView {
                    CaptionLines(
                        model: model,
                        fontSize: fontSize,
                        tracker: tracker,
                        coordinateSpaceName: Self.coordinateSpaceName
                    )
                    .padding(.horizontal, geometry.size.width * 0.068)
                    .padding(.top, geometry.size.height * Self.anchor)
                    .padding(.bottom, geometry.size.height * (1 - Self.anchor))
                }
                .coordinateSpace(name: Self.coordinateSpaceName)
                .scrollIndicators(.never)
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting || phase == .tracking {
                        model.isFollowing = false
                    }
                }
                .onAppear { scrollToActive(proxy, height: geometry.size.height, animated: false) }
                .onChange(of: model.activeLine) { scrollToActive(proxy, height: geometry.size.height, animated: true) }
                .onChange(of: model.isFollowing) { scrollToActive(proxy, height: geometry.size.height, animated: true) }
                .onChange(of: geometry.size) { scrollToActive(proxy, height: geometry.size.height, animated: false) }
                .onDisappear { correctionTask?.cancel() }
            }
        }
    }

    private func scrollToActive(_ proxy: ScrollViewProxy, height: Double, animated: Bool) {
        guard model.isFollowing else { return }
        let target = UnitPoint(x: 0, y: Self.anchor)
        let line = model.activeLine ?? 0
        if animated && !reduceMotion {
            withAnimation(.smooth(duration: 0.45)) {
                proxy.scrollTo(line, anchor: target)
            }
        } else {
            proxy.scrollTo(line, anchor: target)
        }

        // A lazy stack estimates the height of rows it hasn't drawn, so a scroll across a
        // long transcript can land in the wrong place, especially overlapping ones from
        // dragging the progress bar. Once the animation is over, check where the active
        // row really is and keep correcting until it's right. If it's already right,
        // this does nothing.
        correctionTask?.cancel()
        correctionTask = Task { @MainActor in
            try? await Task.sleep(for: Self.correctionDelay)
            for _ in 0..<Self.maximumCorrections {
                guard !Task.isCancelled, model.isFollowing else { return }
                let line = model.activeLine ?? 0
                if tracker.isRow(line, atAnchor: Self.anchor, viewportHeight: height) { return }
                proxy.scrollTo(line, anchor: target)
                try? await Task.sleep(for: Self.correctionInterval)
            }
        }
    }
}

/// Where the active row really is on screen. This isn't observed by any view, because
/// only the scroll correction reads it, and it changes on every frame of a scroll.
@MainActor
private final class ActiveRowTracker {
    private var line: Int?
    private var frame = CGRect.zero

    func update(line: Int, frame: CGRect) {
        self.line = line
        self.frame = frame
    }

    func forget(line: Int) {
        if self.line == line {
            self.line = nil
        }
    }

    /// `scrollTo` lines up the same fraction of the row and the viewport, so that's what
    /// to compare. A row that hasn't been drawn isn't in place, whatever an estimate says.
    func isRow(_ row: Int, atAnchor anchor: Double, viewportHeight: Double) -> Bool {
        guard line == row else { return false }
        return abs(frame.minY + frame.height * anchor - viewportHeight * anchor) <= 3
    }
}

private struct CaptionLines: View {
    let model: ReaderModel
    let fontSize: Double
    let tracker: ActiveRowTracker
    let coordinateSpaceName: String

    var body: some View {
        let transcript = model.lecture.transcript
        let activeWord = model.activeWord
        let activeLine = model.activeLine
        let trackedLine = activeLine ?? 0

        LazyVStack(alignment: .leading, spacing: fontSize * 0.42) {
            ForEach(transcript.lines) { line in
                let isTracked = line.id == trackedLine
                LineRow(
                    firstWord: line.wordRange.lowerBound,
                    words: transcript.words[line.wordRange].map(\.text),
                    state: state(of: line, activeLine: activeLine, activeWord: activeWord),
                    fontSize: fontSize,
                    onTapWord: { model.jump(toWord: $0) }
                )
                .equatable()
                .id(line.id)
                .onGeometryChange(for: CGRect?.self) { [coordinateSpaceName] proxy in
                    isTracked ? proxy.frame(in: .named(coordinateSpaceName)) : nil
                } action: { frame in
                    if let frame {
                        tracker.update(line: line.id, frame: frame)
                    }
                }
                .onDisappear { tracker.forget(line: line.id) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func state(of line: Line, activeLine: Int?, activeWord: Int?) -> LineRow.State {
        guard let activeLine, let activeWord else { return .upcoming }
        if line.id < activeLine { return .past }
        if line.id > activeLine { return .upcoming }
        return .active(wordIndex: activeWord)
    }
}

/// One caption line. Compared by value so a word change redraws only the active row.
private struct LineRow: View, Equatable {
    enum State: Equatable {
        case past
        case active(wordIndex: Int)
        case upcoming

        enum Phase {
            case past, active, upcoming
        }

        /// Where the line is, leaving out which word is active.
        var phase: Phase {
            switch self {
            case .past: .past
            case .active: .active
            case .upcoming: .upcoming
            }
        }
    }

    let firstWord: Int
    let words: [String]
    let state: State
    let fontSize: Double
    let onTapWord: (Int) -> Void

    nonisolated static func == (left: LineRow, right: LineRow) -> Bool {
        left.firstWord == right.firstWord && left.state == right.state && left.fontSize == right.fontSize
    }

    var body: some View {
        FlowLayout(wordSpacing: fontSize * 0.25, lineSpacing: fontSize * -0.07) {
            ForEach(words.indices, id: \.self) { offset in
                let index = firstWord + offset
                WordView(
                    text: words[offset],
                    color: color(ofWord: index),
                    glows: state == .active(wordIndex: index),
                    fontSize: fontSize
                ) {
                    onTapWord(index)
                }
            }
        }
        // Only a change of line fades. Fading each word as it lights up redraws the whole
        // line for every frame of the fade, which was half the work captions did.
        .animation(.easeOut(duration: 0.12), value: state.phase)
    }

    private func color(ofWord index: Int) -> Color {
        switch state {
        case .past: Palette.past
        case .upcoming: Palette.upcoming
        case .active(let wordIndex): index <= wordIndex ? .white : Palette.upcoming
        }
    }
}

private struct WordView: View {
    let text: String
    let color: Color
    let glows: Bool
    let fontSize: Double
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .heavy))
            .tracking(fontSize * -0.035)
            .foregroundStyle(color)
            .underline(isHovering, color: color)
            .shadow(color: glows ? Palette.glow : .clear, radius: fontSize * 0.22)
            .contentShape(.rect)
            .onHover { isHovering = $0 }
            .onTapGesture(perform: onTap)
            .pointerStyle(.link)
            .accessibilityAddTraits(.isButton)
    }
}

/// Lays words out left to right, wrapping when a line is wider than the space.
private struct FlowLayout: Layout {
    let wordSpacing: CGFloat
    let lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let origins = arrange(subviews, width: bounds.width).origins
        for (subview, origin) in zip(subviews, origins) {
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            widest = max(widest, x + size.width)
            x += size.width + wordSpacing
            rowHeight = max(rowHeight, size.height)
        }
        return (origins, CGSize(width: widest, height: y + rowHeight))
    }
}
