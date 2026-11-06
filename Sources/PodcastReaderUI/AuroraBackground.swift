import SwiftUI

/// Slowly drifting color fields behind the captions.
struct AuroraBackground: View {
    private static let colors: [Color] = [
        Palette.fieldBlue, Palette.navy, Palette.fieldTeal,
        Palette.navy, Palette.fieldViolet, Palette.navy,
        Palette.fieldTeal, Palette.navy, Palette.fieldViolet,
    ]
    /// Seconds for the slowest full drift, about 9 s each way.
    private static let period = 18.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            MeshGradient(
                width: 3,
                height: 3,
                points: Self.points(at: time),
                colors: Self.colors,
                background: Palette.navy,
                smoothsColors: true
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// Corners stay fixed so the whole window stays covered; the rest drift.
    private static func points(at time: TimeInterval) -> [SIMD2<Float>] {
        func wave(_ speed: Double, _ phase: Double, _ amount: Double) -> Float {
            Float(sin(time * 2 * .pi / period * speed + phase) * amount)
        }
        return [
            [0, 0],
            [0.5 + wave(0.9, 0.0, 0.22), 0],
            [1, 0],
            [0, 0.5 + wave(1.0, 1.1, 0.22)],
            [0.5 + wave(0.8, 2.0, 0.24), 0.5 + wave(1.1, 0.4, 0.24)],
            [1, 0.5 + wave(0.7, 3.0, 0.22)],
            [0, 1],
            [0.5 + wave(1.2, 4.2, 0.22), 1],
            [1, 1],
        ]
    }
}
