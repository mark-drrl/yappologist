import SwiftUI
import UniformTypeIdentifiers

let acceptedMediaTypes: [UTType] = [
    .audio, .movie, .mpeg4Audio,
    UTType(filenameExtension: "flac") ?? .audio,
    UTType(filenameExtension: "ogg") ?? .audio,
    UTType(filenameExtension: "opus") ?? .audio,
    UTType(filenameExtension: "webm") ?? .movie,
    UTType(filenameExtension: "mkv") ?? .movie,
    UTType(filenameExtension: "avi") ?? .movie,
]

/// Collects URLs from concurrent drop callbacks so they can be queued in the order dropped.
private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [Int: URL] = [:]

    func set(_ url: URL, at index: Int) {
        lock.lock(); defer { lock.unlock() }
        urls[index] = url
    }

    var ordered: [URL] {
        lock.lock(); defer { lock.unlock() }
        return urls.keys.sorted().compactMap { urls[$0] }
    }
}

/// Shared by the drop zone and the queue screen so files can be dropped onto either.
func enqueueDroppedFiles(_ providers: [NSItemProvider], into store: TranscriptionStore) -> Bool {
    guard !providers.isEmpty else { return false }

    let collector = URLCollector()
    let group = DispatchGroup()

    for (index, provider) in providers.enumerated() {
        group.enter()
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            defer { group.leave() }
            guard let data,
                  let urlString = String(data: data, encoding: .utf8),
                  let url = URL(string: urlString) else { return }
            collector.set(url, at: index)
        }
    }

    group.notify(queue: .main) {
        let urls = collector.ordered
        guard !urls.isEmpty else { return }
        Task { @MainActor in store.enqueue(urls) }
    }
    return true
}

struct DropZoneView: View {
    @EnvironmentObject var store: TranscriptionStore
    @EnvironmentObject var themeManager: ThemeManager
    @State private var isTargeted = false
    @State private var showFilePicker = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(
                            isTargeted ? themeManager.theme.accent : Color.secondary.opacity(0.35),
                            style: StrokeStyle(lineWidth: isTargeted ? 2.5 : 1.5, dash: [8, 5])
                        )
                )
                .shadow(color: isTargeted ? themeManager.theme.accent.opacity(0.25) : .clear, radius: 16)
                .scaleEffect(isTargeted ? 1.015 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isTargeted)

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(themeManager.theme.accent.opacity(0.12))
                        .frame(width: 80, height: 80)
                    Image(systemName: isTargeted ? "waveform" : "music.note")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundColor(themeManager.theme.accent)
                        .scaleEffect(isTargeted ? 1.15 : 1.0)
                        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isTargeted)
                }

                VStack(spacing: 6) {
                    Text("Drop audio or video here")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text("One file or many — they'll transcribe one after another")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("mp3 · wav · mp4 · mov · flac · aac · ogg · opus · webm")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.7))
                }

                EchoButton("Choose files", icon: "folder") {
                    showFilePicker = true
                }
                .controlSize(.large)
            }
            .padding(40)
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
