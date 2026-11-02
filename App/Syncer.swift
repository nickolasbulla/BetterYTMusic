import Foundation
import UIKit

/// Sugestão adicionada pelo app que ainda falta salvar na playlist do YouTube Music.
/// Sai da lista sozinha quando aparece na playlist no próximo Atualizar.
struct PendingTrack: Codable, Hashable {
    var playlistId: String
    var track: RemoteTrack
}

/// Outra versão (faixa de áudio do YouTube Music) de uma música que o YouTube não liberou,
/// esperando o usuário confirmar.
struct Substitute: Identifiable, Hashable {
    var original: RemoteTrack
    var candidate: RemoteTrack
    var id: String { original.videoId }
    var key: String { original.videoId + ">" + candidate.videoId }
}

/// Estado salvo em Application Support/sync.json.
private struct SyncState: Codable {
    var sources: [Source] = []
    var playlists: [RemotePlaylist] = []
    var ignoredPlaylists: [String] = []     // playlists de um perfil que o usuário removeu
    var downloaded: [String] = []           // videoIds baixados pela sincronização
    var artworkVersion = 0                  // 2 = capas quadradas
    var pending: [PendingTrack] = []
    var declinedSubstitutes: [String] = []  // Substitute.key recusados: não pergunta de novo
    var acceptedSubstitutes: [String: String] = [:]     // videoId original → videoId da versão usada
    var substituteInfo: [String: RemoteTrack] = [:]     // videoId original → nome/artista/capa da versão usada

    init() {}

    // Campos ausentes (de versões antigas do app) viram o valor padrão em vez de
    // invalidar o arquivo inteiro.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = try c.decodeIfPresent([Source].self, forKey: .sources) ?? []
        playlists = try c.decodeIfPresent([RemotePlaylist].self, forKey: .playlists) ?? []
        ignoredPlaylists = try c.decodeIfPresent([String].self, forKey: .ignoredPlaylists) ?? []
        downloaded = try c.decodeIfPresent([String].self, forKey: .downloaded) ?? []
        artworkVersion = try c.decodeIfPresent(Int.self, forKey: .artworkVersion) ?? 0
        pending = try c.decodeIfPresent([PendingTrack].self, forKey: .pending) ?? []
        declinedSubstitutes = try c.decodeIfPresent([String].self, forKey: .declinedSubstitutes) ?? []
        acceptedSubstitutes = try c.decodeIfPresent([String: String].self, forKey: .acceptedSubstitutes) ?? [:]
        substituteInfo = try c.decodeIfPresent([String: RemoteTrack].self, forKey: .substituteInfo) ?? [:]
    }
}

/// Botão "Atualizar playlists": relê as playlists cadastradas, baixa músicas novas
/// e apaga as que saíram de todas as playlists. Tudo sem login.
@MainActor
final class Syncer: ObservableObject {
    @Published private(set) var playlists: [RemotePlaylist] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var status: String?
    @Published private(set) var errors: [String] = []      // erros do último Atualizar
    @Published private(set) var substitutes: [Substitute] = []
    @Published private(set) var pending: [PendingTrack] = []
    @Published private(set) var adding: Set<String> = []    // videoIds sendo baixados pelo "+"

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
        pending = state.pending
    }

    nonisolated static func fileName(for videoId: String) -> String { "\(videoId).m4a" }

    var allTracks: [RemoteTrack] { playlists.flatMap(\.tracks) + pending.map(\.track) }

    /// O que a biblioteca mostra: músicas trocadas por outra versão aparecem com o nome,
    /// artista e capa dessa versão (o videoId continua o da playlist, que é o nome do arquivo).
    var libraryTracks: [RemoteTrack] { forLibrary(allTracks) }

    private func forLibrary(_ tracks: [RemoteTrack]) -> [RemoteTrack] {
        tracks.map { t in
            guard var info = state.substituteInfo[t.videoId] else { return t }
            info.videoId = t.videoId
            return info
        }
    }

    func pending(in playlistID: String) -> [RemoteTrack] {
        pending.filter { $0.playlistId == playlistID }.map(\.track)
    }

    // MARK: - Sugestões adicionadas

    /// Coloca a sugestão na playlist (só no app, até ser salva no YouTube Music) e baixa.
    func addSuggestion(_ track: RemoteTrack, to playlistID: String, library: Library) async {
        guard !state.pending.contains(where: { $0.playlistId == playlistID && $0.track.videoId == track.videoId })
        else { return }
        state.pending.append(PendingTrack(playlistId: playlistID, track: track))
        pending = state.pending
        save()
        library.apply(remote: libraryTracks)

        let dest = Library.folder.appendingPathComponent(Self.fileName(for: track.videoId))
        guard !FileManager.default.fileExists(atPath: dest.path), !adding.contains(track.videoId) else { return }
        adding.insert(track.videoId)
        defer { adding.remove(track.videoId) }
        do {
            try await Downloader.download(track, to: dest)
            if !state.downloaded.contains(track.videoId) { state.downloaded.append(track.videoId) }
            save()
            await library.add(dest)
        } catch {
            // Continua pendente; o próximo Atualizar tenta baixar de novo.
            status = "\(track.title): \(error.localizedDescription)"
        }
    }

    // MARK: - Outra versão de músicas restritas

    /// Procura a mesma música entre as faixas de áudio do YouTube Music (costumam não ter
    /// restrição de idade, ao contrário do clipe) e confere se essa o YouTube libera.
    private func findSubstitute(for track: RemoteTrack) async -> Substitute? {
        guard let results = try? await YTMusicAPI.searchSongs("\(track.title) \(track.artist)") else { return nil }
        let title = Self.normalized(track.title)
        let options = results.filter { c in
            c.videoId != track.videoId
                && !state.declinedSubstitutes.contains(Substitute(original: track, candidate: c).key)
        }
        // Primeiro as de título parecido (o título do clipe costuma trazer artistas e "(Clipe Oficial)").
        let sameTitle = { (c: RemoteTrack) in
            let t = Self.normalized(c.title)
            return !t.isEmpty && (title.contains(t) || t.contains(title))
        }
        let ranked = options.filter(sameTitle) + options.filter { !sameTitle($0) }
        for c in ranked.prefix(3) {
            if (try? await Downloader.audioURL(videoId: c.videoId)) != nil {
                return Substitute(original: track, candidate: c)
            }
        }
        return nil
    }

    private static func normalized(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber || $0 == " " }
            .split(separator: " ").joined(separator: " ")
    }

    /// Baixa a outra versão (áudio, nome, artista e capa) no lugar da original na playlist.
    func acceptSubstitute(_ s: Substitute, library: Library) async {
        substitutes.removeAll { $0.id == s.id }
        guard !adding.contains(s.original.videoId) else { return }
        let dest = Library.folder.appendingPathComponent(Self.fileName(for: s.original.videoId))
        adding.insert(s.original.videoId)
        defer { adding.remove(s.original.videoId) }
        do {
            try await Downloader.download(s.candidate, as: s.original.videoId, to: dest)
            if !state.downloaded.contains(s.original.videoId) { state.downloaded.append(s.original.videoId) }
            if let old = state.acceptedSubstitutes[s.original.videoId], old != s.candidate.videoId {
                state.declinedSubstitutes.append(s.original.videoId + ">" + old)
            }
            state.acceptedSubstitutes[s.original.videoId] = s.candidate.videoId
            state.substituteInfo[s.original.videoId] = s.candidate
            save()
            library.apply(remote: libraryTracks)
            await library.add(dest)
            errors.removeAll { $0.hasPrefix(s.original.title + ":") }
        } catch {
            status = "\(s.original.title): \(error.localizedDescription)"
        }
    }

    /// Apaga a música baixada e baixa de novo. Se ela veio de outra versão, essa versão
    /// conta como recusada; se a original continuar restrita, oferece as próximas.
    func redownload(_ track: RemoteTrack, library: Library) async {
        guard !adding.contains(track.videoId) else { return }
        if let used = state.acceptedSubstitutes.removeValue(forKey: track.videoId) {
            state.declinedSubstitutes.append(track.videoId + ">" + used)
        }
        state.substituteInfo[track.videoId] = nil
        library.apply(remote: libraryTracks)
        let name = Self.fileName(for: track.videoId)
        library.removeFile(named: name)
        try? FileManager.default.removeItem(at: Library.artworkURL(for: track.videoId))
        state.downloaded.removeAll { $0 == track.videoId }
        save()

        let dest = Library.folder.appendingPathComponent(name)
        adding.insert(track.videoId)
        defer { adding.remove(track.videoId) }
        do {
            try await Downloader.download(track, to: dest)
            state.downloaded.append(track.videoId)
            save()
            await library.add(dest)
        } catch DownloadError.noStreams {
            if let s = await findSubstitute(for: track) {
                substitutes.removeAll { $0.id == s.id }
                substitutes.append(s)
            } else {
                status = "\(track.title): nenhuma outra versão encontrada"
            }
        } catch {
            status = "\(track.title): \(error.localizedDescription)"
        }
    }

    func hasSubstitute(_ videoID: String) -> Bool { state.acceptedSubstitutes[videoID] != nil }

    /// Recusa esta versão e já oferece a próxima, se houver.
    func nextSubstitute(_ s: Substitute) async {
        declineSubstitute(s)
        adding.insert(s.original.videoId)
        defer { adding.remove(s.original.videoId) }
        if let next = await findSubstitute(for: s.original) {
            substitutes.insert(next, at: 0)
        } else {
            status = "\(s.original.title): nenhuma outra versão encontrada"
        }
    }

    func declineSubstitute(_ s: Substitute) {
        substitutes.removeAll { $0.id == s.id }
        state.declinedSubstitutes.append(s.key)
        save()
    }

    func discardPending(_ videoID: String, from playlistID: String, library: Library) {
        state.pending.removeAll { $0.playlistId == playlistID && $0.track.videoId == videoID }
        pending = state.pending
        removeOrphans(library: library)
        save()
    }

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

    func removePlaylist(_ p: RemotePlaylist, library: Library) {
        if p.source.kind == .playlist {
            state.sources.removeAll { $0 == p.source }
        } else {
            state.ignoredPlaylists.append(p.id)
        }
        state.playlists.removeAll { $0.id == p.id }
        playlists = state.playlists
        state.pending.removeAll { $0.playlistId == p.id }
        pending = state.pending
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
        self.errors = []
        substitutes = []

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
        // Pendentes já salvas no YouTube Music (ou cuja playlist sumiu) saem da lista.
        state.pending.removeAll { p in
            guard let playlist = updated.first(where: { $0.id == p.playlistId }) else { return true }
            return playlist.tracks.contains { $0.videoId == p.track.videoId }
        }
        pending = state.pending
        save()

        // 2. Downloads
        let fm = FileManager.default
        var wanted: [RemoteTrack] = []
        var seen = Set<String>()
        for t in allTracks where seen.insert(t.videoId).inserted {
            wanted.append(t)
        }
        library.apply(remote: forLibrary(wanted))
        let isDownloaded = { (t: RemoteTrack) in
            fm.fileExists(atPath: Library.folder.appendingPathComponent(Self.fileName(for: t.videoId)).path)
        }
        let missing = wanted.filter { !isDownloaded($0) && !adding.contains($0.videoId) }

        // Capas que faltam em músicas já baixadas (ou todas, uma vez, para trocar pelas quadradas).
        let redoAll = state.artworkVersion < 2
        let noArtwork = wanted.filter {
            isDownloaded($0) && (redoAll || !fm.fileExists(atPath: Library.artworkURL(for: $0.videoId).path))
        }
        for (i, track) in forLibrary(noArtwork).enumerated() {
            status = "Baixando capas \(i + 1) de \(noArtwork.count)…"
            await Downloader.saveArtwork(for: track)   // se falhar, mantém a capa anterior
        }
        if redoAll {
            state.artworkVersion = 2
            save()
        }
        if !noArtwork.isEmpty { await library.reload() }

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
            } catch DownloadError.noStreams {
                var message = "\(track.title): \(DownloadError.noStreams.localizedDescription)"
                status = "Procurando outra versão de \(track.title)…"
                if let s = await findSubstitute(for: track) {
                    substitutes.append(s)
                    message += " (achamos outra versão)"
                }
                errors.append(message)
            } catch {
                errors.append("\(track.title): \(error.localizedDescription)")
            }
        }

        // 3. Limpeza
        removeOrphans(library: library)
        save()

        var summary = missing.isEmpty ? "Tudo em dia." : "\(done) de \(missing.count) músicas baixadas."
        if !errors.isEmpty {
            summary += " \(errors.count) erro(s)."
        }
        status = summary
        self.errors = errors
    }

    /// Apaga músicas baixadas pela sincronização que não estão mais em nenhuma playlist.
    /// Arquivos importados manualmente nunca são apagados.
    private func removeOrphans(library: Library) {
        let inUse = Set(allTracks.map(\.videoId))
        for id in state.downloaded where !inUse.contains(id) {
            library.removeFile(named: Self.fileName(for: id))
            try? FileManager.default.removeItem(at: Library.artworkURL(for: id))
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
