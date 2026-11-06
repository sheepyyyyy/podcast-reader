import AppKit
import PodcastReaderCore

/// Sends the reader's keyboard and scroll wheel input to its model. Working at the event
/// level means shortcuts keep working after a click on a word moves SwiftUI's focus, and
/// that a mouse wheel is noticed even when it reports no scroll phase.
@MainActor
final class ReaderInputMonitor {
    private var tokens: [Any] = []

    init(model: ReaderModel) {
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak model] event in
            let keyCode = event.keyCode
            let modifiers = Self.modifiers(from: event.modifierFlags)
            let window = event.window
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard Self.isReaderWindow(window) else { return false }
                // A text field normally edits through an NSTextView.
                let responderIsTextView = window?.firstResponder is NSTextView
                return model?.handleKey(
                    keyCode: keyCode,
                    modifiers: modifiers,
                    responderIsTextView: responderIsTextView
                ) ?? false
            }
            return handled ? nil : event
        }) {
            tokens.append(keys)
        }

        if let wheel = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak model] event in
            let x = event.locationInWindow.x
            let window = event.window
            if event.scrollingDeltaY != 0 {
                MainActor.assumeIsolated {
                    if Self.isReaderWindow(window), let width = window?.frame.width {
                        model?.noteScrollWheel(x: x, windowWidth: width)
                    }
                }
            }
            return event
        }) {
            tokens.append(wheel)
        }

        // In full screen this is the only way back to the faded controls, so it shouldn't
        // depend on hover tracking alone.
        if let moves = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak model] event in
            let window = event.window
            MainActor.assumeIsolated {
                if Self.isReaderWindow(window) {
                    model?.noteMouseMoved()
                }
            }
            return event
        }) {
            tokens.append(moves)
        }
    }

    func stop() {
        tokens.forEach(NSEvent.removeMonitor)
        tokens = []
    }

    /// Leaves out anything in front of the reader, such as the About panel or a file
    /// picker, so that typing there can't control playback.
    private static func isReaderWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        guard let main = NSApp.mainWindow else { return !(window is NSPanel) }
        return window === main
    }

    private nonisolated static func modifiers(from flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var modifiers: KeyModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        return modifiers
    }
}
