import SwiftUI
import UniformTypeIdentifiers

// MARK: - Playlists (sincronizadas do YouTube Music)

struct PlaylistsView: View {
    @EnvironmentObject var syncer: Syncer
    @EnvironmentObject var library: Library
    @State private var addingLink = false
    @State private var linkText = ""
    @State private var pendingRemoval: RemotePlaylist?
    @State private var query = ""

    private var visiblePlaylists: [RemotePlaylist] {
        query.isEmpty ? syncer.playlists : syncer.playlists.filter { $0.title.localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let status = syncer.status, query.isEmpty {
                    Section {
                        HStack(spacing: 10) {
                            if syncer.isSyncing { ProgressView() }
                            Text(status).font(.footnote).foregroundStyle(.secondary)
                        }
                        .listRowBackground(Theme.surface)
                    }
                }
                Section {
                    ForEach(visiblePlaylists) { playlist in
                        NavigationLink(value: playlist.id) {
                            PlaylistRow(playlist: playlist)
                        }
                        // Remover só pelo toque longo + confirmação (arrastar apagava sem querer).
                        .contextMenu {
                            Button(role: .destructive) {
                                pendingRemoval = playlist
                            } label: {
                                Label("Remover playlist", systemImage: "trash")
                            }
                        }
                        .listRowBackground(Theme.surface)
                    }
                }
            }
            .themedBackground()
            .miniPlayerSpacing()
            .searchable(text: $query, prompt: "Buscar playlists")
            .confirmationDialog(
                "Remover “\(pendingRemoval?.title ?? "")”?",
                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                titleVisibility: .visible,
                presenting: pendingRemoval
            ) { playlist in
                Button("Remover", role: .destructive) {
                    syncer.removePlaylist(playlist, library: library)
                }
            } message: { _ in
                Text("As músicas baixadas dela que não estão em outra playlist serão apagadas do iPhone. Você pode adicionar o link de novo depois.")
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
    @State private var query = ""

    var body: some View {
        if let playlist = syncer.playlists.first(where: { $0.id == playlistID }) {
            let playable = playlist.tracks.compactMap { library.track(videoID: $0.videoId) }
            let visible = query.isEmpty ? playlist.tracks : playlist.tracks.filter {
                $0.title.localizedStandardContains(query) || $0.artist.localizedStandardContains(query)
            }
            List(Array(visible.enumerated()), id: \.offset) { item in
                let remote = item.element
                Group {
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
                .listRowBackground(Theme.background)
            }
            .listStyle(.plain)
            .themedBackground()
            .miniPlayerSpacing()
            .searchable(text: $query, prompt: "Buscar nesta playlist")
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
    @EnvironmentObject var syncer: Syncer
    @State private var importing = false
    @State private var pendingRemoval: Track?
    @State private var query = ""

    private var visibleTracks: [Track] {
        query.isEmpty ? library.tracks : library.tracks.filter { t in
            [t.title, t.artist, t.album].contains { $0.localizedStandardContains(query) }
        }
    }

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
            .themedBackground()
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
            ForEach(Array(visibleTracks.enumerated()), id: \.element.id) { i, track in
                Button {
                    player.play(visibleTracks, startAt: i)
                } label: {
                    TrackRow(track: track, isCurrent: player.current == track)
                }
                // Apagar só pelo toque longo + confirmação, como nas playlists.
                .contextMenu {
                    Button(role: .destructive) {
                        pendingRemoval = track
                    } label: {
                        Label("Apagar música", systemImage: "trash")
                    }
                }
                .listRowBackground(Theme.background)
            }
        }
        .listStyle(.plain)
        .themedBackground()
        .miniPlayerSpacing()
        .searchable(text: $query, prompt: "Buscar músicas, artistas, álbuns")
        .refreshable { await library.reload() }
        .confirmationDialog(
            "Apagar “\(pendingRemoval?.title ?? "")”?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { track in
            Button("Apagar", role: .destructive) { library.delete(track) }
        } message: { track in
            Text(isSynced(track)
                 ? "O arquivo será apagado do iPhone. Como a música está numa playlist sincronizada, ela será baixada de novo no próximo Atualizar."
                 : "O arquivo será apagado do iPhone.")
        }
    }

    private func isSynced(_ track: Track) -> Bool {
        syncer.allTracks.contains { Syncer.fileName(for: $0.videoId) == track.id }
    }
}

// MARK: - Componentes

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    let action: (String, () -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(Theme.accent.opacity(0.8))
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.borderedProminent)
            }
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
                    .foregroundStyle(isCurrent ? Theme.accent : .primary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(Theme.accent)
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

    /// As listas não herdam o espaço do mini player (ele fica por cima da NavigationStack);
    /// sem isso a última linha fica escondida atrás dele. Use em toda lista.
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
            .overlay(alignment: .top) {
                GeometryReader { geo in
                    let progress = track.duration > 0 ? min(player.currentTime / track.duration, 1) : 0
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(width: geo.size.width * progress, height: 2)
                }
                .frame(height: 2)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
        }
    }
}

struct NowPlayingView: View {
    @EnvironmentObject var player: Player
    @State private var scrub: Double?
    @State private var tint: Color = Theme.background

    var body: some View {
        ZStack {
            // Fundo na cor da capa, escurecendo para baixo.
            LinearGradient(colors: [tint, Theme.background], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: tint)
            if let track = player.current {
                GeometryReader { geo in
                    content(track, artworkSide: min(geo.size.width - 64, 380))
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .task(id: player.current?.id) {
            tint = player.current?.artwork?.themeTint.map { Color(uiColor: $0) } ?? Theme.background
        }
        .environment(\.colorScheme, .dark)
        .presentationDragIndicator(.visible)
    }

    private func content(_ track: Track, artworkSide: CGFloat) -> some View {
        VStack(spacing: 28) {
            Spacer(minLength: 8)
            Artwork(image: track.artwork, size: artworkSide)
                .scaleEffect(player.isPlaying ? 1 : 0.86)
                .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
                .animation(.spring(response: 0.45, dampingFraction: 0.7), value: player.isPlaying)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title).font(.title2.bold()).lineLimit(1)
                Text(track.artist).font(.title3).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            controls(track)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 32)
        .foregroundStyle(.white)
    }

    private func controls(_ track: Track) -> some View {
        VStack(spacing: 28) {
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
                .tint(.white)
                HStack {
                    Text(formatTime(scrub ?? player.currentTime))
                    Spacer()
                    Text("-" + formatTime(max(track.duration - (scrub ?? player.currentTime), 0)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
            }
            HStack {
                Button { player.toggleShuffle() } label: { Image(systemName: "shuffle") }
                    .foregroundStyle(player.isShuffled ? Theme.accent : Theme.secondaryText)
                    .accessibilityLabel(player.isShuffled ? "Aleatório ligado" : "Aleatório desligado")
                Spacer()
                Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title) }
                Spacer()
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 76))
                        .symbolRenderingMode(.hierarchical)
                }
                Spacer()
                Button { player.next() } label: { Image(systemName: "forward.fill").font(.title) }
                Spacer()
                Button { player.cycleRepeat() } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                }
                .foregroundStyle(player.repeatMode == .off ? Theme.secondaryText : Theme.accent)
                .accessibilityLabel(repeatLabel)
            }
            .font(.title3)
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
