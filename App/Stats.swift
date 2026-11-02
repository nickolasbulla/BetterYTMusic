import Foundation

/// Estatísticas de reprodução, salvas em Application Support/stats.json.
/// Título e artista ficam guardados junto, para a música continuar aparecendo
/// mesmo depois de apagada.
final class Stats: ObservableObject {
    struct Entry: Codable {
        var title: String
        var artist: String
        var plays: Int = 0
        var seconds: Double = 0
        var lastPlayed: Date?
    }

    struct ArtistTotal: Identifiable {
        var id: String { name }
        let name: String
        let plays: Int
        let seconds: Double
    }

    @Published private(set) var entries: [String: Entry] = [:]   // chave: Track.id

    private var lastSave = Date.distantPast

    private static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("stats.json")
    }()

    init() {
        if let data = try? Data(contentsOf: Self.url),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    var totalSeconds: Double { entries.values.reduce(0) { $0 + $1.seconds } }
    var totalPlays: Int { entries.values.reduce(0) { $0 + $1.plays } }

    struct Ranked: Identifiable {
        let id: String      // Track.id
        let entry: Entry
    }

    func topTracks(_ n: Int) -> [Ranked] {
        entries.filter { $0.value.plays > 0 }
            .sorted { ($0.value.plays, $0.value.seconds) > ($1.value.plays, $1.value.seconds) }
            .prefix(n)
            .map { Ranked(id: $0.key, entry: $0.value) }
    }

    func topArtists(_ n: Int) -> [ArtistTotal] {
        var byArtist: [String: (plays: Int, seconds: Double)] = [:]
        for e in entries.values where !e.artist.isEmpty {
            byArtist[e.artist, default: (0, 0)].plays += e.plays
            byArtist[e.artist, default: (0, 0)].seconds += e.seconds
        }
        return byArtist
            .map { ArtistTotal(name: $0.key, plays: $0.value.plays, seconds: $0.value.seconds) }
            .sorted { $0.seconds > $1.seconds }
            .prefix(n)
            .map { $0 }
    }

    // MARK: - Registro (chamado pelo Player)

    func addListening(_ track: Track, seconds: Double) {
        update(track) { $0.seconds += seconds }
        if Date().timeIntervalSince(lastSave) > 30 { save() }
    }

    func countPlay(_ track: Track) {
        update(track) {
            $0.plays += 1
            $0.lastPlayed = Date()
        }
        save()
    }

    func save() {
        lastSave = Date()
        do {
            try JSONEncoder().encode(entries).write(to: Self.url, options: .atomic)
        } catch {
            print("Falha ao salvar stats.json: \(error)")
        }
    }

    private func update(_ track: Track, _ change: (inout Entry) -> Void) {
        var e = entries[track.id] ?? Entry(title: track.title, artist: track.artist)
        e.title = track.title
        e.artist = track.artist
        change(&e)
        entries[track.id] = e
    }
}
