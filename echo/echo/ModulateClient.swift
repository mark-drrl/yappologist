import Foundation

enum ModulateError: LocalizedError {
    case missingAPIKey
    case httpError(Int, String)
    case decodingError(Error)
    case networkError(Error)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key found. Open Settings (⌘,) to add your Modulate key."
        case .cancelled:
            return "Cancelled."
        case .httpError(let code, let detail):
            let extra = detail.isEmpty ? "" : "\n\n\(detail)"
            switch code {
            case 400, 415, 422:
                return "The server rejected this file (\(code)). It may be an unsupported format, corrupted, or contain no audio.\(extra)"
            case 401:
                return "Invalid or missing API key. Check your key in Settings."
            case 403:
                return "Your account doesn't have access to this model. Contact Modulate support."
            case 404:
                return "Transcription endpoint not found (404). The API may have moved.\(extra)"
            case 413:
                return "This file is too large for the server (413). Try splitting it into shorter parts.\(extra)"
            case 429:
                return "Rate limit reached. Please wait a moment and try again."
            case 500...599:
                return "The server hit an error (\(code)). This is on Modulate's side — retrying usually works.\(extra)"
            default:
                return "Unexpected server response (\(code)).\(extra)"
            }
        case .decodingError(let e):
            return "Couldn't read the server response: \(e.localizedDescription)"
        case .networkError(let e):
            return "Network error: \(e.localizedDescription)"
        }
    }
}

/// Reports upload progress for a single request.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        onProgress(min(max(fraction, 0), 1))
    }
}

actor ModulateClient {
    static let shared = ModulateClient()
    private let endpoint = URL(string: "https://modulate-developer-apis.com/api/velma-2-stt-batch")!

    /// `progressHandler` reports upload progress from 0 to 1. It reaches 1 when the
    /// file is fully sent — the server then transcribes, which reports no progress.
    func transcribe(fileURL: URL,
                    speakerDiarization: Bool = true,
                    emotionSignal: Bool = false,
                    progressHandler: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionResponse {

        guard let apiKey = KeychainHelper.load(), !apiKey.isEmpty else {
            throw ModulateError.missingAPIKey
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // The body is written to disk and streamed, so a 100 MB file never sits in memory
        // and URLSession can report an accurate Content-Length for the progress bar.
        let bodyURL = try writeMultipartBody(boundary: boundary,
                                             fileURL: fileURL,
                                             speakerDiarization: speakerDiarization,
                                             emotionSignal: emotionSignal)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let delegate = UploadProgressDelegate(onProgress: progressHandler)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.upload(for: request,
                                                                  fromFile: bodyURL,
                                                                  delegate: delegate)
        } catch let error as URLError where error.code == .cancelled {
            throw ModulateError.cancelled
        } catch is CancellationError {
            throw ModulateError.cancelled
        } catch {
            throw ModulateError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ModulateError.networkError(URLError(.badServerResponse))
        }

        guard http.statusCode == 200 else {
            throw ModulateError.httpError(http.statusCode, Self.explanation(from: data))
        }

        do {
            return try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        } catch {
            throw ModulateError.decodingError(error)
        }
    }

    // MARK: - Error parsing

    /// Pulls a human-readable reason out of an error response.
    ///
    /// This API is FastAPI-backed, so `detail` is a plain string for auth errors but an
    /// array of validation objects for 422s. Decoding it as `[String: String]` silently
    /// produced an empty message for every rejected file, which is why failures used to
    /// surface as a bare "Server error". Gateway errors aren't JSON at all.
    static func explanation(from data: Data) -> String {
        guard !data.isEmpty else { return "" }

        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = root["detail"] {
                if let text = detail as? String { return text }
                if let items = detail as? [[String: Any]] {
                    let messages = items.compactMap { item -> String? in
                        guard let msg = item["msg"] as? String else { return nil }
                        guard let loc = item["loc"] as? [Any], !loc.isEmpty else { return msg }
                        return "\(loc.map { "\($0)" }.joined(separator: ".")): \(msg)"
                    }
                    if !messages.isEmpty { return messages.joined(separator: "\n") }
                }
                return String(describing: detail)
            }
            if let message = root["message"] as? String { return message }
            if let error = root["error"] as? String { return error }
        }

        // Plain text or an HTML page from a proxy — show a trimmed snippet.
        let text = String(data: data.prefix(500), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.contains("<html") ? "" : text
    }

    // MARK: - Multipart

    private func writeMultipartBody(boundary: String,
                                    fileURL: URL,
                                    speakerDiarization: Bool,
                                    emotionSignal: Bool) throws -> URL {
        let crlf = "\r\n"
        let fileName = Self.headerSafeFileName(fileURL.lastPathComponent)
        let mime = mimeType(for: fileURL.pathExtension.lowercased())

        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).multipart")
        _ = FileManager.default.createFile(atPath: bodyURL.path, contents: nil)

        let out = try FileHandle(forWritingTo: bodyURL)
        defer { try? out.close() }

        func write(_ string: String) throws {
            try out.write(contentsOf: Data(string.utf8))
        }

        // upload_file
        try write("--\(boundary)\(crlf)")
        try write("Content-Disposition: form-data; name=\"upload_file\"; filename=\"\(fileName)\"\(crlf)")
        try write("Content-Type: \(mime)\(crlf)\(crlf)")

        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        try write(crlf)

        // speaker_diarization
        try write("--\(boundary)\(crlf)")
        try write("Content-Disposition: form-data; name=\"speaker_diarization\"\(crlf)\(crlf)")
        try write("\(speakerDiarization)\(crlf)")

        // emotion_signal
        try write("--\(boundary)\(crlf)")
        try write("Content-Disposition: form-data; name=\"emotion_signal\"\(crlf)\(crlf)")
        try write("\(emotionSignal)\(crlf)")

        try write("--\(boundary)--\(crlf)")
        return bodyURL
    }

    /// Content-Disposition headers are raw ASCII. A quote, backslash, newline or accented
    /// character in a filename corrupts the header and the server then reports the whole
    /// `upload_file` field as missing.
    static func headerSafeFileName(_ name: String) -> String {
        var cleaned = String(name.unicodeScalars.map { scalar -> Character in
            let isPrintableASCII = scalar.value >= 32 && scalar.value <= 126
            let isReserved = scalar == "\"" || scalar == "\\"
            return (isPrintableASCII && !isReserved) ? Character(scalar) : "_"
        })
        if cleaned.count > 120 {
            let ext = (cleaned as NSString).pathExtension
            cleaned = String(cleaned.prefix(100)) + (ext.isEmpty ? "" : ".\(ext)")
        }
        return cleaned.isEmpty ? "audio" : cleaned
    }

    private func mimeType(for ext: String) -> String {
        switch ext {
        case "mp3":  return "audio/mpeg"
        case "wav":  return "audio/wav"
        case "flac": return "audio/flac"
        case "aac":  return "audio/aac"
        case "aiff": return "audio/aiff"
        case "ogg":  return "audio/ogg"
        case "opus": return "audio/opus"
        case "mp4":  return "video/mp4"
        case "mov":  return "video/quicktime"
        case "webm": return "video/webm"
        case "m4a":  return "audio/mp4"
        default:     return "application/octet-stream"
        }
    }
}
