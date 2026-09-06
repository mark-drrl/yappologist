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
    @State private var replaceText = ""
    @State private var autoScroll = true
    @State private var editingID: UUID?
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

    /// Built once per render so each text field's binding is an O(1) lookup
    /// rather than a linear scan of every utterance.
    private var utteranceIndexByID: [UUID: Int] {
        var map: [UUID: Int] = [:]
        map.reserveCapacity(transcript.response.utterances.count)
        for (index, utterance) in transcript.response.utterances.enumerated() {
            map[utterance.id] = index
        }
        return map
    }

    /// The block covering the playhead, used for highlighting and auto-scroll.
    private var currentBlockID: SpeakerBlock.ID? {
        guard player.isLoaded else { return nil }
        let now = player.currentTimeMs
        return response.speakerBlocks.last { $0.startMs <= now }?.id
    }

    var body: some View {
        // Every one of these walks all the utterances. Referencing them inside the
        // ForEach re-ran them once per block, which is quadratic — a 200-phrase
        // transcript took long enough to open that it looked hung.
        let visibleBlocks = blocks
        let stats = response.speakerStats
        let playingID = currentBlockID
        let indexByID = utteranceIndexByID

        return VStack(spacing: 0) {
            statusBar
            Divider()
            toolBar
            if stats.count > 1 {
                Divider()
                speakerStatsBar(stats)
            }
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(visibleBlocks) { block in
                            SpeakerBlockView(block: block,
                                             isPlaying: block.id == playingID,
                                             canPlay: player.isLoaded,
                                             speakers: stats,
                                             editingID: editingID,
                                             text: { self.textBinding(for: $0, indexByID: indexByID) },
                                             onPlay: { player.play(fromMs: block.startMs) },
                                             onReassign: { reassign(block, to: $0) },
                                             onBeginEdit: { editingID = $0 })
                            .id(block.id)
                        }

                        if visibleBlocks.isEmpty {
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

            if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                TextField("Replace with", text: $replaceText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .frame(maxWidth: 160)

                Button("Replace all") { replaceAll() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

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

    private func speakerStatsBar(_ stats: [SpeakerStat]) -> some View {
        HStack(spacing: 14) {
            ForEach(stats) { stat in
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

    /// Replaces across every utterance in one binding write, rather than one per
    /// line, so the library persists a single change.
    private func replaceAll() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }

        var updated = transcript.response.utterances
        for index in updated.indices {
            updated[index].text = updated[index].text
                .replacingOccurrences(of: query, with: replaceText, options: [.caseInsensitive])
        }
        transcript.response.utterances = updated
    }

    /// Diarization gets attribution wrong sometimes; this moves a whole block to
    /// another speaker. Labels stay "Speaker 1", "Speaker 2" — only the grouping moves.
    private func reassign(_ block: SpeakerBlock, to speaker: Int) {
        let ids = Set(block.utterances.map(\.id))
        var updated = transcript.response.utterances
        for index in updated.indices where ids.contains(updated[index].id) {
            updated[index].speaker = speaker
        }
        transcript.response.utterances = updated
    }

    /// Writes edits straight back through the library binding, which persists them.
    private func textBinding(for utterance: Utterance, indexByID: [UUID: Int]) -> Binding<String> {
        Binding(
            get: {
                guard let index = indexByID[utterance.id],
                      index < transcript.response.utterances.count else { return utterance.text }
                return transcript.response.utterances[index].text
            },
            set: { newValue in
                guard let index = indexByID[utterance.id],
                      index < transcript.response.utterances.count else { return }
                transcript.response.utterances[index].text = newValue
            }
        )
    }
}

struct SpeakerBlockView: View {
    let block: SpeakerBlock
    let isPlaying: Bool
    let canPlay: Bool
    let speakers: [SpeakerStat]
    let editingID: UUID?
    let text: (Utterance) -> Binding<String>
    let onPlay: () -> Void
    let onReassign: (Int) -> Void
    let onBeginEdit: (UUID) -> Void

    @FocusState private var isEditing: Bool

    private var color: Color {
        speakerColors[(block.displayNumber - 1) % speakerColors.count]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Menu {
                    ForEach(speakers) { stat in
                        Button {
                            onReassign(stat.speaker)
                        } label: {
                            if stat.speaker == block.speaker {
                                Label("Speaker \(stat.displayNumber)", systemImage: "checkmark")
                            } else {
                                Text("Speaker \(stat.displayNumber)")
                            }
                        }
                    }
                    Divider()
                    Button("New speaker") {
                        onReassign((speakers.map(\.speaker).max() ?? 0) + 1)
                    }
                } label: {
                    Text("Speaker \(block.displayNumber)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(color.opacity(0.12))
                        .clipShape(Capsule())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Reassign this block to another speaker")

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

                        // A live TextField per line is far too expensive — a
                        // 200-phrase transcript spent seconds building them before
                        // anything appeared. Lines render as text and only become
                        // editable when clicked.
                        if utterance.id == editingID {
                            TextField("", text: text(utterance), axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(.system(size: 14))
                                .lineSpacing(4)
                                .focused($isEditing)
                                .onAppear { isEditing = true }
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(text(utterance).wrappedValue)
                                .font(.system(size: 14))
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { onBeginEdit(utterance.id) }
                        }
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
