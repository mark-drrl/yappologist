import Foundation

struct TranscriptionResponse: Codable {
    let text: String
    let durationMs: Int
    let utterances: [Utterance]
    enum CodingKeys: String, CodingKey {
        case text
        case durationMs = "duration_ms"
        case utterances
    }
}

struct Utterance: Codable, Identifiable {
    let id: UUID
    let text: String
    let startMs: Int
    let durationMs: Int
    let speaker: Int
    let language: String
    let emotion: String?
    let accent: String?
    enum CodingKeys: String, CodingKey {
        case id = "utterance_uuid"
        case text
        case startMs = "start_ms"
        case durationMs = "duration_ms"
        case speaker, language, emotion, accent
    }
}

/// Groups of consecutive same-speaker utterances
struct SpeakerBlock: Identifiable {
    let id = UUID()
    let speaker: Int          // raw speaker id from the API
    let displayNumber: Int    // 1-based, by order of first appearance
    let language: String
    let startMs: Int
    let utterances: [Utterance]
    var text: String { utterances.map(\.text).joined(separator: " ") }
}

extension TranscriptionResponse {
    var speakerBlocks: [SpeakerBlock] {
        var numbering: [Int: Int] = [:]
        var nextNumber = 1
        func displayNumber(for speaker: Int) -> Int {
            if let n = numbering[speaker] { return n }
            let n = nextNumber
            numbering[speaker] = n
            nextNumber += 1
            return n
        }

        var blocks: [SpeakerBlock] = []
        var run: [Utterance] = []

        func flush() {
            guard let first = run.first else { return }
            blocks.append(SpeakerBlock(speaker: first.speaker,
                                       displayNumber: displayNumber(for: first.speaker),
                                       language: first.language,
                                       startMs: first.startMs,
                                       utterances: run))
        }

        for u in utterances {
            if let last = run.last, last.speaker == u.speaker {
                run.append(u)
            } else {
                flush()
                run = [u]
            }
        }
        flush()
        return blocks
    }

    var speakerCount: Int { Set(utterances.map(\.speaker)).count }

    var formattedDuration: String {
        let total = durationMs / 1000
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

func formatMs(_ ms: Int) -> String {
    let total = ms / 1000
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}
