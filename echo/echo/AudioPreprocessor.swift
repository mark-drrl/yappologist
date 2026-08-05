import Foundation
import AVFoundation

enum PreprocessorError: LocalizedError {
    case unsupportedFormat(String)
    case exportFailed(String)
    case exportCancelled

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "Unsupported format: .\(ext). Supported: mp3, wav, flac, aac, aiff, ogg, opus, mp4, mov, webm, m4a, mkv, avi, wmv."
        case .exportFailed(let msg):
            return "Audio export failed: \(msg)"
        case .exportCancelled:
            return "Audio export was cancelled."
        }
    }
}

private let directFormats: Set<String> = ["mp3","wav","flac","aac","aiff","ogg","opus","mp4","mov","webm"]
private let maxBytes: Int = 100 * 1024 * 1024  // 100 MB

actor AudioPreprocessor {
    static let shared = AudioPreprocessor()

    /// Returns the URL to upload (either the original or an exported .m4a).
    /// `progressHandler` reports 0...1 during conversion; files that upload directly
    /// jump straight to 1.
    func prepare(url: URL,
                 progressHandler: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let ext = url.pathExtension.lowercased()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        guard size > 0 else {
            throw PreprocessorError.exportFailed("File is empty.")
        }

        let needsConversion = !directFormats.contains(ext) || size > maxBytes

        if needsConversion {
            return try await exportAudio(from: url, progressHandler: progressHandler)
        }
        progressHandler(1)
        return url
    }

    private func exportAudio(from url: URL,
                             progressHandler: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: url)

        // Check asset is loadable
        let duration = try await asset.load(.duration)
        guard duration.seconds > 0 else {
            throw PreprocessorError.exportFailed("Could not read media duration.")
        }

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw PreprocessorError.exportFailed("Could not create export session.")
        }
        session.outputURL = tmpURL
        session.outputFileType = .m4a
        session.audioTimePitchAlgorithm = .spectral

        // AVAssetExportSession has no progress callback, so poll it while the export runs.
        let poller = Task {
            while !Task.isCancelled {
                progressHandler(Double(session.progress))
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        defer { poller.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                session.exportAsynchronously {
                    switch session.status {
                    case .completed:
                        progressHandler(1)
                        continuation.resume(returning: tmpURL)
                    case .cancelled:
                        continuation.resume(throwing: PreprocessorError.exportCancelled)
                    default:
                        let msg = session.error?.localizedDescription ?? "Unknown export error"
                        continuation.resume(throwing: PreprocessorError.exportFailed(msg))
                    }
                }
            }
        } onCancel: {
            session.cancelExport()
        }
    }
}
