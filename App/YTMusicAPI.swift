import Foundation

/// Fontes que o usuário cadastra colando um link.
struct Source: Codable, Hashable {
    enum Kind: String, Codable { case playlist, channel }
    var kind: Kind
    var value: String       // ID da playlist, ID do canal (UC...) ou @handle
}

struct RemoteTrack: Codable, Hashable {
    var videoId: String
    var title: String
    var artist: String
    var album: String
    var thumbnail: String?
    var duration: Double? = nil     // só nas sugestões (rádio); nas playlists vem do arquivo
}

struct RemotePlaylist: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var tracks: [RemoteTrack]
    var source: Source
}

enum APIError: LocalizedError {
    case http(Int)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .http(let code): return "YouTube respondeu HTTP \(code)"
        case .notFound(let what): return "Não encontrado: \(what)"
        }
    }
}

/// Acesso anônimo (sem login) à API interna do YouTube / YouTube Music (InnerTube).
/// As respostas mudam de formato com frequência, então a leitura procura as chaves
/// em qualquer profundidade em vez de seguir um caminho fixo.
enum YTMusicAPI {
    struct Client {
        let name: String
        let version: String
        let nameID: String
        let host: String
    }

    static let music = Client(name: "WEB_REMIX", version: "1.20261029.01.00", nameID: "67", host: "music.youtube.com")
    static let web = Client(name: "WEB", version: "2.20261029.01.00", nameID: "1", host: "www.youtube.com")

    // MARK: - Links

    /// Aceita link de playlist (…?list=…), de perfil (youtube.com/@nome, …/channel/UC…) ou só "@nome".
    static func parseLink(_ text: String) -> Source? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("@") { return Source(kind: .channel, value: t) }

        guard let comps = URLComponents(string: t),
              let host = comps.host?.lowercased(),
              host.hasSuffix("youtube.com") || host == "youtu.be"
        else { return nil }

        if let list = comps.queryItems?.first(where: { $0.name == "list" })?.value, !list.isEmpty {
            return Source(kind: .playlist, value: list)
        }
        let parts = comps.path.split(separator: "/").map(String.init)
        if let first = parts.first {
            if first.hasPrefix("@") { return Source(kind: .channel, value: first) }
            if first == "channel", parts.count > 1 { return Source(kind: .channel, value: parts[1]) }
        }
        return nil
    }

    // MARK: - Playlists

    static func playlist(id: String, source: Source) async throws -> RemotePlaylist {
        let browseId = id.hasPrefix("VL") ? id : "VL" + id
        let first = try await post("browse", client: music, body: ["browseId": browseId])

        // Só a lista da playlist; o resto da página tem "sugestões" que não queremos.
        let shelf: Any = JSONWalk.first("musicPlaylistShelfRenderer", in: first) ?? first
        var tracks = parseItems(shelf)
        var seen = Set(tracks.map(\.videoId))
        var token = continuationToken(in: shelf)
        var pages = 0

        while let t = token, pages < 100 {
            let next = try await post("browse", client: music, body: ["continuation": t])
            let more = parseItems(next).filter { seen.insert($0.videoId).inserted }
            if more.isEmpty { break }
            tracks += more
            token = continuationToken(in: next)
            pages += 1
        }

        let title = headerTitle(first) ?? "Playlist"
        return RemotePlaylist(id: id, title: title, tracks: tracks, source: source)
    }

    /// IDs das playlists públicas de um canal (aba "Playlists" do perfil).
    static func channelPlaylistIDs(_ channel: String) async throws -> [String] {
        var channelID = channel
        if !channel.hasPrefix("UC") {
            let r: Any
            do {
                r = try await post("navigation/resolve_url", client: web,
                                   body: ["url": "https://www.youtube.com/\(channel)"])
            } catch APIError.http(404) {
                throw APIError.notFound(channel)
            }
            guard let id = JSONWalk.strings("browseId", in: r).first(where: { $0.hasPrefix("UC") }) else {
                throw APIError.notFound(channel)
            }
            channelID = id
        }
        // params = aba "Playlists"
        let r = try await post("browse", client: web,
                               body: ["browseId": channelID, "params": "EglwbGF5bGlzdHPyBgQKAkIA"])
        var ids: [String] = []
        for key in ["playlistId", "contentId"] {
            // IDs reais de playlist têm 18+ caracteres; há outros "PL…" curtos na página.
            for s in JSONWalk.strings(key, in: r) where s.hasPrefix("PL") && s.count >= 18 && !ids.contains(s) {
                ids.append(s)
            }
        }
        return ids
    }

    // MARK: - Rádio

    /// Mix de ~50 músicas parecidas com `videoId` (o "rádio" do YouTube Music). A primeira é a própria música.
    static func radio(videoId: String) async throws -> [RemoteTrack] {
        let r = try await post("next", client: music,
                               body: ["videoId": videoId, "playlistId": "RDAMVM" + videoId])
        return JSONWalk.objects("playlistPanelVideoRenderer", in: r).compactMap { v in
            guard let id = v["videoId"] as? String,
                  let title = v["title"].flatMap(runsText), !title.isEmpty
            else { return nil }
            // longBylineText: "Artista • Álbum • Ano" ou "Artista • 1 mi de visualizações…"
            let byline = (v["longBylineText"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
            let album = byline.first { run in
                JSONWalk.strings("pageType", in: run).contains("MUSIC_PAGE_TYPE_ALBUM")
            }?["text"] as? String
            return RemoteTrack(
                videoId: id,
                title: title,
                artist: v["shortBylineText"].flatMap(runsText) ?? "",
                album: album ?? "",
                thumbnail: v["thumbnail"].flatMap { JSONWalk.strings("url", in: $0).last },
                duration: v["lengthText"].flatMap(runsText).flatMap(parseDuration)
            )
        }
    }

    // MARK: - Busca

    /// Busca só entre as músicas (faixas de áudio do YouTube Music), sem clipes.
    static func searchSongs(_ query: String) async throws -> [RemoteTrack] {
        // params = filtro "Músicas"
        let r = try await post("search", client: music,
                               body: ["query": query, "params": "EgWKAQIIAWoMEA4QChADEAQQCRAF"])
        return parseItems(r).map { t in
            // Na busca a 2ª coluna vem como "Artista • Álbum • 3:21".
            var t = t
            let parts = t.artist.components(separatedBy: " • ")
            if parts.count >= 2 {
                t.artist = parts[0]
                t.album = parts.count >= 3 ? parts[1] : ""
                t.duration = parseDuration(parts[parts.count - 1])
            }
            return t
        }
    }

    /// "3:45" / "1:02:03" → segundos.
    private static func parseDuration(_ text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    // MARK: - Leitura das respostas

    private static func parseItems(_ node: Any) -> [RemoteTrack] {
        JSONWalk.objects("musicResponsiveListItemRenderer", in: node).compactMap { r in
            let videoId = (r["playlistItemData"] as? [String: Any])?["videoId"] as? String
                ?? JSONWalk.strings("videoId", in: r).first
            guard let videoId else { return nil }   // item indisponível

            let columns = (r["flexColumns"] as? [Any] ?? []).map { col -> String in
                guard let flex = (col as? [String: Any])?["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
                      let text = flex["text"]
                else { return "" }
                return runsText(text) ?? ""
            }
            let thumb = r["thumbnail"].flatMap { JSONWalk.strings("url", in: $0).last }
            return RemoteTrack(
                videoId: videoId,
                title: columns.first.flatMap { $0.isEmpty ? nil : $0 } ?? videoId,
                artist: columns.count > 1 ? columns[1] : "",
                album: columns.count > 2 ? columns[2] : "",
                thumbnail: thumb
            )
        }
    }

    private static func continuationToken(in node: Any) -> String? {
        JSONWalk.objects("continuationCommand", in: node).compactMap { $0["token"] as? String }.first
            ?? JSONWalk.objects("nextContinuationData", in: node).compactMap { $0["continuation"] as? String }.first
    }

    private static func headerTitle(_ json: Any) -> String? {
        for key in ["musicResponsiveHeaderRenderer", "musicDetailHeaderRenderer", "musicEditablePlaylistDetailHeaderRenderer"] {
            if let header = JSONWalk.first(key, in: json),
               let title = JSONWalk.first("title", in: header).flatMap(runsText), !title.isEmpty {
                return title
            }
        }
        return (JSONWalk.first("microformatDataRenderer", in: json) as? [String: Any])?["title"] as? String
    }

    private static func runsText(_ any: Any) -> String? {
        guard let dict = any as? [String: Any] else { return nil }
        if let runs = dict["runs"] as? [[String: Any]] {
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        return dict["simpleText"] as? String
    }

    // MARK: - HTTP

    private static func post(_ endpoint: String, client: Client, body: [String: Any]) async throws -> Any {
        var payload = body
        payload["context"] = ["client": [
            "clientName": client.name, "clientVersion": client.version, "hl": "pt", "gl": "BR",
        ]]
        var req = URLRequest(url: URL(string: "https://\(client.host)/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://\(client.host)", forHTTPHeaderField: "Origin")
        req.setValue(client.nameID, forHTTPHeaderField: "X-Youtube-Client-Name")
        req.setValue(client.version, forHTTPHeaderField: "X-Youtube-Client-Version")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw APIError.http(code) }
        return try JSONSerialization.jsonObject(with: data)
    }
}

/// Busca chaves em qualquer profundidade de um JSON. Arrays são percorridos em ordem,
/// então itens de uma lista saem na ordem da playlist.
enum JSONWalk {
    static func first(_ key: String, in json: Any) -> Any? {
        if let dict = json as? [String: Any] {
            if let v = dict[key] { return v }
            for v in dict.values { if let found = first(key, in: v) { return found } }
        } else if let array = json as? [Any] {
            for v in array { if let found = first(key, in: v) { return found } }
        }
        return nil
    }

    static func values(_ key: String, in json: Any) -> [Any] {
        var out: [Any] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let v = dict[key] { out.append(v) }
                for (k, v) in dict where k != key { walk(v) }
            } else if let array = node as? [Any] {
                array.forEach(walk)
            }
        }
        walk(json)
        return out
    }

    static func objects(_ key: String, in json: Any) -> [[String: Any]] {
        values(key, in: json).compactMap { $0 as? [String: Any] }
    }

    static func strings(_ key: String, in json: Any) -> [String] {
        values(key, in: json).compactMap { $0 as? String }
    }
}
