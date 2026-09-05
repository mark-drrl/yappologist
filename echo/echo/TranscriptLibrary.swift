import Foundation
import SwiftUI

/// A transcript saved to disk, with the metadata needed to reopen it and play
/// back the audio it came from.
struct SavedTranscript: Identifiable, Codable {
    var id = UUID()
    var filename: String
    var createdAt: Date
    /// Original audio file. Playback is skipped when it has been moved or deleted.
    var audioPath: String?
    var response: TranscriptionResponse

    var audioURL: URL? {
        guard let audioPath else { return nil }
        let url = URL(fileURLWithPath: audioPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Transcripts persisted under Application Support, one JSON file each.
///
/// Before this existed a finished transcript lived only in memory, so quitting the
/// app threw away the result of a job that may have taken minutes and cost money.
@MainActor
final class TranscriptLibrary: ObservableObject {
    static let shared = TranscriptLibrary()

    @Published private(set) var items: [SavedTranscript] = []

    private let directory: URL
    private var saveTasks: [UUID: Task<Void, Never>] = [:]

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = base
            .appendingPathComponent("The Yappologist", isDirectory: true)
            .appendingPathComponent("Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
    }

    // MARK: - Loading

    private func reload() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        items = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(SavedTranscript.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Mutation

    @discardableResult
    func add(filename: String, audioURL: URL?, response: TranscriptionResponse) -> SavedTranscript {
        let transcript = SavedTranscript(filename: filename,
                                         createdAt: Date(),
                                         audioPath: audioURL?.path,
                                         response: response)
        items.insert(transcript, at: 0)
        persist(transcript)
        return transcript
    }

    /// Called on every keystroke while editing, so the in-memory copy updates
    /// immediately but the disk write is debounced.
    func update(_ transcript: SavedTranscript) {
        guard let index = items.firstIndex(where: { $0.id == transcript.id }) else { return }
        items[index] = transcript

        saveTasks[transcript.id]?.cancel()
        saveTasks[transcript.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.persist(transcript)
            self?.saveTasks[transcript.id] = nil
        }
    }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    func binding(for id: UUID) -> Binding<SavedTranscript>? {
        guard items.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in
                self?.items.first { $0.id == id }
                    ?? SavedTranscript(filename: "",
                                       createdAt: Date(),
                                       audioPath: nil,
                                       response: TranscriptionResponse(text: "", durationMs: 0, utterances: []))
            },
            set: { [weak self] newValue in
                self?.update(newValue)
            }
        )
    }

    /// True when this exact file has already been transcribed, so the queue can
    /// avoid paying to do it twice.
    func existingTranscript(forAudioAt url: URL) -> SavedTranscript? {
        items.first { $0.audioPath == url.path }
    }

    // MARK: - Disk

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func persist(_ transcript: SavedTranscript) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(transcript) else { return }
        try? data.write(to: fileURL(for: transcript.id), options: .atomic)
    }
}
