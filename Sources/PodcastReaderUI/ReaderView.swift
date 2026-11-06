import AppKit
import PodcastReaderCore
import SwiftUI

package struct ReaderView: View {
    let model: ReaderModel
    let onClose: () -> Void

    /// The height of the control bar, which captions must fade out above.
    private static let controlBarHeight = 150.0

    @State private var inputMonitor: ReaderInputMonitor?
    @State private var isCompact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    package init(model: ReaderModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    package var body: some View {
        ZStack {
            AuroraBackground()

            HStack(spacing: 0) {
                captionsColumn

                if model.panel != nil {
                    SidePanel(model: model)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: model.panel)
        }
        .onContinuousHover { phase in
            if case .active = phase {
                model.noteMouseMoved()
            }
        }
        .onChange(of: model.controlsVisible) {
            if !model.controlsVisible {
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            model.setFullScreen(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            model.setFullScreen(false)
        }
        .onAppear {
            if (NSApp.mainWindow ?? NSApp.keyWindow)?.styleMask.contains(.fullScreen) == true {
                model.setFullScreen(true)
            }
            // Windows don't report mouse movement unless asked to.
            (NSApp.mainWindow ?? NSApp.keyWindow)?.acceptsMouseMovedEvents = true
            // Stopped first so that a second appearance can't make every shortcut fire twice.
            inputMonitor?.stop()
            inputMonitor = ReaderInputMonitor(model: model)
        }
        .onDisappear {
            inputMonitor?.stop()
            inputMonitor = nil
        }
    }

    private var captionsColumn: some View {
        ZStack(alignment: .topLeading) {
            readingContent

            controls

            if !model.isFollowing {
                backToNow
            }

            if let toast = model.toast {
                toastView(toast)
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width < ControlBar.compactBelowWidth
        } action: { isCompact = $0 }
    }

    /// The real page for a PDF, or big captions for audio.
    @ViewBuilder
    private var readingContent: some View {
        if model.documentURL != nil {
            PDFPageView(model: model)
                .padding(.top, model.controlsVisible ? 44 : 0)
                .padding(.bottom, model.controlsVisible ? Self.controlBarHeight : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: model.controlsVisible)
                .ignoresSafeArea()
        } else {
            CaptionsView(model: model)
                .mask(edgeFade)
                .ignoresSafeArea()
        }
    }

    /// Fades captions out at the edges so they never collide with the controls. Sized in
    /// points, because the controls stay the same height whatever the window's size.
    /// With the controls faded in full screen, captions use the full height.
    private var edgeFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 70)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 70)
            Color.clear
                .frame(height: model.controlsVisible ? Self.controlBarHeight : 0)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: model.controlsVisible)
        .ignoresSafeArea()
    }

    private var controls: some View {
        ZStack(alignment: .topLeading) {
            ControlBar(model: model, isCompact: isCompact)
                .frame(maxHeight: .infinity, alignment: .bottom)

            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.12), in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help("Back to your lectures")
            .accessibilityLabel("Back to your lectures")
            // In a window, this clears the close, minimize and zoom buttons.
            .padding(.leading, model.isFullScreen ? 24 : 84)
            .padding(.top, 8)
        }
        .ignoresSafeArea()
        .opacity(model.controlsVisible ? 1 : 0)
        .allowsHitTesting(model.controlsVisible)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: model.controlsVisible)
    }

    private var backToNow: some View {
        Button { model.backToNow() } label: {
            Text("Back to now")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Palette.navy)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.white, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // Just above the progress bar, clear of the PDF page, which ends at the bar's top.
        .padding(.bottom, 112)
    }

    private func toastView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Palette.navy)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Palette.bookmarkTick, in: .capsule)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
            .allowsHitTesting(false)
    }
}
