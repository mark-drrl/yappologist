import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: TranscriptionStore
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var library: TranscriptLibrary

    @State private var showHistory = false

    var body: some View {
        Group {
            if !themeManager.hasOnboarded {
                OnboardingView()
            } else {
                mainApp
            }
        }
    }

    private var mainApp: some View {
        ZStack {
            ThemeBackground(theme: themeManager.theme)

            if let id = store.openTranscriptID, let binding = library.binding(for: id) {
                VStack(spacing: 0) {
                    header
                    TranscriptView(transcript: binding)
                }
            } else if showHistory {
                VStack(spacing: 0) {
                    header
                    HistoryView(onClose: { showHistory = false })
                }
            } else if store.jobs.isEmpty {
                VStack(spacing: 0) {
                    header
                    VStack(spacing: 16) {
                        Text(themeManager.greeting)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                        DropZoneView()
                        Text("by Dih (Darrel aka Marga's Wife)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(24)
                }
            } else {
                VStack(spacing: 0) {
                    header
                    QueueView()
                }
            }
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .foregroundColor(themeManager.theme.accent)
                Text("The Yappologist")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
            }
            Spacer()

            // Closing a transcript returns to wherever it was opened from —
            // clearing showHistory here dumped her in the queue instead.
            if store.openTranscriptID != nil {
                EchoButton(showHistory ? "History" : "Queue",
                           icon: showHistory ? "clock.arrow.circlepath" : "list.bullet") {
                    store.openTranscriptID = nil
                }
                .controlSize(.small)
            } else if !library.items.isEmpty {
                EchoButton(showHistory ? "Queue" : "History", icon: showHistory ? "list.bullet" : "clock.arrow.circlepath") {
                    showHistory.toggle()
                }
                .controlSize(.small)
            }

            // Theme switcher
            Menu {
                ForEach(AppTheme.allCases) { theme in
                    Button {
                        withAnimation(.easeInOut) { themeManager.theme = theme }
                    } label: {
                        if themeManager.theme == theme {
                            Label(theme.label, systemImage: "checkmark")
                        } else {
                            Text(theme.label)
                        }
                    }
                }
            } label: {
                Image(systemName: themeManager.theme.icon)
                    .font(.system(size: 14))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help("Theme")

            SettingsButton {
                Image(systemName: "gear")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .help("Settings")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}

// MARK: - History

struct HistoryView: View {
    let onClose: () -> Void

    @EnvironmentObject var store: TranscriptionStore
    @EnvironmentObject var library: TranscriptLibrary

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df
    }()

    private var totalHours: Double {
        library.items.reduce(0) { $0 + Double($1.response.durationMs) / 3_600_000 }
    }

    /// Billing runs monthly, so this is the number that matters day to day —
    /// lifetime spend keeps growing and stops meaning anything.
    private var hoursThisMonth: Double {
        let calendar = Calendar.current
        return library.items
            .filter { calendar.isDate($0.createdAt, equalTo: Date(), toGranularity: .month) }
            .reduce(0) { $0 + Double($1.response.durationMs) / 3_600_000 }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(library.items.count) saved transcript\(library.items.count == 1 ? "" : "s")")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                Text("·")
                    .foregroundColor(.secondary)
                Text(String(format: "this month %.1f h · ~$%.2f", hoursThisMonth, hoursThisMonth * transcriptionCostPerHour))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Text(String(format: "(all time %.1f h · ~$%.2f)", totalHours, totalHours * transcriptionCostPerHour))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.7))
                    .help("Estimated at $\(String(format: "%.2f", transcriptionCostPerHour))/hour of audio. The Azure portal is the authority on actual billing and remaining credit.")
                Spacer()
                EchoButton("Export all", icon: "square.and.arrow.down") {
                    Exporters.exportAll(library.items)
                }
                .controlSize(.small)
                EchoButton("Back", icon: "chevron.left") {
                    onClose()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)

            Divider()

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(library.items) { item in
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.filename)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("\(Self.dateFormatter.string(from: item.createdAt)) · \(item.response.speakerCount) speaker\(item.response.speakerCount == 1 ? "" : "s") · \(item.response.formattedDuration)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            EchoButton("Open", icon: "doc.text") {
                                store.openTranscriptID = item.id
                            }
                            .controlSize(.small)

                            Button {
                                library.delete(item.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Delete transcript")
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
                        )
                    }
                }
                .padding(20)
            }
        }
    }
}

// MARK: - Queue

struct QueueView: View {
    @EnvironmentObject var store: TranscriptionStore
    @EnvironmentObject var themeManager: ThemeManager
    @State private var isTargeted = false
    @State private var showFilePicker = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(store.summary)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                EchoButton("Add files", icon: "plus") {
                    showFilePicker = true
                }
                .controlSize(.small)
                if store.hasFinishedJobs {
                    EchoButton("Clear finished", icon: "xmark") {
                        store.clearFinished()
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)

            Divider()

            if store.jobs.contains(where: { $0.status.isRunning }) {
                WaveformLoadingView()
                    .padding(.top, 12)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.jobs) { job in
                        JobRow(job: job)
                    }
                }
                .padding(20)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(themeManager.theme.accent, lineWidth: isTargeted ? 2.5 : 0)
                    .padding(8)
                    .animation(.easeInOut(duration: 0.15), value: isTargeted)
            )
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            enqueueDroppedFiles(providers, into: store)
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: acceptedMediaTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                store.enqueue(urls)
            }
        }
    }
}

struct JobRow: View {
    let job: TranscriptionJob
    @EnvironmentObject var store: TranscriptionStore
    @EnvironmentObject var themeManager: ThemeManager

    private var statusColor: Color {
        switch job.status {
        case .done:      return .green
        case .failed:    return .orange
        case .cancelled: return .secondary
        default:         return themeManager.theme.accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: job.status.icon)
                    .font(.system(size: 14))
                    .foregroundColor(statusColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(job.filename)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(job.status.label)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                actions
            }

            if !job.status.isFinished {
                progressBar
            }

            if let message = job.status.errorMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        )
    }

    @ViewBuilder
    private var progressBar: some View {
        if let fraction = job.status.fraction {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(statusColor)
        } else {
            // The server gives no signal while it transcribes, so this stage is
            // honest about being indeterminate rather than faking a percentage.
            ProgressView()
                .progressViewStyle(.linear)
                .tint(statusColor)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let transcriptID = job.status.transcriptID {
            EchoButton("View", icon: "doc.text") {
                store.openTranscriptID = transcriptID
            }
            .controlSize(.small)
        } else {
            switch job.status {
            case .failed, .cancelled:
                HStack(spacing: 8) {
                    EchoButton("Retry", icon: "arrow.counterclockwise") {
                        store.retry(job.id)
                    }
                    .controlSize(.small)
                    removeButton
                }
            case .queued:
                removeButton
            default:
                Button {
                    store.cancel(job.id)
                } label: {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel")
            }
        }
    }

    private var removeButton: some View {
        Button {
            store.remove(job.id)
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help("Remove")
    }
}

// MARK: - Settings

/// Opens the Settings scene. Uses SettingsLink on macOS 14+, falls back to the
/// legacy selector on macOS 13.
struct SettingsButton<Label: View>: View {
    @ViewBuilder var label: () -> Label

    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink(label: label)
                .buttonStyle(.plain)
        } else {
            Button(action: {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }, label: label)
            .buttonStyle(.plain)
        }
    }
}
