import Foundation

enum TranscribeError: LocalizedError {
    case missingAPIKey
    case missingResourceName
    case httpError(Int, String)
    case decodingError(Error)
    case networkError(Error)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key found. Open Settings (⌘,) to add your Azure Speech key."
        case .missingResourceName:
            return "No Azure resource name set. Open Settings (⌘,) and add it."
        case .cancelled:
            return "Cancelled."
        case .httpError(let code, let detail):
            let extra = detail.isEmpty ? "" : "\n\n\(detail)"
            switch code {
            case 400, 415:
                return "The server rejected this file (\(code)). It may be corrupted or contain no audio.\(extra)"
            case 401:
                return "Invalid API key. Check your key in Settings, and that it belongs to the resource named there."
            case 403:
                return "Access denied. Your Azure subscription may be disabled — check whether free credits have expired.\(extra)"
            case 404:
                return "Endpoint not found (404). Check the resource name in Settings.\(extra)"
            case 413:
                return "This file is too large for the server (413). Try splitting it into shorter parts.\(extra)"
            case 429:
                return "Rate limit reached. Please wait a moment and try again."
            case 500...599:
                return "The server hit an error (\(code)). This is on Microsoft's side — retrying usually works.\(extra)"
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

/// Azure Speech "fast transcription" using the MAI-Transcribe-2 model.
///
/// The endpoint is synchronous — the whole transcript arrives in one response and
/// there is no job to poll. The model runs at roughly 410x real time, so the upload
/// is where the waiting actually happens; that is what `progressHandler` reports.
actor TranscribeClient {
    static let shared = TranscribeClient()

    private let apiVersion = "2025-10-15"
    private let model = "MAI-Transcribe-2"

    /// Below this, a phrase is too short for language identification to be reliable.
    private let shortPhraseMs = 1500

    func transcribe(fileURL: URL,
                    progressHandler: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionResponse {

        guard let apiKey = KeychainHelper.load(), !apiKey.isEmpty else {
            throw TranscribeError.missingAPIKey
        }
        let resource = AzureSettings.resourceName.trimmingCharacters(in: .whitespaces)
        guard !resource.isEmpty,
              let endpoint = URL(string: "https://\(resource).cognitiveservices.azure.com/speechtotext/transcriptions:transcribe?api-version=\(apiVersion)") else {
            throw TranscribeError.missingResourceName
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // The body is written to disk and streamed, so a large file never sits in
        // memory and URLSession can report an accurate Content-Length for progress.
        let bodyURL = try writeMultipartBody(boundary: boundary, fileURL: fileURL)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let delegate = UploadProgressDelegate(onProgress: progressHandler)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.upload(for: request,
                                                                  fromFile: bodyURL,
                                                                  delegate: delegate)
        } catch let error as URLError where error.code == .cancelled {
            throw TranscribeError.cancelled
        } catch is CancellationError {
            throw TranscribeError.cancelled
        } catch {
            throw TranscribeError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranscribeError.networkError(URLError(.badServerResponse))
        }

        guard http.statusCode == 200 else {
            throw TranscribeError.httpError(http.statusCode, Self.explanation(from: data))
        }

        do {
            let payload = try JSONDecoder().decode(AzurePayload.self, from: data)
            return makeResponse(from: payload)
        } catch {
            throw TranscribeError.decodingError(error)
        }
    }

    // MARK: - Response mapping

    /// Azure's fast-transcription response body.
    private struct AzurePayload: Decodable {
        let durationMilliseconds: Int
        let combinedPhrases: [Combined]
        let phrases: [Phrase]

        struct Combined: Decodable {
            let text: String
        }

        struct Phrase: Decodable {
            let speaker: Int?
            let offsetMilliseconds: Int
            let durationMilliseconds: Int
            let text: String
            let locale: String?
        }
    }

    private func makeResponse(from payload: AzurePayload) -> TranscriptionResponse {
        let utterances = repairShortPhraseLanguages(
            payload.phrases.map { phrase in
                Utterance(text: CorrectionSettings.apply(to: phrase.text),
                          startMs: phrase.offsetMilliseconds,
                          durationMs: phrase.durationMilliseconds,
                          speaker: phrase.speaker ?? 0,
                          language: phrase.locale ?? "")
            }
        )

        let combined = CorrectionSettings.apply(
            to: payload.combinedPhrases.map(\.text).joined(separator: "\n")
        )
        return TranscriptionResponse(text: combined,
                                     durationMs: payload.durationMilliseconds,
                                     utterances: utterances)
    }

    /// Language identification is unreliable on very short phrases — a 420 ms
    /// "In Tagalog." came back tagged German. Short phrases inherit the language
    /// of the nearest phrase long enough to trust.
    private func repairShortPhraseLanguages(_ utterances: [Utterance]) -> [Utterance] {
        let trusted = utterances.indices.filter { utterances[$0].durationMs >= shortPhraseMs }
        guard let first = trusted.first else { return utterances }

        return utterances.enumerated().map { index, utterance in
            guard utterance.durationMs < shortPhraseMs else { return utterance }
            let nearest = trusted.min(by: { abs($0 - index) < abs($1 - index) }) ?? first
            return Utterance(text: utterance.text,
                             startMs: utterance.startMs,
                             durationMs: utterance.durationMs,
                             speaker: utterance.speaker,
                             language: utterances[nearest].language)
        }
    }

    // MARK: - Error parsing

    /// Azure returns `{"error":{"code":"401","message":"..."}}`, while gateways and
    /// proxies return something else entirely. Fall back to a raw snippet rather than
    /// swallowing the reason — that is how the previous client hid every failure
    /// behind a bare "Server error".
    static func explanation(from data: Data) -> String {
        guard !data.isEmpty else { return "" }

        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = root["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            if let message = root["message"] as? String { return message }
            if let detail = root["detail"] as? String { return detail }
        }

        let text = String(data: data.prefix(500), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.contains("<html") ? "" : text
    }

    // MARK: - Multipart

    private func writeMultipartBody(boundary: String, fileURL: URL) throws -> URL {
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

        // audio
        try write("--\(boundary)\(crlf)")
        try write("Content-Disposition: form-data; name=\"audio\"; filename=\"\(fileName)\"\(crlf)")
        try write("Content-Type: \(mime)\(crlf)\(crlf)")

        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        try write(crlf)

        // definition
        try write("--\(boundary)\(crlf)")
        try write("Content-Disposition: form-data; name=\"definition\"\(crlf)")
        try write("Content-Type: application/json\(crlf)\(crlf)")
        try write("\(definitionJSON())\(crlf)")

        try write("--\(boundary)--\(crlf)")
        return bodyURL
    }

    private func definitionJSON() -> String {
        var definition: [String: Any] = [
            "enhancedMode": ["enabled": true, "model": model],
            "diarization": ["enabled": true],
            "modelOptions": [
                "timestamps": "segment",
                "transcribeStyle": AzureSettings.cleanTranscript ? "clean" : "verbatim",
            ],
        ]

        // Biasing toward known names and jargon is the cheapest accuracy win
        // available — proper nouns are where recognition fails hardest.
        let phrases = AzureSettings.vocabularyPhrases
        if !phrases.isEmpty {
            definition["phraseList"] = ["phrases": phrases]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: definition),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"enhancedMode\":{\"enabled\":true,\"model\":\"\(model)\"},\"diarization\":{\"enabled\":true}}"
        }
        return json
    }

    /// Content-Disposition headers are raw ASCII. A quote, backslash or accented
    /// character corrupts the header, and the server then reports the file field as
    /// missing entirely.
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
        default:     return "application/octet-stream"
        }
    }
}
