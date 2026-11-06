import PodcastReaderCore
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    let model: AppModel

    @State private var isChoosingFile = false
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            AuroraBackground()

            VStack(alignment: .leading, spacing: 28) {
                Text("Podcast Reader")
                    .font(.system(size: 44, weight: .heavy))
                    .tracking(-1.5)
                    .foregroundStyle(.white)

                importArea

                voiceArea

                if let notice = model.notice {
                    Text(notice)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.bookmarkTick)
                }

                recents
            }
            .padding(.horizontal, 48)
            .padding(.top, 48)
            .frame(maxWidth: 900, maxHeight: .infinity, alignment: .top)
        }
        .task { model.refresh() }
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: [.mp3, .mpeg4Audio, .wav, .pdf]
        ) { result in
            if case .success(let url) = result {
                model.importFile(url)
            }
        }
    }

    /// The voice menu, or the question or progress that's taken its place for now.
    @ViewBuilder
    private var voiceArea: some View {
        switch model.kokoroSetup {
        case .idle:
            voiceMenu
        case .confirmingRemoval:
            voicePrompt("Remove Kokoro? This frees about 1.3 GB. PDFs already prepared keep working.") {
                Button("Remove", role: .destructive) { model.removeKokoro() }
                Button("Cancel") { model.dismissKokoroSetup() }
            }
        case .confirming:
            voicePrompt("Set up Kokoro? This downloads about 1.3 GB once, and stays on this Mac.") {
                Button("Set up") { model.confirmKokoroSetup() }
                Button("Not now") { model.dismissKokoroSetup() }
            }
        case .installing(let fraction, _):
            HStack(spacing: 12) {
                Text("Setting up Kokoro. This can take a few minutes.")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                ProgressView(value: fraction)
                    .tint(Palette.upcoming)
                    .frame(maxWidth: 260)
                Button("Cancel") { model.cancelKokoroSetup() }
            }
        case .failed(let message, _):
            voicePrompt(message) {
                Button("Try again") { model.confirmKokoroSetup() }
                Button("Dismiss") { model.dismissKokoroSetup() }
            }
        }
    }

    private func voicePrompt<Buttons: View>(_ message: String, @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            HStack {
                buttons()
            }
        }
    }

    private var voiceMenu: some View {
        Menu {
            Section("Natural, slower to prepare") {
                ForEach(KokoroVoice.all) { voice in
                    voiceItem(voice.name, voice: .kokoro(voice))
                }
            }
            Section("Fast to prepare") {
                voiceItem(model.bestAppleVoiceName, voice: .apple)
            }
            if model.isKokoroInstalled {
                Divider()
                Button("Remove Kokoro…") { model.askToRemoveKokoro() }
            }
        } label: {
            Text("Voice for PDFs: \(model.readingVoiceName)")
                .font(.system(size: 15, weight: .semibold))
        }
        .fixedSize()
    }

    /// A menu item with a check mark on the current voice.
    private func voiceItem(_ title: String, voice: ReadingVoice) -> some View {
        Toggle(title, isOn: Binding(
            get: { model.readingVoice == voice },
            set: { _ in model.chooseVoice(voice) }
        ))
    }

    private var importArea: some View {
        VStack(spacing: 14) {
            switch model.importState {
            case .idle:
                dropPrompt
            case .working(let title, let phase, let isDocument):
                workingView(title: title, phase: phase, isDocument: isDocument)
            case .failed(let message, let retry):
                failedView(message: message, retry: retry)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 170)
        .background(.white.opacity(isDropTargeted ? 0.12 : 0.05), in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    Palette.upcoming.opacity(isDropTargeted ? 0.9 : 0.35),
                    style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])
                )
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let first = urls.first else { return false }
            model.importFile(first)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private var dropPrompt: some View {
        VStack(spacing: 14) {
            Text("Drop an audio file or PDF here")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
            Button("Choose file") { isChoosingFile = true }
                .controlSize(.large)
        }
    }

    private func workingView(title: String, phase: TranscriptionPhase?, isDocument: Bool) -> some View {
        VStack(spacing: 14) {
            Text(workingText(title: title, phase: phase, isDocument: isDocument))
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            ProgressView(value: workingFraction(phase))
                .tint(Palette.upcoming)
                .frame(maxWidth: 420)
            if let remaining = model.importRemainingText {
                Text(remaining)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.upcoming)
            }
            Button("Cancel") { model.cancelImport() }
        }
    }

    private func workingText(title: String, phase: TranscriptionPhase?, isDocument: Bool) -> String {
        if isDocument {
            return "Preparing \(title)…"
        }
        if case .downloadingModel = phase {
            return "Downloading the speech model…"
        }
        return "Transcribing \(title)…"
    }

    private func workingFraction(_ phase: TranscriptionPhase?) -> Double {
        switch phase {
        case .downloadingModel(let fraction), .transcribing(let fraction): fraction
        case nil: 0
        }
    }

    private func failedView(message: String, retry: URL?) -> some View {
        VStack(spacing: 14) {
            Text(message)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            HStack {
                if model.canRetryImport {
                    Button("Try again") { model.retryImport() }
                }
                Button("Dismiss") { model.dismissImportError() }
            }
        }
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent lectures")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.upcoming)

            if model.lectures.isEmpty {
                Text("Lectures you add will appear here.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.lectures) { lecture in
                            LectureRow(
                                lecture: lecture,
                                readAgainTitle: model.canReadAgain(lecture) ? "Read again with \(model.readingVoiceName)" : nil
                            ) {
                                model.open(lecture)
                            } onReadAgain: {
                                model.readAgain(lecture)
                            } onRemove: {
                                model.remove(lecture)
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct LectureRow: View {
    let lecture: Lecture
    let readAgainTitle: String?
    let onOpen: () -> Void
    let onReadAgain: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    private var progress: Double {
        guard lecture.duration > 0 else { return 0 }
        return min(max(lecture.position / lecture.duration, 0), 1)
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: lecture.document == nil ? "waveform" : "doc.text")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.upcoming)
                        .accessibilityLabel(lecture.document == nil ? "Audio" : "PDF")
                    Text(lecture.title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(TimeFormat.string(lecture.duration))
                        .font(.system(size: 14, weight: .medium).monospacedDigit())
                        .foregroundStyle(Palette.upcoming)
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.14))
                        Capsule().fill(Palette.upcoming).frame(width: geometry.size.width * progress)
                    }
                }
                .frame(height: 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.white.opacity(isHovering ? 0.1 : 0.05), in: .rect(cornerRadius: 12))
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            if let readAgainTitle {
                Button(readAgainTitle, action: onReadAgain)
            }
            Button("Remove from library", action: onRemove)
        }
    }
}
