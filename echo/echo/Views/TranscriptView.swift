import SwiftUI

private let speakerColors: [Color] = [
    Color(red: 0.38, green: 0.51, blue: 0.93),
    Color(red: 0.24, green: 0.74, blue: 0.65),
    Color(red: 0.92, green: 0.55, blue: 0.37),
    Color(red: 0.78, green: 0.40, blue: 0.82),
    Color(red: 0.95, green: 0.77, blue: 0.28),
]

struct TranscriptView: View {
    let job: TranscriptionJob
    let response: TranscriptionResponse
    @EnvironmentObject var store: TranscriptionStore

    /// Source filename without its extension, so exports don't all land on "transcript".
    private var exportBaseName: String {
        (job.filename as NSString).deletingPathExtension
    }

    var body: some View {
        VStack(spacing: 0) {
            // Status bar
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.filename)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(response.speakerCount) speaker\(response.speakerCount == 1 ? "" : "s") · \(response.formattedDuration)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                EchoButton("Back to queue", icon: "list.bullet") {
                    store.selectedJobID = nil
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)

            Divider()

            // Transcript scroll
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(response.speakerBlocks) { block in
                        SpeakerBlockView(block: block)
                    }
                }
                .padding(20)
            }

            Divider()

            // Export bar
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
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial)
        }
    }
}

struct SpeakerBlockView: View {
    let block: SpeakerBlock

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

                Text(formatMs(block.startMs))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)

                Text(block.language.lowercased())
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            VStack(alignment: .leading, spacing: 9) {
                ForEach(block.utterances) { utterance in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(formatMs(utterance.startMs))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 50, alignment: .leading)
                        Text(utterance.text)
                            .font(.system(size: 14))
                            .foregroundColor(.primary)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
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
