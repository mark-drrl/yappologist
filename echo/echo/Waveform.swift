import Foundation
import AVFoundation
import SwiftUI

/// Reads a recording and reduces it to one amplitude per horizontal pixel-ish
/// bucket, so the whole thing can be drawn as a single shape.
enum WaveformLoader {
    /// Enough detail to see structure in a long recording without carrying the
    /// audio around in memory.
    static let bucketCount = 900

    static func samples(for url: URL) async -> [Float] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: load(url))
            }
        }
    }

    private static func load(_ url: URL) -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return [] }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 8_000,          // plenty for a drawing
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        let totalSamples = max(Int(asset.duration.seconds * 8_000), 1)
        let perBucket = max(totalSamples / bucketCount, 1)

        var peaks: [Float] = []
        peaks.reserveCapacity(bucketCount)
        var bucketPeak: Int16 = 0
        var countInBucket = 0

        while reader.status == .reading {
            // Same autorelease discipline as the converter — these buffers are large
            // and there are a lot of them.
            var finished = false
            autoreleasepool {
                guard let buffer = output.copyNextSampleBuffer(),
                      let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else {
                    finished = true
                    return
                }

                var lengthAtOffset = 0
                var totalLength = 0
                var pointer: UnsafeMutablePointer<Int8>?
                guard CMBlockBufferGetDataPointer(blockBuffer,
                                                  atOffset: 0,
                                                  lengthAtOffsetOut: &lengthAtOffset,
                                                  totalLengthOut: &totalLength,
                                                  dataPointerOut: &pointer) == noErr,
                      let raw = pointer else { return }

                raw.withMemoryRebound(to: Int16.self, capacity: totalLength / 2) { samples in
                    for index in 0..<(totalLength / 2) {
                        let magnitude = Int16(clamping: abs(Int(samples[index])))
                        if magnitude > bucketPeak { bucketPeak = magnitude }
                        countInBucket += 1
                        if countInBucket >= perBucket {
                            peaks.append(Float(bucketPeak) / Float(Int16.max))
                            bucketPeak = 0
                            countInBucket = 0
                        }
                    }
                }
            }
            if finished { break }
        }

        if countInBucket > 0 {
            peaks.append(Float(bucketPeak) / Float(Int16.max))
        }
        return peaks
    }
}

/// A scrubbable waveform with a playhead, drawn as one Canvas rather than a stack
/// of views — hundreds of bars as separate views is what got us into trouble
/// elsewhere.
struct WaveformScrubber: View {
    let samples: [Float]
    let durationMs: Int
    let currentMs: Int
    let accent: Color
    let onScrub: (Int) -> Void

    private var progress: Double {
        guard durationMs > 0 else { return 0 }
        return min(max(Double(currentMs) / Double(durationMs), 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard !samples.isEmpty else { return }

                let midY = size.height / 2
                let step = size.width / CGFloat(samples.count)
                let playedWidth = size.width * CGFloat(progress)

                var played = Path()
                var upcoming = Path()

                for (index, sample) in samples.enumerated() {
                    let x = CGFloat(index) * step
                    // A floor keeps silence visible as a hairline rather than a gap.
                    let height = max(CGFloat(sample) * midY * 1.8, 0.5)
                    let bar = CGRect(x: x,
                                     y: midY - height / 2,
                                     width: max(step - 0.5, 0.5),
                                     height: height)
                    if x <= playedWidth {
                        played.addRect(bar)
                    } else {
                        upcoming.addRect(bar)
                    }
                }

                context.fill(upcoming, with: .color(accent.opacity(0.25)))
                context.fill(played, with: .color(accent.opacity(0.85)))

                var playhead = Path()
                playhead.move(to: CGPoint(x: playedWidth, y: 0))
                playhead.addLine(to: CGPoint(x: playedWidth, y: size.height))
                context.stroke(playhead, with: .color(accent), lineWidth: 1.5)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                        onScrub(Int(fraction * Double(durationMs)))
                    }
            )
        }
    }
}
