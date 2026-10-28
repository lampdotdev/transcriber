import AVFoundation
import Foundation

/// Plays a recording from any point, so a click on a transcript line plays what was said there.
@MainActor
final class Player: ObservableObject {
    @Published private(set) var recordingID: Recording.ID?
    @Published private(set) var isPlaying = false
    @Published private(set) var time: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func play(_ recording: Recording, from start: TimeInterval) {
        guard let url = Library.shared.audioURL(for: recording) else { return }
        if recordingID != recording.id || player == nil {
            stop()
            guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
            self.player = player
            recordingID = recording.id
        }
        player?.currentTime = max(0, start - 0.3)   // a moment early, so the first word isn't clipped
        player?.play()
        isPlaying = true
        startTicking()
    }

    /// Play or pause the recording that's open, from where it was.
    func toggle(_ recording: Recording) {
        if recordingID == recording.id, let player {
            if player.isPlaying { player.pause() } else { player.play() }
            isPlaying = player.isPlaying
        } else {
            play(recording, from: 0)
        }
    }

    func stop() {
        player?.stop()
        player = nil
        recordingID = nil
        isPlaying = false
        time = 0
        timer?.invalidate()
        timer = nil
    }

    private func startTicking() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let player else { return }
        time = player.currentTime
        if isPlaying != player.isPlaying { isPlaying = player.isPlaying }
    }
}
