import Foundation
import AVFoundation

enum PreprocessorError: LocalizedError {
    case exportFailed(String)
    case exportCancelled
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .exportFailed(let msg):
            return "Audio export failed: \(msg)"
        case .exportCancelled:
            return "Audio export was cancelled."
        case .fileTooLarge:
            return "This file is over the 300 MB upload limit. Try splitting it into shorter parts."
        }
    }
}

/// One piece of audio ready to send, with where it sits in the original recording.
struct PreparedSegment {
    let url: URL
    /// Offset into the original recording, so timestamps can be put back together.
    let startMs: Int
    let isTemporary: Bool
}

/// Formats the transcription API accepts directly, so no conversion is needed.
private let directFormats: Set<String> = ["mp3", "wav", "flac"]

/// Server-side upload cap.
private let maxUploadBytes = 300 * 1024 * 1024

/// Azure's fast-transcription endpoint fails on long recordings regardless of file
/// size — measured working at 30 minutes and failing at 35, with a 40 minute FLAC
/// half the size of a passing WAV still rejected. Twenty minutes leaves margin.
private let maxSegmentSeconds: Double = 20 * 60

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

    /// Returns the pieces to upload. Short files in an accepted format pass through
    /// untouched as a single segment; anything else is converted, and anything long
    /// is also split.
    func prepare(url: URL,
                 progressHandler: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [PreparedSegment] {
        let ext = url.pathExtension.lowercased()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        guard size > 0 else {
            throw PreprocessorError.exportFailed("File is empty.")
        }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let totalSeconds = duration.seconds

        // Short and already acceptable: send it as it is.
        if directFormats.contains(ext),
           size <= maxUploadBytes,
           totalSeconds.isFinite,
           totalSeconds <= maxSegmentSeconds {
            progressHandler(1)
            return [PreparedSegment(url: url, startMs: 0, isTemporary: false)]
        }

        guard totalSeconds.isFinite, totalSeconds > 0 else {
            throw PreprocessorError.exportFailed("Could not read media duration.")
        }
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw PreprocessorError.exportFailed("This file has no audio track.")
        }

        let segmentCount = max(Int(ceil(totalSeconds / maxSegmentSeconds)), 1)
        let segmentSeconds = totalSeconds / Double(segmentCount)

        if segmentCount > 1 {
            DiagnosticLog.write("splitting \(Int(totalSeconds / 60)) min into \(segmentCount) parts — the endpoint rejects long recordings")
        }

        var segments: [PreparedSegment] = []
        for index in 0..<segmentCount {
            try Task.checkCancellation()

            let start = Double(index) * segmentSeconds
            let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                    duration: CMTime(seconds: segmentSeconds, preferredTimescale: 600))

            let url = try await exportWAV(asset: asset, track: track, range: range) { fraction in
                // Spread each segment's progress across the whole job.
                let overall = (Double(index) + fraction) / Double(segmentCount)
                progressHandler(min(max(overall, 0), 1))
            }
            segments.append(PreparedSegment(url: url,
                                            startMs: Int(start * 1000),
                                            isTemporary: true))
        }

        progressHandler(1)
        return segments
    }

    private func exportWAV(asset: AVURLAsset,
                           track: AVAssetTrack,
                           range: CMTimeRange,
                           progressHandler: @escaping @Sendable (Double) -> Void) async throws -> URL {
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
        reader.timeRange = range
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
        let rangeStart = range.start.seconds
        let rangeSeconds = max(range.duration.seconds, 0.001)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let queue = DispatchQueue(label: "com.echo.wav-export")
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData {
                        // copyNextSampleBuffer returns autoreleased buffers; without a
                        // pool per iteration they pile up for the whole loop.
                        var stop = false
                        autoreleasepool {
                            if state.isCancelled {
                                reader.cancelReading()
                                input.markAsFinished()
                                writer.cancelWriting()
                                if state.claimFinish() {
                                    continuation.resume(throwing: PreprocessorError.exportCancelled)
                                }
                                stop = true
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
                                stop = true
                                return
                            }

                            input.append(buffer)

                            let elapsed = CMSampleBufferGetPresentationTimeStamp(buffer).seconds - rangeStart
                            if elapsed.isFinite {
                                let fraction = min(max(elapsed / rangeSeconds, 0), 1)
                                if state.shouldReport(fraction) {
                                    progressHandler(fraction)
                                }
                            }
                        }

                        if stop { return }
                    }
                }
            }
        } onCancel: {
            state.cancel()
        }
    }
}
