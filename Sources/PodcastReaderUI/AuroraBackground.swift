import AppKit
import SwiftUI

/// Slowly drifting color fields behind the captions.
///
/// This fills the window, so it's the costliest thing on screen if left to run. It's drawn
/// at an eighth of the size and stretched, which a blur this soft doesn't show, and it
/// only drifts while something plays with the app in front, about ten times a second,
/// which is plenty for fields this slow. Otherwise it holds still and costs nothing.
struct AuroraBackground: View {
    /// Whether the fields should move, such as while audio plays.
    var isDrifting = false

    private static let colors: [Color] = [
        Palette.fieldBlue, Palette.navy, Palette.fieldTeal,
        Palette.navy, Palette.fieldViolet, Palette.navy,
        Palette.fieldTeal, Palette.navy, Palette.fieldViolet,
    ]
    /// Seconds for the slowest full drift, about 9 s each way.
    private static let period = 18.0
    /// How much smaller than the window the fields are drawn.
    private static let downscale = 8.0

    @State private var drift = AuroraDrift()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            MeshGradient(
                width: 3,
                height: 3,
                points: Self.points(at: drift.time),
                colors: Self.colors,
                background: Palette.navy,
                smoothsColors: true
            )
            .frame(width: geometry.size.width / Self.downscale, height: geometry.size.height / Self.downscale)
            .drawingGroup()
            .scaleEffect(Self.downscale, anchor: .topLeading)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .onAppear { drift.isWanted = isDrifting && !reduceMotion }
        .onChange(of: isDrifting && !reduceMotion) { drift.isWanted = $1 }
        .onDisappear { drift.isWanted = false }
    }

    /// Corners stay fixed so the whole window stays covered; the rest drift.
    static func points(at time: TimeInterval) -> [SIMD2<Float>] {
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

/// How far the fields have drifted. It only counts time spent drifting, so they pick up
/// where they stopped rather than jumping, including on the next screen.
@MainActor
@Observable
final class AuroraDrift {
    /// Shared between screens, so changing screens doesn't move the fields.
    private static var sharedTime = 0.0
    /// Ten frames a second changes no pixel by more than 3 levels in 255 at a time, too
    /// little to see on colors this dark. Five frames a second can reach 5 levels.
    static let interval = Duration.milliseconds(100)

    private(set) var time = AuroraDrift.sharedTime

    /// Set by the view. It only drifts while the app is in front and can be seen, too.
    @ObservationIgnored var isWanted = false {
        didSet { update() }
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init() {
        let names = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSApplication.didChangeOcclusionStateNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }
    }

    isolated deinit {
        task?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    var isRunning: Bool { task != nil }

    private func update() {
        let shouldRun = isWanted && NSApp?.isActive == true && NSApp?.occlusionState.contains(.visible) == true
        if shouldRun, task == nil {
            time = Self.sharedTime
            task = Task { [weak self] in
                var last = ContinuousClock.now
                while !Task.isCancelled {
                    // The leeway lets the system line this up with other work.
                    try? await Task.sleep(for: Self.interval, tolerance: .milliseconds(30))
                    guard !Task.isCancelled, let self else { return }
                    let now = ContinuousClock.now
                    // After a stall, such as the Mac sleeping, carry on rather than leap.
                    let step = min((now - last) / .seconds(1), 0.25)
                    last = now
                    self.time += step
                    Self.sharedTime = self.time
                }
            }
        } else if !shouldRun, let running = task {
            running.cancel()
            task = nil
        }
    }
}
