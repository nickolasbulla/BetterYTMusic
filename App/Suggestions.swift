import Foundation
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
        results[id] = score.sorted { $0.value > $1.value }
            .prefix(Self.resultCount)
            .compactMap { info[$0.key] }
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
        guard let url = try? await Downloader.audioURL(videoId: remote.videoId) else { return }
        let artwork = await Downloader.fetchArtwork(remote).flatMap(UIImage.init(data:))
        let track = Track(id: "stream:" + remote.videoId, url: url, title: remote.title,
                          artist: remote.artist, album: remote.album,
                          duration: remote.duration ?? 0, artwork: artwork)
        player.play([track], startAt: 0)
    }
}
