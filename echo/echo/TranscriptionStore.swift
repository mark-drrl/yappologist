import Foundation
import SwiftUI
import AppKit
import UserNotifications

/// Tells her a job finished when she's looking at something else — at five hours
/// of audio a day, sitting and watching the queue isn't the workflow.
enum JobNotifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func finished(filename: String, succeeded: Bool) {
        guard !NSApp.isActive else { return }   // she's already watching

        let content = UNMutableNotificationContent()
        content.title = succeeded ? "Transcription finished" : "Transcription failed"
        content.body = filename
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

enum JobStatus {
    case queued
    case preparing(Double)
    case uploading(Double)
    case processing
    /// Carries the id of the saved transcript, not the transcript itself — the
    /// library owns it from here so edits survive quitting the app.
    case done(UUID)
    case failed(String)
    case cancelled

    var isFinished: Bool {
        switch self {
        case .done, .failed, .cancelled: return true
        default: return false
        }
    }

    var isRunning: Bool {
        switch self {
        case .preparing, .uploading, .processing: return true
        default: return false
        }
    }

    var transcriptID: UUID? {
        if case .done(let id) = self { return id }
        return nil
    }

    var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    var label: String {
        switch self {
        case .queued:            return "Waiting…"
        case .preparing:         return "Preparing audio…"
        case .uploading(let p):  return "Uploading… \(Int(p * 100))%"
        case .processing:        return "Transcribing…"
        case .done:              return "Done"
        case .failed:            return "Failed"
        case .cancelled:         return "Cancelled"
        }
    }

    /// Determinate progress, or nil when there is nothing meaningful to show.
    /// Preparing takes the first slice of the bar, uploading the rest; the server's
    /// own transcription time is unknowable, so that stage runs indeterminate.
    var fraction: Double? {
        switch self {
        case .queued:            return 0
        case .preparing(let p):  return p * 0.2
        case .uploading(let p):  return 0.2 + p * 0.8
        case .done:              return 1
        case .processing, .failed, .cancelled: return nil
        }
    }

    var icon: String {
        switch self {
        case .queued:     return "clock"
        case .preparing:  return "waveform"
        case .uploading:  return "arrow.up.circle"
        case .processing: return "sparkles"
        case .done:       return "checkmark.circle.fill"
        case .failed:     return "exclamationmark.triangle.fill"
        case .cancelled:  return "xmark.circle"
        }
    }
}

struct TranscriptionJob: Identifiable {
    let id = UUID()
    let url: URL
    let filename: String
    var status: JobStatus = .queued

    init(url: URL, status: JobStatus = .queued) {
        self.url = url
        self.filename = url.lastPathComponent
        self.status = status
    }
}

@MainActor
final class TranscriptionStore: ObservableObject {
    @Published private(set) var jobs: [TranscriptionJob] = []
    /// The transcript currently open for reading and editing, if any.
    @Published var openTranscriptID: UUID?

    /// One runner drains the queue serially — parallel uploads would fight for
    /// bandwidth and trip the API's concurrency limit.
    private var runner: Task<Void, Never>?
    private var activeJobID: TranscriptionJob.ID?
    private var activeWork: Task<TranscriptionResponse, Error>?

    private static let pendingKey = "pendingJobPaths"

    init() {
        JobNotifier.requestAuthorization()
        restorePending()
    }

    // MARK: - Persistence across launches

    /// Only status transitions call this — progress updates mutate the array
    /// directly, and writing on every frame of a progress bar would be absurd.
    private func savePending() {
        let paths = jobs.filter { !$0.status.isFinished }.map(\.url.path)
        UserDefaults.standard.set(paths, forKey: Self.pendingKey)
    }

    private func restorePending() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.pendingKey) ?? []
        let urls = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        enqueue(urls)
    }

    // MARK: - Derived state

    var hasFinishedJobs: Bool { jobs.contains { $0.status.isFinished } }

    var summary: String {
        guard !jobs.isEmpty else { return "" }
        let done = jobs.filter { $0.status.transcriptID != nil }.count
        let failed = jobs.filter { if case .failed = $0.status { return true }; return false }.count
        let pending = jobs.filter { !$0.status.isFinished }.count

        var parts: [String] = []
        if pending > 0 { parts.append("\(pending) in progress") }
        if done > 0 { parts.append("\(done) done") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Queue management

    func enqueue(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        let newJobs = urls.map { url -> TranscriptionJob in
            // Already transcribed: reuse it rather than paying to do it again.
            if let existing = TranscriptLibrary.shared.existingTranscript(forAudioAt: url) {
                return TranscriptionJob(url: url, status: .done(existing.id))
            }
            return TranscriptionJob(url: url)
        }

        jobs.append(contentsOf: newJobs)
        savePending()
        startRunner()
    }

    func retry(_ id: TranscriptionJob.ID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].status = .queued
        startRunner()
    }

    func cancel(_ id: TranscriptionJob.ID) {
        if activeJobID == id {
            activeWork?.cancel()
            return
        }
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if !jobs[index].status.isFinished { jobs[index].status = .cancelled }
    }

    func remove(_ id: TranscriptionJob.ID) {
        if activeJobID == id { activeWork?.cancel() }
        jobs.removeAll { $0.id == id }
        savePending()
    }

    func clearFinished() {
        jobs.removeAll { $0.status.isFinished }
        savePending()
    }

    // MARK: - Runner

    private func startRunner() {
        guard runner == nil else { return }   // an existing loop will pick up new jobs
        runner = Task { [weak self] in
            await self?.drainQueue()
        }
    }

    private func drainQueue() async {
        while let next = jobs.first(where: { if case .queued = $0.status { return true }; return false })?.id {
            await process(next)
        }
        runner = nil
    }

    private func process(_ id: TranscriptionJob.ID) async {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        let url = job.url
        let filename = job.filename

        activeJobID = id
        defer {
            activeJobID = nil
            activeWork = nil
        }

        setStatus(id, .preparing(0))

        // Task inherits the main actor here; the actual work hops to the preprocessor
        // and networking actors, so nothing heavy runs on the main thread.
        let work = Task { [weak self] () -> TranscriptionResponse in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let prepared = try await AudioPreprocessor.shared.prepare(url: url) { progress in
                Task { @MainActor in self?.setPrepareProgress(id, progress) }
            }
            let isTemporary = prepared != url
            defer { if isTemporary { try? FileManager.default.removeItem(at: prepared) } }

            try Task.checkCancellation()
            self?.setStatus(id, .uploading(0))

            return try await TranscribeClient.shared.transcribe(fileURL: prepared) { progress in
                Task { @MainActor in self?.setUploadProgress(id, progress) }
            }
        }
        activeWork = work

        do {
            let response = try await work.value
            let saved = TranscriptLibrary.shared.add(filename: filename,
                                                     audioURL: url,
                                                     response: response)
            setStatus(id, .done(saved.id))
            JobNotifier.finished(filename: filename, succeeded: true)
            // Open it automatically only for a lone file, matching the old
            // single-file flow. During a batch this would yank the user off the
            // queue mid-run.
            if jobs.count == 1 { openTranscriptID = saved.id }
        } catch is CancellationError {
            setStatus(id, .cancelled)
        } catch TranscribeError.cancelled {
            setStatus(id, .cancelled)
        } catch PreprocessorError.exportCancelled {
            setStatus(id, .cancelled)
        } catch {
            setStatus(id, .failed(error.localizedDescription))
            JobNotifier.finished(filename: filename, succeeded: false)
        }
    }

    // MARK: - Status updates

    private func setStatus(_ id: TranscriptionJob.ID, _ status: JobStatus) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].status = status
        savePending()
    }

    /// Every published change re-renders the queue, so sub-percent movement is
    /// dropped. Publishing each callback verbatim flooded the main actor badly
    /// enough that macOS marked the app as not responding.
    private static let progressStep = 0.01

    private func setPrepareProgress(_ id: TranscriptionJob.ID, _ progress: Double) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        // Callbacks can land out of order, so only ever move forward.
        if case .preparing(let current) = jobs[index].status,
           progress >= 1 || progress - current >= Self.progressStep {
            jobs[index].status = .preparing(progress)
        }
    }

    private func setUploadProgress(_ id: TranscriptionJob.ID, _ progress: Double) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[index].status {
        case .queued, .preparing:
            jobs[index].status = progress >= 1 ? .processing : .uploading(progress)
        case .uploading(let current):
            if progress >= 1 {
                jobs[index].status = .processing
            } else if progress - current >= Self.progressStep {
                jobs[index].status = .uploading(progress)
            }
        default:
            break   // late callback after the job already moved on
        }
    }
}
