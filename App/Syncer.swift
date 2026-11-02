import Foundation
import UIKit

/// Estado salvo em Application Support/sync.json.
private struct SyncState: Codable {
    var sources: [Source] = []
    var playlists: [RemotePlaylist] = []
    var ignoredPlaylists: [String] = []     // playlists de um perfil que o usuário removeu
    var downloaded: [String] = []           // videoIds baixados pela sincronização
}

/// Botão "Atualizar playlists": relê as playlists cadastradas, baixa músicas novas
/// e apaga as que saíram de todas as playlists. Tudo sem login.
@MainActor
final class Syncer: ObservableObject {
    @Published private(set) var playlists: [RemotePlaylist] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var status: String?

    private var state: SyncState

    private static let stateURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sync.json")
    }()

    init() {
        if let data = try? Data(contentsOf: Self.stateURL),
           let saved = try? JSONDecoder().decode(SyncState.self, from: data) {
            state = saved
        } else {
            state = SyncState()
        }
        playlists = state.playlists
    }

    static func fileName(for videoId: String) -> String { "\(videoId).m4a" }

    // MARK: - Links

    /// Retorna false se o link não for reconhecido.
    func addLink(_ text: String) -> Bool {
        guard let source = YTMusicAPI.parseLink(text) else {
            status = "Link não reconhecido. Use o link de uma playlist ou do seu perfil (@nome)."
            return false
        }
        if source.kind == .playlist {
            state.ignoredPlaylists.removeAll { $0 == source.value }
        }
        if !state.sources.contains(source) {
            state.sources.append(source)
        }
        save()
        return true
    }

    func removePlaylists(at offsets: IndexSet, library: Library) {
        for p in offsets.map({ playlists[$0] }) {
            if p.source.kind == .playlist {
                state.sources.removeAll { $0 == p.source }
            } else {
                state.ignoredPlaylists.append(p.id)
            }
            state.playlists.removeAll { $0.id == p.id }
        }
        playlists = state.playlists
        removeOrphans(library: library)
        save()
    }

    // MARK: - Sincronização

    func sync(library: Library) async {
        guard !isSyncing else { return }
        isSyncing = true
        UIApplication.shared.isIdleTimerDisabled = true   // tela não apaga durante os downloads
        defer {
            isSyncing = false
            UIApplication.shared.isIdleTimerDisabled = false
        }

        var errors: [String] = []

        // 1. Playlists
        status = "Lendo playlists…"
        var updated: [RemotePlaylist] = []
        for source in state.sources {
            let previous = state.playlists.filter { $0.source == source }
            let ids: [String]
            do {
                ids = source.kind == .playlist
                    ? [source.value]
                    : try await YTMusicAPI.channelPlaylistIDs(source.value)
            } catch {
                errors.append("\(source.value): \(error.localizedDescription)")
                updated += previous      // sem internet / erro: mantém o que já tinha
                continue
            }
            for id in ids where !state.ignoredPlaylists.contains(id) && !updated.contains(where: { $0.id == id }) {
                do {
                    updated.append(try await YTMusicAPI.playlist(id: id, source: source))
                } catch {
                    errors.append("Playlist \(id): \(error.localizedDescription)")
                    if let old = previous.first(where: { $0.id == id }) { updated.append(old) }
                }
            }
        }
        state.playlists = updated
        playlists = updated
        save()

        // 2. Downloads
        let fm = FileManager.default
        var wanted: [RemoteTrack] = []
        var seen = Set<String>()
        for t in updated.flatMap(\.tracks) where seen.insert(t.videoId).inserted {
            wanted.append(t)
        }
        let missing = wanted.filter {
            !fm.fileExists(atPath: Library.folder.appendingPathComponent(Self.fileName(for: $0.videoId)).path)
        }

        var done = 0
        for (i, track) in missing.enumerated() {
            status = "Baixando \(i + 1) de \(missing.count): \(track.title)"
            let dest = Library.folder.appendingPathComponent(Self.fileName(for: track.videoId))
            do {
                try await Downloader.download(track, to: dest)
                if !state.downloaded.contains(track.videoId) { state.downloaded.append(track.videoId) }
                save()
                await library.add(dest)
                done += 1
            } catch {
                errors.append("\(track.title): \(error.localizedDescription)")
            }
        }

        // 3. Limpeza
        removeOrphans(library: library)
        save()

        var summary = missing.isEmpty ? "Tudo em dia." : "\(done) de \(missing.count) músicas baixadas."
        if let first = errors.first {
            summary += " \(errors.count) erro(s). Primeiro: \(first)"
        }
        status = summary
    }

    /// Apaga músicas baixadas pela sincronização que não estão mais em nenhuma playlist.
    /// Arquivos importados manualmente nunca são apagados.
    private func removeOrphans(library: Library) {
        let inUse = Set(state.playlists.flatMap(\.tracks).map(\.videoId))
        for id in state.downloaded where !inUse.contains(id) {
            library.removeFile(named: Self.fileName(for: id))
        }
        state.downloaded.removeAll { !inUse.contains($0) }
    }

    private func save() {
        do {
            try JSONEncoder().encode(state).write(to: Self.stateURL, options: .atomic)
        } catch {
            print("Falha ao salvar sync.json: \(error)")
        }
    }
}
