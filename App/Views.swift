import SwiftUI
import UniformTypeIdentifiers

// Visual propositalmente simples: a etapa 1 serve para testar importação e reprodução.

struct LibraryView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var showingNowPlaying = false

    var body: some View {
        NavigationStack {
            Group {
                if library.tracks.isEmpty { emptyState } else { trackList }
            }
            .navigationTitle("Músicas")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { importing = true } label: { Image(systemName: "plus") }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if player.current != nil {
                MiniPlayer { showingNowPlaying = true }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await library.importFiles(urls) }
            }
        }
        .sheet(isPresented: $showingNowPlaying) {
            NowPlayingView()
                .environmentObject(player)
        }
        .task { await library.reload() }
        // Arquivos copiados pelo app Arquivos aparecem ao voltar para o app.
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await library.reload() } }
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

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Nenhuma música ainda")
                .font(.headline)
            Text("Toque em + para importar arquivos de áudio, ou copie para Arquivos → No Meu iPhone → BetterYTM → Music.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Importar músicas") { importing = true }
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
            .padding(.vertical, 10)
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
                Spacer()
            }
            .padding(.horizontal, 32)
            .presentationDragIndicator(.visible)
        }
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds)
    return String(format: "%d:%02d", s / 60, s % 60)
}
