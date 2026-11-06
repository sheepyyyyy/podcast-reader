import AppKit
import PDFKit
import PodcastReaderCore
import SwiftUI

/// The real PDF page, with the word being spoken highlighted.
struct PDFPageView: View {
    let model: ReaderModel

    var body: some View {
        // Read here so that only this small view updates as each word is spoken.
        PDFPageRepresentable(model: model, activeWord: model.activeWord, isFollowing: model.isFollowing)
    }
}

private struct PDFPageRepresentable: NSViewRepresentable {
    let model: ReaderModel
    let activeWord: Int?
    let isFollowing: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.backgroundColor = .clear
        if let url = model.documentURL {
            view.document = PDFDocument(url: url)
        }
        Self.clearScrollBackgrounds(in: view)
        context.coordinator.attach(to: view)
        return view
    }

    /// PDFView's inner scroll view paints its own dark background over the Aurora.
    private static func clearScrollBackgrounds(in view: NSView) {
        for subview in view.subviews {
            if let scrollView = subview as? NSScrollView {
                scrollView.drawsBackground = false
                scrollView.contentView.drawsBackground = false
            }
            clearScrollBackgrounds(in: subview)
        }
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.update(activeWord: activeWord, isFollowing: isFollowing)
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.stopWatchingClicks()
    }

    @MainActor
    final class Coordinator: NSObject {
        /// Scrolling brings the active word to this far down the visible area.
        private static let followPosition = 0.2
        /// The word counts as in view while it's between these fractions of the visible height.
        private static let visibleBand = 0.04...0.92
        /// A mouse that moves further than this between press and release is dragging.
        private static let clickTolerance = 4.0

        private let model: ReaderModel
        private let locations: [WordLocation]
        private let wordIndex: DocumentWordIndex
        private weak var view: PDFView?
        private var shownWord: Int?
        private var wasFollowing = true
        /// A follow that couldn't happen yet because the view hadn't been given a size.
        private var isFollowPending = false
        private var clickMonitor: Any?
        private var pressPoint: CGPoint?
        private var isPressOnLink = false

        init(model: ReaderModel) {
            self.model = model
            locations = model.lecture.document?.locations ?? []
            wordIndex = DocumentWordIndex(locations: locations)
        }

        func attach(to view: PDFView) {
            self.view = view
            // Watches the mouse rather than adding a gesture recognizer, which PDFView's own
            // click handling keeps from firing. Events still reach the view afterward, so
            // dragging across text still selects it, except for clicks on links.
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                let isPress = event.type == .leftMouseDown
                let point = event.locationInWindow
                let windowNumber = event.windowNumber
                let clickCount = event.clickCount
                let isConsumed = MainActor.assumeIsolated {
                    self?.handleMouse(isPress: isPress, at: point, windowNumber: windowNumber, clickCount: clickCount) ?? false
                }
                return isConsumed ? nil : event
            }

            view.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(viewChangedSize),
                name: NSView.frameDidChangeNotification,
                object: view
            )
        }

        /// A new size changes the page's scale, which can move the word out of sight. This is
        /// also when a follow from before the view had a size, such as on resuming, can happen.
        /// The next turn of the run loop gives the PDF view time to rescale first.
        @objc private func viewChangedSize() {
            DispatchQueue.main.async { [weak self] in
                self?.followShownWord()
            }
        }

        private func followShownWord() {
            guard let view, let shownWord, wasFollowing, let target = selection(forWord: shownWord) else { return }
            follow(target.selection, on: target.page, in: view, force: isFollowPending)
        }

        func update(activeWord: Int?, isFollowing: Bool) {
            let wordChanged = activeWord != shownWord
            let followingResumed = isFollowing && !wasFollowing
            wasFollowing = isFollowing
            guard wordChanged || followingResumed else { return }
            shownWord = activeWord

            guard let view, let activeWord, let target = selection(forWord: activeWord) else {
                view?.highlightedSelections = nil
                return
            }
            target.selection.color = NSColor(Palette.bookmarkTick)
            view.highlightedSelections = [target.selection]

            if isFollowing {
                follow(target.selection, on: target.page, in: view, force: followingResumed)
            }
        }

        private func selection(forWord index: Int) -> (selection: PDFSelection, page: PDFPage)? {
            guard locations.indices.contains(index),
                  let page = view?.document?.page(at: locations[index].page)
            else { return nil }
            let selections = locations[index].ranges.compactMap { page.selection(for: $0.nsRange) }
            guard let selection = selections.first else { return nil }
            selections.dropFirst().forEach(selection.add)
            return (selection, page)
        }

        /// Moves the view only when the word has gone out of sight, so that the page holds
        /// still for reading rather than creeping along with every line.
        private func follow(_ selection: PDFSelection, on page: PDFPage, in view: PDFView, force: Bool) {
            guard view.bounds.height > 0, view.scaleFactor > 0, view.window != nil else {
                isFollowPending = true
                return
            }
            isFollowPending = false
            let bounds = selection.bounds(for: page)
            let onScreen = view.convert(bounds, from: page)
            // View coordinates run from the bottom up, so measure from the top.
            let fromTop = (view.bounds.maxY - onScreen.maxY) / view.bounds.height
            if !force, Self.visibleBand.contains(fromTop) { return }

            let visibleHeight = view.bounds.height / view.scaleFactor
            let top = bounds.maxY + visibleHeight * Self.followPosition
            view.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: top)))
        }

        func stopWatchingClicks() {
            if let clickMonitor {
                NSEvent.removeMonitor(clickMonitor)
            }
            clickMonitor = nil
        }

        /// A press and release in about the same place, with no drag between, is a click.
        /// Returns true for a click on a link, to keep it from PDFView. Academic papers link
        /// their citations, and here a click should read from that word, not open a browser
        /// or jump to the bibliography.
        private func handleMouse(isPress: Bool, at point: CGPoint, windowNumber: Int, clickCount: Int) -> Bool {
            guard let view, view.window?.windowNumber == windowNumber else { return false }
            let inView = view.convert(point, from: nil)

            if isPress {
                pressPoint = clickCount == 1 ? point : nil
                isPressOnLink = view.bounds.contains(inView) && isLink(at: inView, in: view)
                return isPressOnLink
            }

            let wasOnLink = isPressOnLink
            isPressOnLink = false
            defer { pressPoint = nil }
            if let pressPoint,
               hypot(point.x - pressPoint.x, point.y - pressPoint.y) <= Self.clickTolerance,
               view.bounds.contains(inView) {
                handleClick(at: inView, in: view)
            }
            return wasOnLink
        }

        private func isLink(at point: CGPoint, in view: PDFView) -> Bool {
            guard let page = view.page(for: point, nearest: false) else { return false }
            return page.annotation(at: view.convert(point, to: page))?.type == "Link"
        }

        /// Text that isn't spoken, such as a skipped header, and empty space do nothing.
        private func handleClick(at point: CGPoint, in view: PDFView) {
            guard let page = view.page(for: point, nearest: false),
                  let pageIndex = view.document?.index(for: page)
            else { return }
            let character = page.characterIndex(at: view.convert(point, to: page))
            if let word = wordIndex.wordIndex(page: pageIndex, character: character) {
                model.jump(toWord: word)
            }
        }
    }
}
