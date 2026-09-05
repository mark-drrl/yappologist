import Foundation

/// A finished transcript, normalized away from any one provider's response shape.
/// Codable here is for saving to disk, not for decoding an API — the client maps
/// provider responses into this shape by hand.
struct TranscriptionResponse: Codable {
    var text: String
    let durationMs: Int
    var utterances: [Utterance]
}

struct Utterance: Identifiable, Codable {
    var id = UUID()
    /// Editable — no engine transcribes Taglish perfectly, so corrections land here.
    var text: String
    let startMs: Int
    let durationMs: Int
    var speaker: Int
    var language: String
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

/// Azure's published rate for MAI-Transcribe-2 batch transcription. Used only for
/// the running estimate in History — the Azure portal is the authority on billing.
let transcriptionCostPerHour = 0.10

struct SpeakerStat: Identifiable {
    var id: Int { speaker }
    let speaker: Int
    let displayNumber: Int
    let durationMs: Int
    let wordCount: Int
}

extension TranscriptionResponse {
    /// How long each speaker talked and how much they said — the sort of thing
    /// that's obvious from the data but tedious to work out by eye.
    var speakerStats: [SpeakerStat] {
        var order: [Int] = []
        var durations: [Int: Int] = [:]
        var words: [Int: Int] = [:]

        for utterance in utterances {
            if !order.contains(utterance.speaker) { order.append(utterance.speaker) }
            durations[utterance.speaker, default: 0] += utterance.durationMs
            words[utterance.speaker, default: 0] += utterance.text
                .split(whereSeparator: { $0 == " " || $0.isNewline })
                .count
        }

        return order.enumerated().map { index, speaker in
            SpeakerStat(speaker: speaker,
                        displayNumber: index + 1,
                        durationMs: durations[speaker] ?? 0,
                        wordCount: words[speaker] ?? 0)
        }
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
