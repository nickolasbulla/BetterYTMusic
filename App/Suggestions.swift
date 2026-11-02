import Foundation
import Network
import UIKit

/// Sugestões de músicas parecidas com uma playlist, montadas a partir do rádio
/// do YouTube Music de algumas músicas dela. Sem login.
@MainActor
final class Suggester: ObservableObject {
    @Published private(set) var results: [String: [RemoteTrack]] = [:]    // playlistId → sugestões
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var failed: Set<String> = []
    @Published private(set) var preparing: String?      // videoId da sugestão sendo aberta para tocar

    private static let seedCount = 5
    private static let resultCount = 20

    /// Wi-Fi comum: pré-carrega. Dados móveis, roteador do celular ou Modo de Dados Reduzidos: não.
    private var cheapNetwork = false
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let cheap = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            Task { @MainActor in self?.cheapNetwork = cheap }
        }
        monitor.start(queue: DispatchQueue(label: "network-monitor"))
    }

    /// Busca uma vez por playlist (ou de novo com `refresh`). `exclude` = músicas que já estão nela.
    func load(_ playlist: RemotePlaylist, exclude: Set<String>, refresh: Bool = false) async {
        let id = playlist.id
        guard !loading.contains(id), refresh || results[id] == nil, !playlist.tracks.isEmpty else { return }
        loading.insert(id)
        failed.remove(id)
        defer { loading.remove(id) }

        // Sementes diferentes a cada vez para variar as sugestões.
        let seeds = playlist.tracks.shuffled().prefix(Self.seedCount).map(\.videoId)
        let radios = await withTaskGroup(of: [RemoteTrack]?.self, returning: [[RemoteTrack]].self) { group in
            for seed in seeds {
                group.addTask { try? await YTMusicAPI.radio(videoId: seed) }
            }
            var all: [[RemoteTrack]] = []
            for await r in group { if let r { all.append(r) } }
            return all
        }
        guard !radios.isEmpty else {
            failed.insert(id)
            return
        }

        // Quem aparece em mais rádios combina com a playlist inteira, não só com uma música.
        var score: [String: Double] = [:]
        var info: [String: RemoteTrack] = [:]
        for radio in radios {
            for (rank, t) in radio.enumerated() where !exclude.contains(t.videoId) {
                score[t.videoId, default: 0] += 1 + 1 / Double(rank + 2)   // empate: o mais alto no rádio
                if info[t.videoId] == nil { info[t.videoId] = t }
            }
        }
        let list = score.sorted { $0.value > $1.value }
            .prefix(Self.resultCount)
            .compactMap { info[$0.key] }
        results[id] = list
        if cheapNetwork { prefetch(list.map(\.videoId)) }
    }

    // MARK: - Links de áudio

    /// Achar o link do áudio é a parte lenta de tocar uma sugestão (1–3 s), então no Wi-Fi
    /// os links de todas as sugestões são buscados antes do toque. Os links valem algumas horas.
    private static let urlLifetime: TimeInterval = 60 * 60
    private var audioURLs: [String: (url: URL, date: Date)] = [:]
    private var resolving: [String: Task<URL, Error>] = [:]

    /// Um de cada vez, para não disparar 20 pedidos juntos ao YouTube.
    private func prefetch(_ ids: [String]) {
        Task {
            for id in ids {
                guard cheapNetwork else { return }      // saiu do Wi-Fi no meio
                _ = try? await audioURLTask(id).value
            }
        }
    }

    private func audioURLTask(_ videoID: String) -> Task<URL, Error> {
        if let cached = audioURLs[videoID], Date().timeIntervalSince(cached.date) < Self.urlLifetime {
            return Task<URL, Error> { cached.url }
        }
        if let running = resolving[videoID] { return running }
        let task = Task { try await Downloader.audioURL(videoId: videoID) }
        resolving[videoID] = task
        Task {
            if let url = try? await task.value { audioURLs[videoID] = (url, Date()) }
            resolving[videoID] = nil
        }
        return task
    }

    /// Tira da lista (depois do "+", ou porque foi adicionada).
    func remove(_ videoID: String, from playlistID: String) {
        results[playlistID]?.removeAll { $0.videoId == videoID }
    }

    /// Toca a sugestão sem baixar (precisa de internet).
    func play(_ remote: RemoteTrack, with player: Player) async {
        guard preparing == nil else { return }
        preparing = remote.videoId
        defer { preparing = nil }
        guard let url = try? await audioURLTask(remote.videoId).value else { return }
        let track = Track(id: "stream:" + remote.videoId, url: url, title: remote.title,
                          artist: remote.artist, album: remote.album,
                          duration: remote.duration ?? 0, artwork: nil)
        player.play([track], startAt: 0)
        preparing = nil

        // A capa chega depois; não vale atrasar o começo da música por ela.
        if let image = await Downloader.fetchArtwork(remote).flatMap(UIImage.init(data:)) {
            player.setArtwork(image, for: track.id)
        }
    }
}
