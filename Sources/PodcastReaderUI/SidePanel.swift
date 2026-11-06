import PodcastReaderCore
import SwiftUI

/// Search and bookmarks. Sits beside the captions so they stay readable.
struct SidePanel: View {
    static let width = 340.0

    @Bindable var model: ReaderModel

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                tab("Search", .search)
                tab("Bookmarks", .bookmarks)
                Spacer()
                Button { model.closePanel() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close")
            }

            if model.panel == .search {
                searchContent
            } else {
                bookmarksContent
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 40)
        .padding(.bottom, 16)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.scrim.opacity(0.72))
        .ignoresSafeArea()
        .onChange(of: isSearchFocused) { model.isSearchFieldFocused = isSearchFocused }
        .onDisappear { model.isSearchFieldFocused = false }
    }

    private func tab(_ title: String, _ value: ReaderModel.PanelTab) -> some View {
        let isSelected = model.panel == value
        return Button { model.openPanel(value) } label: {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(isSelected ? Palette.navy : .white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.1)), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    private var searchContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search this lecture", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.white.opacity(0.1), in: .rect(cornerRadius: 10))
                .focused($isSearchFocused)
                .onAppear { isSearchFocused = true }
                .onChange(of: model.searchFocusRequest) { isSearchFocused = true }

            if model.matches.isEmpty {
                if !model.isSearching && !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    PanelNote("No matches")
                }
            } else {
                Text(model.matches.count == 1 ? "1 match" : "\(model.matches.count) matches")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.upcoming)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.matches) { match in
                            PanelRow(time: match.time, text: highlighted(match)) {
                                model.jump(toWord: match.wordRange.lowerBound)
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }

    private func highlighted(_ match: SearchMatch) -> AttributedString {
        let words = model.lecture.transcript.words
        var text = AttributedString()
        for index in match.contextRange {
            var word = AttributedString(words[index].text + " ")
            word.foregroundColor = match.wordRange.contains(index) ? .white : Palette.upcoming
            text.append(word)
        }
        return text
    }

    private var bookmarksContent: some View {
        Group {
            if model.lecture.bookmarks.isEmpty {
                PanelNote("Press B to bookmark a moment")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.lecture.bookmarks) { bookmark in
                            bookmarkRow(bookmark)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }

    private func bookmarkRow(_ bookmark: Bookmark) -> some View {
        var text = AttributedString(bookmark.text)
        text.foregroundColor = .white
        return HStack(alignment: .top, spacing: 2) {
            PanelRow(time: bookmark.time, text: text) {
                model.jump(toWord: bookmark.wordIndex)
            }
            Button { model.removeBookmark(id: bookmark.id) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.upcoming)
                    .frame(width: 30, height: 34)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Delete bookmark")
            .accessibilityLabel("Delete bookmark at \(TimeFormat.string(bookmark.time))")
        }
    }
}

private struct PanelNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(.white.opacity(0.75))
    }
}

private struct PanelRow: View {
    let time: TimeInterval
    let text: AttributedString
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(TimeFormat.string(time))
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(Palette.bookmarkTick)
                Text(text)
                    .font(.system(size: 14, weight: .medium))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.white.opacity(isHovering ? 0.1 : 0), in: .rect(cornerRadius: 10))
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
