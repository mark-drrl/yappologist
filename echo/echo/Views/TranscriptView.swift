import SwiftUI

private let speakerColors: [Color] = [
    Color(red: 0.38, green: 0.51, blue: 0.93),
    Color(red: 0.24, green: 0.74, blue: 0.65),
    Color(red: 0.92, green: 0.55, blue: 0.37),
    Color(red: 0.78, green: 0.40, blue: 0.82),
    Color(red: 0.95, green: 0.77, blue: 0.28),
]

private let playbackRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

struct TranscriptView: View {
    @Binding var transcript: SavedTranscript
    @EnvironmentObject var store: TranscriptionStore
    @EnvironmentObject var themeManager: ThemeManager

    @StateObject private var player = AudioPlayerController()
    @State private var searchText = ""
    @State private var autoScroll = true
    @FocusState private var searchFocused: Bool

    private var response: TranscriptionResponse { transcript.response }

    /// Source filename without its extension, so exports don't all land on "transcript".
    private var exportBaseName: String {
        (transcript.filename as NSString).deletingPathExtension
    }

    private var blocks: [SpeakerBlock] {
        let all = response.speakerBlocks
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    /// The block covering the playhead, used for highlighting and auto-scroll.
    private var currentBlockID: SpeakerBlock.ID? {
        guard player.isLoaded else { return nil }
        let now = player.currentTimeMs
        return response.speakerBlocks.last { $0.startMs <= now }?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            toolBar
            if response.speakerCount > 1 {
                Divider()
                speakerStatsBar
            }
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(blocks) { block in
                            SpeakerBlockView(block: block,
                                             isPlaying: block.id == currentBlockID,
                                             canPlay: player.isLoaded,
                                             text: { self.textBinding(for: $0) },
                                             onPlay: { player.play(fromMs: block.startMs) })
                            .id(block.id)
                        }

                        if blocks.isEmpty {
                            Text("No lines match \"\(searchText)\".")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .padding(.top, 40)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(20)
                }
                .onReceive(player.$currentTimeMs) { _ in
                    guard autoScroll, player.isPlaying, let id = currentBlockID else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }

            Divider()
            exportBar
        }
        .onAppear {
            if let url = transcript.audioURL { player.load(url) }
        }
        .onDisappear { player.teardown() }
        .background(hiddenShortcuts)
    }

    // MARK: - Bars

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(transcript.filename)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(response.speakerCount) speaker\(response.speakerCount == 1 ? "" : "s") · \(response.formattedDuration)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            EchoButton("Back", icon: "chevron.left") {
                store.openTranscriptID = nil
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var toolBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("Search transcript", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .frame(maxWidth: 240)

            Spacer()

            if player.isLoaded {
                Button {
                    player.isPlaying ? player.pause() : player.resume()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(themeManager.theme.accent)
                }
                .buttonStyle(.plain)
                .help(player.isPlaying ? "Pause (⌘P)" : "Play (⌘P)")

                Text(formatMs(player.currentTimeMs))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)

                Picker("", selection: $player.rate) {
                    ForEach(playbackRates, id: \.self) { rate in
                        Text(rate == 1.0 ? "1×" : "\(String(format: "%g", rate))×").tag(rate)
                    }
                }
                .labelsHidden()
                .frame(width: 70)
                .help("Playback speed")

                Toggle("Follow", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .help("Scroll along with playback")
            } else {
                Text("Audio unavailable")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .help("The original file has moved or been deleted")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var speakerStatsBar: some View {
        HStack(spacing: 14) {
            ForEach(response.speakerStats) { stat in
                HStack(spacing: 5) {
                    Circle()
                        .fill(speakerColors[(stat.displayNumber - 1) % speakerColors.count])
                        .frame(width: 7, height: 7)
                    Text("Speaker \(stat.displayNumber)")
                        .font(.system(size: 11, weight: .medium))
                    Text("\(formatMs(stat.durationMs)) · \(stat.wordCount) words")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private var exportBar: some View {
        HStack(spacing: 10) {
            ExportButton("Copy", icon: "doc.on.doc") {
                Exporters.copyText(response)
            }
            ExportButton("Word", icon: "doc.richtext") {
                Exporters.exportDocx(response, baseName: exportBaseName)
            }
            ExportButton("PDF", icon: "doc.fill") {
                Exporters.exportPDF(response, baseName: exportBaseName)
            }
            ExportButton(".txt", icon: "doc.text") {
                Exporters.exportTXT(response, baseName: exportBaseName)
            }
            Spacer()
            Text("Edits save automatically")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    /// Modifier-based shortcuts only. Bare space and arrow keys would fight with
    /// editing the transcript text, which is the point of the view.
    private var hiddenShortcuts: some View {
        Group {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
            Button("") {
                guard player.isLoaded else { return }
                player.isPlaying ? player.pause() : player.resume()
            }
            .keyboardShortcut("p", modifiers: .command)
            Button("") { step(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("") { step(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    // MARK: - Behaviour

    /// Jumps playback to the next or previous speaker block.
    private func step(by offset: Int) {
        let all = response.speakerBlocks
        guard player.isLoaded, !all.isEmpty else { return }
        let currentIndex = all.lastIndex { $0.startMs <= player.currentTimeMs } ?? 0
        let target = min(max(currentIndex + offset, 0), all.count - 1)
        player.play(fromMs: all[target].startMs)
    }

    /// Writes edits straight back through the library binding, which persists them.
    private func textBinding(for utterance: Utterance) -> Binding<String> {
        Binding(
            get: {
                transcript.response.utterances.first { $0.id == utterance.id }?.text ?? utterance.text
            },
            set: { newValue in
                guard let index = transcript.response.utterances.firstIndex(where: { $0.id == utterance.id }) else { return }
                transcript.response.utterances[index].text = newValue
            }
        )
    }
}

struct SpeakerBlockView: View {
    let block: SpeakerBlock
    let isPlaying: Bool
    let canPlay: Bool
    let text: (Utterance) -> Binding<String>
    let onPlay: () -> Void

    private var color: Color {
        speakerColors[(block.displayNumber - 1) % speakerColors.count]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Speaker \(block.displayNumber)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.12))
                    .clipShape(Capsule())

                Button {
                    onPlay()
                } label: {
                    HStack(spacing: 3) {
                        if canPlay {
                            Image(systemName: "play.fill").font(.system(size: 8))
                        }
                        Text(formatMs(block.startMs))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canPlay)
                .help(canPlay ? "Play from here" : "")

                if !block.language.isEmpty {
                    Text(block.language.lowercased())
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                ForEach(block.utterances) { utterance in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(formatMs(utterance.startMs))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 50, alignment: .leading)
                        TextField("", text: text(utterance), axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isPlaying ? color.opacity(0.7) : .clear, lineWidth: 2)
        )
    }
}

struct ExportButton: View {
    let label: String
    let icon: String
    let action: () -> Void

    init(_ label: String, icon: String, action: @escaping () -> Void) {
        self.label = label; self.icon = icon; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
