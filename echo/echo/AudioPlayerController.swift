import Foundation
import AVFoundation
import Combine

/// Plays the source recording alongside its transcript.
///
/// Uses AVPlayer rather than AVAudioPlayer so video containers (.mp4, .mov) work
/// without extracting the audio track first.
@MainActor
final class AudioPlayerController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTimeMs: Int = 0
    @Published var rate: Float = 1.0 {
        didSet { if isPlaying { player?.rate = rate } }
    }

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private(set) var loadedURL: URL?

    deinit {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    var isLoaded: Bool { player != nil }

    func load(_ url: URL) {
        guard loadedURL != url else { return }
        teardown()

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        self.loadedURL = url

        // Each tick republishes and re-renders the transcript, so 5/sec is plenty
        // — fine enough for follow-along scrolling, cheap enough not to stutter.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                self.currentTimeMs = Int(max(time.seconds, 0) * 1000)
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.isPlaying = false }
        }
    }

    /// Seeks to the given offset and starts playing. Used when a transcript line
    /// is clicked, so "what did they actually say" is one keystroke away.
    func play(fromMs ms: Int) {
        guard let player else { return }
        seek(toMs: ms)
        player.rate = rate
        isPlaying = true
    }

    func togglePlayback(fromMs ms: Int) {
        if isPlaying {
            pause()
        } else {
            play(fromMs: ms)
        }
    }

    func resume() {
        guard let player else { return }
        player.rate = rate
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func seek(toMs ms: Int) {
        guard let player else { return }
        let time = CMTime(seconds: Double(ms) / 1000, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTimeMs = ms
    }

    func teardown() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        timeObserver = nil
        endObserver = nil
        player?.pause()
        player = nil
        loadedURL = nil
        isPlaying = false
        currentTimeMs = 0
    }
}
