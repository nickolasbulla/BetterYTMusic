import Foundation
import AVFoundation
import UIKit

struct Track: Identifiable, Equatable {
    let id: String          // nome do arquivo dentro de Documents/Music
    let url: URL
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var artwork: UIImage?

    static func == (a: Track, b: Track) -> Bool { a.id == b.id }
}

/// Biblioteca local: tudo o que está em Documents/Music.
/// Essa pasta também aparece no app Arquivos (No Meu iPhone → BetterYTM → Music).
@MainActor
final class Library: ObservableObject {
    @Published private(set) var tracks: [Track] = []

    static let folder: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "mp4", "wav", "aif", "aiff", "caf", "flac"]

    func reload() async {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        var result: [Track] = []
        for url in files where Self.audioExtensions.contains(url.pathExtension.lowercased()) {
            result.append(await Self.readTrack(url))
        }
        tracks = result.sorted {
            ($0.artist.lowercased(), $0.album.lowercased(), $0.title.lowercased())
                < ($1.artist.lowercased(), $1.album.lowercased(), $1.title.lowercased())
        }
    }

    func importFiles(_ urls: [URL]) async {
        for src in urls {
            let access = src.startAccessingSecurityScopedResource()
            defer { if access { src.stopAccessingSecurityScopedResource() } }
            let dest = Self.folder.appendingPathComponent(src.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: dest.path) else { continue }
            do {
                try FileManager.default.copyItem(at: src, to: dest)
            } catch {
                print("Falha ao importar \(src.lastPathComponent): \(error)")
            }
        }
        await reload()
    }

    func delete(_ track: Track) {
        try? FileManager.default.removeItem(at: track.url)
        tracks.removeAll { $0 == track }
    }

    nonisolated static func readTrack(_ url: URL) async -> Track {
        let asset = AVURLAsset(url: url)
        var title = url.deletingPathExtension().lastPathComponent
        var artist = "Artista desconhecido"
        var album = ""
        var artwork: UIImage?
        var duration = 0.0

        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                switch item.commonKey {
                case .commonKeyTitle?:
                    if let v = try? await item.load(.stringValue), !v.isEmpty { title = v }
                case .commonKeyArtist?:
                    if let v = try? await item.load(.stringValue), !v.isEmpty { artist = v }
                case .commonKeyAlbumName?:
                    if let v = try? await item.load(.stringValue) { album = v }
                case .commonKeyArtwork?:
                    if let d = try? await item.load(.dataValue) { artwork = UIImage(data: d) }
                default:
                    break
                }
            }
        }
        if let d = try? await asset.load(.duration), d.seconds.isFinite {
            duration = d.seconds
        }
        return Track(id: url.lastPathComponent, url: url, title: title, artist: artist,
                     album: album, duration: duration, artwork: artwork)
    }
}
