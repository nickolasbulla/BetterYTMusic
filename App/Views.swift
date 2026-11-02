import SwiftUI
import UniformTypeIdentifiers

// Visual propositalmente simples por enquanto.

// MARK: - Playlists (sincronizadas do YouTube Music)

struct PlaylistsView: View {
    @EnvironmentObject var syncer: Syncer
    @EnvironmentObject var library: Library
    @State private var addingLink = false
    @State private var linkText = ""

    var body: some View {
        NavigationStack {
            List {
                if let status = syncer.status {
                    Section {
                        HStack(spacing: 10) {
                            if syncer.isSyncing { ProgressView() }
                            Text(status).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    ForEach(syncer.playlists) { playlist in
                        NavigationLink(value: playlist.id) {
                            PlaylistRow(playlist: playlist)
                        }
                    }
                    .onDelete { syncer.removePlaylists(at: $0, library: library) }
                }
            }
            .overlay {
                if syncer.playlists.isEmpty && !syncer.isSyncing {
                    EmptyState(
                        icon: "music.note.list",
                        title: "Nenhuma playlist",
                        message: "Toque em + e cole o link de uma playlist (pública ou não listada) ou do seu perfil (@nome).",
                        action: ("Adicionar link", { addingLink = true })
                    )
                }
            }
            .navigationTitle("Playlists")
            .navigationDestination(for: String.self) { PlaylistDetailView(playlistID: $0) }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        Task { await syncer.sync(library: library) }
                    } label: {
                        Label("Atualizar playlists", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(syncer.isSyncing)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { addingLink = true } label: { Image(systemName: "plus") }
                }
            }
            .alert("Adicionar link", isPresented: $addingLink) {
                TextField("https://music.youtube.com/playlist?list=…", text: $linkText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Adicionar") {
                    if syncer.addLink(linkText) {
                        Task { await syncer.sync(library: library) }
                    }
                    linkText = ""
                }
                Button("Cancelar", role: .cancel) { linkText = "" }
            } message: {
                Text("Link de uma playlist ou do seu perfil (@nome).")
            }
        }
        .miniPlayer()
    }
}

struct PlaylistRow: View {
    @EnvironmentObject var library: Library
    let playlist: RemotePlaylist

    var body: some View {
        let downloaded = playlist.tracks.filter { library.track(videoID: $0.videoId) != nil }.count
        HStack(spacing: 12) {
            Artwork(image: playlist.tracks.lazy.compactMap { library.track(videoID: $0.videoId)?.artwork }.first,
                    size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title).font(.body).lineLimit(1)
                Text("\(playlist.tracks.count) músicas · \(downloaded) baixadas")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PlaylistDetailView: View {
    @EnvironmentObject var syncer: Syncer
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    let playlistID: String

    var body: some View {
        if let playlist = syncer.playlists.first(where: { $0.id == playlistID }) {
            let playable = playlist.tracks.compactMap { library.track(videoID: $0.videoId) }
            List(Array(playlist.tracks.enumerated()), id: \.offset) { item in
                let remote = item.element
                if let local = library.track(videoID: remote.videoId) {
                    Button {
                        player.play(playable, startAt: playable.firstIndex(of: local) ?? 0)
                    } label: {
                        TrackRow(track: local, isCurrent: player.current == local)
                    }
                } else {
                    // Ainda não baixada.
                    HStack(spacing: 12) {
                        Artwork(image: nil, size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(remote.title).lineLimit(1)
                            Text(remote.artist).font(.subheadline).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "icloud.and.arrow.down")
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .miniPlayerSpacing()
            .navigationTitle(playlist.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        player.playShuffled(playable)
                    } label: {
                        Image(systemName: "shuffle")
                    }
                    .disabled(playable.isEmpty)
                }
            }
        }
    }
}

// MARK: - Todas as músicas

struct LibraryView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Group {
                if library.tracks.isEmpty {
                    EmptyState(
                        icon: "music.note",
                        title: "Nenhuma música ainda",
                        message: "Atualize as playlists, toque em + para importar arquivos, ou copie para Arquivos → No Meu iPhone → BetterYTM → Music.",
                        action: ("Importar músicas", { importing = true })
                    )
                } else {
                    trackList
                }
            }
            .navigationTitle("Músicas")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { importing = true } label: { Image(systemName: "plus") }
                }
            }
        }
        .miniPlayer()
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await library.importFiles(urls) }
            }
        }
    }

    private var trackList: some View {
        List {
            ForEach(Array(library.tracks.enumerated()), id: \.element.id) { i, track in
                Button {
                    player.play(library.tracks, startAt: i)
                } label: {
                    TrackRow(track: track, isCurrent: player.current == track)
                }
            }
            .onDelete { offsets in
                let doomed = offsets.map { library.tracks[$0] }
                doomed.forEach { library.delete($0) }
            }
        }
        .listStyle(.plain)
        .refreshable { await library.reload() }
    }
}

// MARK: - Componentes

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    let action: (String, () -> Void)

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action.0, action: action.1)
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}

struct TrackRow: View {
    let track: Track
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            Artwork(image: track.artwork, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }
}

struct Artwork: View {
    let image: UIImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.gray.opacity(0.25)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.12))
    }
}

// MARK: - Player

extension View {
    /// Mini player fixo embaixo, que abre a tela "tocando agora".
    func miniPlayer() -> some View { modifier(MiniPlayerInset()) }

    /// Telas abertas dentro de uma navegação não herdam o espaço do mini player;
    /// sem isso a última linha da lista fica escondida atrás dele.
    func miniPlayerSpacing() -> some View { modifier(MiniPlayerSpacing()) }
}

private let miniPlayerHeight: CGFloat = 64

struct MiniPlayerSpacing: ViewModifier {
    @EnvironmentObject var player: Player

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if player.current != nil {
                Color.clear.frame(height: miniPlayerHeight)
            }
        }
    }
}

struct MiniPlayerInset: ViewModifier {
    @EnvironmentObject var player: Player
    @State private var showingNowPlaying = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                if player.current != nil {
                    MiniPlayer { showingNowPlaying = true }
                }
            }
            .sheet(isPresented: $showingNowPlaying) {
                NowPlayingView().environmentObject(player)
            }
    }
}

struct MiniPlayer: View {
    @EnvironmentObject var player: Player
    let onOpen: () -> Void

    var body: some View {
        if let track = player.current {
            HStack(spacing: 12) {
                Artwork(image: track.artwork, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.subheadline.bold()).lineLimit(1)
                    Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                }
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.title3)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .frame(height: miniPlayerHeight)
            .background(.bar)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
        }
    }
}

struct NowPlayingView: View {
    @EnvironmentObject var player: Player
    @State private var scrub: Double?

    var body: some View {
        if let track = player.current {
            VStack(spacing: 24) {
                Spacer()
                Artwork(image: track.artwork, size: 300)
                    .shadow(radius: 20)
                VStack(spacing: 4) {
                    Text(track.title).font(.title2.bold()).lineLimit(2).multilineTextAlignment(.center)
                    Text(track.artist).font(.title3).foregroundStyle(.secondary).lineLimit(1)
                }
                VStack(spacing: 4) {
                    Slider(
                        value: Binding(get: { scrub ?? player.currentTime }, set: { scrub = $0 }),
                        in: 0...max(track.duration, 1),
                        onEditingChanged: { editing in
                            if !editing, let s = scrub {
                                player.seek(to: s)
                                scrub = nil
                            }
                        }
                    )
                    HStack {
                        Text(formatTime(scrub ?? player.currentTime))
                        Spacer()
                        Text(formatTime(track.duration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                HStack(spacing: 48) {
                    Button { player.previous() } label: { Image(systemName: "backward.fill") }
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 72))
                    }
                    Button { player.next() } label: { Image(systemName: "forward.fill") }
                }
                .font(.title)
                .foregroundStyle(.primary)
                HStack {
                    Button { player.toggleShuffle() } label: {
                        Image(systemName: "shuffle")
                    }
                    .foregroundStyle(player.isShuffled ? Color.accentColor : Color.secondary)
                    .accessibilityLabel(player.isShuffled ? "Aleatório ligado" : "Aleatório desligado")
                    Spacer()
                    Button { player.cycleRepeat() } label: {
                        Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    }
                    .foregroundStyle(player.repeatMode == .off ? Color.secondary : Color.accentColor)
                    .accessibilityLabel(repeatLabel)
                }
                .font(.title3)
                .padding(.horizontal, 24)
                Spacer()
            }
            .padding(.horizontal, 32)
            .presentationDragIndicator(.visible)
        }
    }

    private var repeatLabel: String {
        switch player.repeatMode {
        case .off: return "Repetir desligado"
        case .all: return "Repetir playlist"
        case .one: return "Repetir música"
        }
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds)
    return String(format: "%d:%02d", s / 60, s % 60)
}
