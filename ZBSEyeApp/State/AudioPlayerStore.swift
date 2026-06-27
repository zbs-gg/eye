import Foundation
import Observation
import AVFoundation

/// Playback of an m4a segment from the timeline (AVAudioPlayer: local file, simple transport).
/// One player per app — opening a new segment stops the previous one.
@MainActor
@Observable
final class AudioPlayerStore {
    private(set) var isPlaying = false
    private(set) var progress: Double = 0      // 0...1 for the progress bar
    private(set) var currentURL: URL?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    func toggle(url: URL) {
        if currentURL == url, let player {
            if player.isPlaying { pause() } else { resume() }
            return
        }
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else {
            Log.audio.error("audio playback failed to open \(url.lastPathComponent, privacy: .public)")
            return
        }
        player = p
        currentURL = url
        resume()
    }

    func stop() {
        tickTask?.cancel(); tickTask = nil
        player?.stop()
        player = nil
        currentURL = nil
        isPlaying = false
        progress = 0
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        tickTask?.cancel(); tickTask = nil
    }

    private func resume() {
        guard let player else { return }
        player.play()
        isPlaying = true
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, let p = self.player else { return }
                self.progress = p.duration > 0 ? p.currentTime / p.duration : 0
                if !p.isPlaying && self.isPlaying {          // finished playing to the end
                    self.isPlaying = false
                    self.progress = 0
                    return
                }
            }
        }
    }
}
