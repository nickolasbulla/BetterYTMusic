import Foundation
import AVFoundation
import UIKit
import YouTubeKit

enum DownloadError: LocalizedError {
    case noStreams
    case noAudioOnly
    case noM4a([String])
    case http(Int)
    case export(Error?)

    var errorDescription: String? {
        switch self {
        case .noStreams: return "O YouTube não liberou nenhum formato deste vídeo"
        case .noAudioOnly: return "O YouTube só liberou vídeo, sem áudio separado"
        case .noM4a(let formats): return "Sem áudio m4a (só \(formats.joined(separator: ", ")))"
        case .http(let code): return "Download falhou (HTTP \(code))"
        case .export(let e): return "Falha ao gravar o arquivo: \(e?.localizedDescription ?? "?")"
        }
    }
}

enum Downloader {
    /// Link direto do áudio AAC (m4a) de um vídeo. Também serve para tocar sem baixar.
    static func audioURL(videoId: String) async throws -> URL {
        let streams = try await YouTube(videoID: videoId, methods: [.local, .remote]).streams
        // Nada veio: vídeo bloqueado/restrito ou o YouTubeKit não conseguiu ler os links.
        guard !streams.isEmpty else { throw DownloadError.noStreams }
        let audio = streams.filterAudioOnly()
        guard !audio.isEmpty else { throw DownloadError.noAudioOnly }
        guard let stream = audio
            .filter({ $0.fileExtension == .m4a })
            .highestAudioBitrateStream()
        else { throw DownloadError.noM4a(Set(audio.map { "\($0.fileExtension)" }).sorted()) }

        // Vídeos com anúncio só liberam o áudio depois de alguns segundos.
        try await stream.waitUntilAvailable()
        return stream.url
    }

    /// Baixa o áudio AAC (m4a) de um vídeo e grava em `dest` com título, artista, álbum e capa.
    static func download(_ track: RemoteTrack, to dest: URL) async throws {
        let url = try await audioURL(videoId: track.videoId)

        let fm = FileManager.default
        let raw = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? fm.removeItem(at: raw) }
        try await fetchInChunks(url, to: raw)

        let artwork = await fetchArtwork(track)
        if let artwork { try? artwork.write(to: Library.artworkURL(for: track.videoId)) }
        try? fm.removeItem(at: dest)
        do {
            try await writeTagged(raw, to: dest, track: track, artwork: artwork)
        } catch {
            // Sem tags é melhor que nada: a música ainda toca.
            print("Tags não gravadas (\(track.videoId)): \(error)")
            try fm.copyItem(at: raw, to: dest)
        }
    }

    /// O YouTube limita downloads de uma vez só; pedir em partes evita bloqueio e lentidão.
    private static func fetchInChunks(_ url: URL, to file: URL) async throws {
        let chunk = 4 * 1024 * 1024
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }

        var offset = 0
        var total: Int?
        while total == nil || offset < total! {
            var req = URLRequest(url: url)
            req.setValue("bytes=\(offset)-\(offset + chunk - 1)", forHTTPHeaderField: "Range")
            let (data, response) = try await URLSession.shared.data(for: req)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            guard (200...299).contains(code) else { throw DownloadError.http(code) }

            try handle.write(contentsOf: data)
            offset += data.count
            if code == 200 || data.isEmpty { break }    // servidor mandou o arquivo inteiro
            if total == nil,
               let range = http?.value(forHTTPHeaderField: "Content-Range"),
               let slash = range.lastIndex(of: "/") {
                total = Int(range[range.index(after: slash)...])
            }
            if total == nil && data.count < chunk { break }
        }
    }

    /// Baixa só a capa (músicas já baixadas sem capa, ou com a capa antiga não quadrada).
    /// Retorna false se não conseguiu; a capa anterior é mantida.
    @discardableResult
    static func saveArtwork(for track: RemoteTrack) async -> Bool {
        guard let data = await fetchArtwork(track) else { return false }
        return (try? data.write(to: Library.artworkURL(for: track.videoId))) != nil
    }

    /// Capa quadrada em JPEG. Músicas oficiais já vêm com capa quadrada; vídeos (clipes,
    /// "ao vivo") vêm com a miniatura do vídeo, que é recortada no centro.
    static func fetchArtwork(_ track: RemoteTrack) async -> Data? {
        for url in artworkCandidates(track) {
            guard let result = try? await URLSession.shared.data(from: url),
                  (result.1 as? HTTPURLResponse)?.statusCode == 200,
                  let square = squareJPEG(result.0)
            else { continue }
            return square
        }
        return nil
    }

    private static func artworkCandidates(_ track: RemoteTrack) -> [URL] {
        guard let thumb = track.thumbnail else { return [] }
        if thumb.contains("ytimg.com") {
            // Miniaturas maiores e sem faixas pretas, quando existem.
            let base = "https://i.ytimg.com/vi/\(track.videoId)/"
            return [base + "maxresdefault.jpg", base + "hq720.jpg", thumb].compactMap(URL.init(string:))
        }
        // Capas do YouTube Music vêm pequenas (…=w60-h60…); pede uma maior.
        let big = thumb.replacingOccurrences(of: #"=w\d+-h\d+"#, with: "=w544-h544", options: .regularExpression)
        return [big].compactMap(URL.init(string:))
    }

    private static func squareJPEG(_ data: Data) -> Data? {
        guard let cg = UIImage(data: data)?.cgImage else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        // hqdefault/sddefault são 4:3 com faixas pretas em cima e embaixo de um vídeo 16:9.
        let contentHeight = abs(w / h - 4.0 / 3.0) < 0.02 ? w * 9 / 16 : h
        let side = min(w, contentHeight)
        let rect = CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side).integral
        guard let cropped = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped).jpegData(compressionQuality: 0.9)
    }

    /// Reempacota sem recomprimir (passthrough), só adicionando os metadados.
    private static func writeTagged(_ src: URL, to dest: URL, track: RemoteTrack, artwork: Data?) async throws {
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: src), presetName: AVAssetExportPresetPassthrough) else {
            throw DownloadError.export(nil)
        }
        func item(_ id: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol) -> AVMetadataItem {
            let i = AVMutableMetadataItem()
            i.identifier = id
            i.value = value
            i.extendedLanguageTag = "und"
            return i
        }
        var metadata = [
            item(.commonIdentifierTitle, track.title as NSString),
            item(.commonIdentifierArtist, track.artist as NSString),
            item(.commonIdentifierAlbumName, track.album as NSString),
        ]
        if let artwork {
            let art = AVMutableMetadataItem()
            art.identifier = .commonIdentifierArtwork
            art.value = artwork as NSData
            art.dataType = kCMMetadataBaseDataType_JPEG as String
            metadata.append(art)
        }

        session.outputURL = dest
        session.outputFileType = .m4a
        session.metadata = metadata
        await withCheckedContinuation { continuation in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: dest)
            throw DownloadError.export(session.error)
        }
    }
}
