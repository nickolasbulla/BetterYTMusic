import SwiftUI

@main
struct BetterYTMusicApp: App {
    @StateObject private var library = Library()
    @StateObject private var player = Player()
    @StateObject private var syncer = Syncer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(syncer)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var syncer: Syncer
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            PlaylistsView()
                .tabItem { Label("Playlists", systemImage: "music.note.list") }
            LibraryView()
                .tabItem { Label("Músicas", systemImage: "music.note") }
        }
        .task {
            library.apply(remote: syncer.allTracks)
            await library.reload()
        }
        // Arquivos copiados pelo app Arquivos aparecem ao voltar para o app.
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await library.reload() } }
        }
    }
}
