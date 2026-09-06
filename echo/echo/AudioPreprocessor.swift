import Foundation
import AVFoundation

enum PreprocessorError: LocalizedError {
    case exportFailed(String)
    case exportCancelled
    case fileTooLarge
    case audioTooLong(Double)

    var errorDescription: String? {
        switch self {
        case .exportFailed(let msg):
            return "Audio export failed: \(msg)"
        case .exportCancelled:
            return "Audio export was cancelled."
        case .fileTooLarge:
            return "This file is over the 300 MB upload limit. Try splitting it into shorter parts."
        case .audioTooLong(let seconds):
            let hours = seconds / 3600
            return String(format: "This recording is %.1f hours long. Converted audio would exceed the 300 MB upload limit — split it into parts under 2.5 hours.", hours)
        }
    }
}

/// Formats the transcription API accepts directly, so no conversion is needed.
private let directFormats: Set<String> = ["mp3", "wav", "flac"]

/// Server-side upload cap.
private let maxUploadBytes = 300 * 1024 * 1024

/// 16 kHz, mono, 16-bit PCM. Speech recognition resamples to this internally, so
/// downsampling costs no accuracy and keeps converted files far smaller.
private let wavBytesPerSecond = 32_000

/// Tracks cancellation, throttles progress, and guarantees the continuation
/// resumes exactly once.
private final class ExportState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    private var lastReported: Double = -1

    /// Sample buffers arrive in their thousands per second. Reporting each one
    /// floods the main actor with view updates and macOS marks the app as not
    /// responding, so only meaningful movement is published.
    func shouldReport(_ progress: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard progress >= 1 || progress - lastReported >= 0.01 else { return false }
        lastReported = progress
        return true
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }

    /// Returns true for exactly one caller — whoever should resume the continuation.
    func claimFinish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }
}

actor AudioPreprocessor {
    static let shared = AudioPreprocessor()

    /// Returns the URL to upload — either the original file, or a converted WAV.
    /// `progressHandler` reports 0...1 during conversion; files that upload
    /// directly jump straight to 1.
    func prepare(url: URL,
                 progressHandler: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let ext = url.pathExtension.lowercased()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        guard size > 0 else {
            throw PreprocessorError.exportFailed("File is empty.")
        }

        if directFormats.contains(ext) {
            // Re-encoding an already-compressed file would only make it bigger,
            // so an oversized mp3 has to be split rather than converted.
            guard size <= maxUploadBytes else { throw PreprocessorError.fileTooLarge }
            progressHandler(1)
            return url
        }

        return try await exportWAV(from: url, progressHandler: progressHandler)
    }

    private func exportWAV(from url: URL,
                           progressHandler: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: url)

        let duration = try await asset.load(.duration)
        let totalSeconds = duration.seconds
        guard totalSeconds.isFinite, totalSeconds > 0 else {
            throw PreprocessorError.exportFailed("Could not read media duration.")
        }

        guard Int(totalSeconds * Double(wavBytesPerSecond)) <= maxUploadBytes else {
            throw PreprocessorError.audioTooLong(totalSeconds)
        }

        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw PreprocessorError.exportFailed("This file has no audio track.")
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)
        guard reader.canAdd(output) else {
            throw PreprocessorError.exportFailed("Could not read audio from this file.")
        }
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: outURL, fileType: .wav)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw PreprocessorError.exportFailed("Could not write converted audio.")
        }
        writer.add(input)

        guard writer.startWriting(), reader.startReading() else {
            let message = writer.error?.localizedDescription
                ?? reader.error?.localizedDescription
                ?? "Could not start conversion."
            throw PreprocessorError.exportFailed(message)
        }
        writer.startSession(atSourceTime: .zero)

        let state = ExportState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let queue = DispatchQueue(label: "com.echo.wav-export")
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData {
                        if state.isCancelled {
                            reader.cancelReading()
                            input.markAsFinished()
                            writer.cancelWriting()
                            if state.claimFinish() {
                                continuation.resume(throwing: PreprocessorError.exportCancelled)
                            }
                            return
                        }

                        guard let buffer = output.copyNextSampleBuffer() else {
                            // A failed reader also returns nil here. Without this
                            // check the writer would finish cleanly on a truncated
                            // file and we'd transcribe half a recording.
                            let readerFailed = reader.status == .failed
                            let readerError = reader.error

                            input.markAsFinished()
                            writer.finishWriting {
                                guard state.claimFinish() else { return }
                                if readerFailed {
                                    let message = readerError?.localizedDescription
                                        ?? "Could not read the whole recording."
                                    continuation.resume(throwing: PreprocessorError.exportFailed(message))
                                } else if writer.status == .completed {
                                    progressHandler(1)
                                    continuation.resume(returning: outURL)
                                } else {
                                    let message = writer.error?.localizedDescription
                                        ?? "Unknown conversion error"
                                    continuation.resume(throwing: PreprocessorError.exportFailed(message))
                                }
                            }
                            return
                        }

                        input.append(buffer)

                        let elapsed = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                        if elapsed.isFinite {
                            let fraction = min(max(elapsed / totalSeconds, 0), 1)
                            if state.shouldReport(fraction) {
                                progressHandler(fraction)
                            }
                        }
                    }
                }
            }
        } onCancel: {
            state.cancel()
        }
    }
}
