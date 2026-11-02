import AVFoundation
import MediaPlayer
import UIKit

/// Player nativo: toca em segundo plano e com a tela bloqueada, e aparece
/// na tela de bloqueio / Central de Controle com os controles do sistema.
final class Player: ObservableObject {
    @Published private(set) var queue: [Track] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var notificationTokens: [NSObjectProtocol] = []

    init() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        } catch {
            print("AVAudioSession error: \(error)")
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            if time.seconds.isFinite { self?.currentTime = time.seconds }
        }

        statusObservation = player.observe(\.timeControlStatus) { [weak self] p, _ in
            DispatchQueue.main.async {
                self?.isPlaying = p.timeControlStatus != .paused
                self?.updateNowPlaying()
            }
        }

        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
            self.next()
        })
        // Retoma depois de uma ligação, Siri etc.
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: rawType) == .ended,
                  let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt,
                  AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            else { return }
            self?.play()
        })

        configureRemoteCommands()
    }

    // MARK: - Controles

    func play(_ tracks: [Track], startAt i: Int) {
        guard tracks.indices.contains(i) else { return }
        queue = tracks
        load(i)
        play()
    }

    func play() {
        guard current != nil else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
    }

    func pause() { player.pause() }

    func toggle() { isPlaying ? pause() : play() }

    func next() {
        guard !queue.isEmpty else { return }
        if index + 1 < queue.count {
            load(index + 1)
            play()
        } else {
            pause()
            seek(to: 0)
        }
    }

    func previous() {
        if currentTime > 3 || index == 0 {
            seek(to: 0)
        } else {
            load(index - 1)
            play()
        }
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
        updateNowPlaying()
    }

    // MARK: - Interno

    private func load(_ i: Int) {
        index = i
        currentTime = 0
        player.replaceCurrentItem(with: AVPlayerItem(url: queue[i].url))
        updateNowPlaying()
    }

    private func updateNowPlaying() {
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        let elapsed = player.currentTime().seconds
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed.isFinite ? elapsed : 0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let image = track.artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.play(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
    }
}
