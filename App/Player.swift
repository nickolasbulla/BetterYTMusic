import AVFoundation
import MediaPlayer
import UIKit

/// Player nativo: toca em segundo plano e com a tela bloqueada, e aparece
/// na tela de bloqueio / Central de Controle com os controles do sistema.
final class Player: ObservableObject {
    enum RepeatMode: String, Codable { case off, all, one }

    /// Estado salvo para reabrir o app na mesma música, ponto e modos.
    private struct SavedState: Codable {
        var queue: [String]
        var originalQueue: [String]
        var index: Int
        var time: Double
        var isShuffled: Bool
        var repeatMode: RepeatMode
    }
    private static let savedStateKey = "playerState"

    /// Recebe o tempo ouvido e as reproduções (conta como "tocada" após 30 s ou metade da música).
    var stats: Stats?
    private var lastObservedTime: Double?
    private var listenedThisTrack: Double = 0
    private var countedThisTrack = false
    private var lastStateSave = Date.distantPast

    @Published private(set) var queue: [Track] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isShuffled = false
    @Published private(set) var repeatMode: RepeatMode = .off

    /// Fila na ordem original, para desligar o aleatório sem perder a ordem.
    private var originalQueue: [Track] = []

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
            guard let self, time.seconds.isFinite else { return }
            self.currentTime = time.seconds
            self.recordListening(at: time.seconds)
            if Date().timeIntervalSince(self.lastStateSave) > 5 { self.saveState() }
        }

        statusObservation = player.observe(\.timeControlStatus) { [weak self] p, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isPlaying = p.timeControlStatus != .paused
                self.updateNowPlaying()
                if !self.isPlaying { self.saveState() }
            }
        }

        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
            if self.repeatMode == .one {
                self.resetListening()
                self.seek(to: 0)
                self.play()
            } else {
                self.next()
            }
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
        notificationTokens.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.saveState()
            self?.stats?.save()
        })

        configureRemoteCommands()
    }

    // MARK: - Estado salvo

    /// Volta para a última música/ponto/modos, pausado. `lookup` acha a música pelo id.
    func restore(lookup: (String) -> Track?) {
        guard current == nil,
              let data = UserDefaults.standard.data(forKey: Self.savedStateKey),
              let saved = try? JSONDecoder().decode(SavedState.self, from: data)
        else { return }

        let q = saved.queue.compactMap(lookup)
        guard !q.isEmpty else { return }
        let currentID = saved.queue.indices.contains(saved.index) ? saved.queue[saved.index] : nil

        queue = q
        originalQueue = saved.originalQueue.compactMap(lookup)
        if originalQueue.isEmpty { originalQueue = q }
        isShuffled = saved.isShuffled
        repeatMode = saved.repeatMode

        let i = q.firstIndex { $0.id == currentID } ?? 0
        load(i)
        if q[i].id == currentID, saved.time > 0 { seek(to: saved.time) }
    }

    private func saveState() {
        lastStateSave = Date()
        guard current != nil else { return }
        let saved = SavedState(
            queue: queue.map(\.id),
            originalQueue: originalQueue.map(\.id),
            index: index,
            time: currentTime,
            isShuffled: isShuffled,
            repeatMode: repeatMode
        )
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.savedStateKey)
        }
    }

    // MARK: - Estatísticas

    private func recordListening(at time: Double) {
        defer { lastObservedTime = time }
        // Sugestões tocadas por streaming não entram nas estatísticas.
        guard isPlaying, let track = current, track.url.isFileURL, let last = lastObservedTime else { return }
        let delta = time - last
        guard delta > 0, delta < 2 else { return }   // ignora pulos (seek)
        stats?.addListening(track, seconds: delta)
        listenedThisTrack += delta
        if !countedThisTrack, listenedThisTrack >= min(30, max(track.duration * 0.5, 1)) {
            countedThisTrack = true
            stats?.countPlay(track)
        }
    }

    private func resetListening() {
        listenedThisTrack = 0
        countedThisTrack = false
        lastObservedTime = nil
    }

    // MARK: - Controles

    func play(_ tracks: [Track], startAt i: Int) {
        guard tracks.indices.contains(i) else { return }
        originalQueue = tracks
        if isShuffled {
            var rest = tracks
            let first = rest.remove(at: i)
            queue = [first] + rest.shuffled()
            load(0)
        } else {
            queue = tracks
            load(i)
        }
        play()
    }

    /// Liga o aleatório e começa por uma música qualquer da lista.
    func playShuffled(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        isShuffled = true
        play(tracks, startAt: Int.random(in: tracks.indices))
    }

    /// Embaralha (ou desembaralha) a fila atual sem interromper a música que está tocando.
    func toggleShuffle() {
        isShuffled.toggle()
        guard let cur = current else { return }
        if isShuffled {
            var rest = originalQueue
            if let i = rest.firstIndex(of: cur) { rest.remove(at: i) }
            queue = [cur] + rest.shuffled()
            index = 0
        } else {
            queue = originalQueue
            index = originalQueue.firstIndex(of: cur) ?? 0
        }
        saveState()
    }

    /// Desligado → repetir fila → repetir música → desligado.
    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        saveState()
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
        } else if repeatMode != .off {
            load(0)
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
        resetListening()
        player.replaceCurrentItem(with: AVPlayerItem(url: queue[i].url))
        updateNowPlaying()
        saveState()
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
