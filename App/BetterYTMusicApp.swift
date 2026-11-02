import SwiftUI

@main
struct BetterYTMusicApp: App {
    @StateObject private var library = Library()
    @StateObject private var player = Player()
    @StateObject private var syncer = Syncer()
    @StateObject private var stats = Stats()
    @StateObject private var suggester = Suggester()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(syncer)
                .environmentObject(stats)
                .environmentObject(suggester)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var syncer: Syncer
    @EnvironmentObject var player: Player
    @EnvironmentObject var stats: Stats
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            PlaylistsView()
                .tabItem { Label("Playlists", systemImage: "music.note.list") }
            LibraryView()
                .tabItem { Label("Músicas", systemImage: "music.note") }
            StatsView()
                .tabItem { Label("Estatísticas", systemImage: "chart.bar.fill") }
        }
        .task {
            player.stats = stats
            library.apply(remote: syncer.allTracks)
            await library.reload()
            // Reabre na última música, no mesmo ponto, com os mesmos modos (pausado).
            player.restore { library.track(id: $0) }
        }
        // Arquivos copiados pelo app Arquivos aparecem ao voltar para o app.
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await library.reload() } }
        }
    }
}
