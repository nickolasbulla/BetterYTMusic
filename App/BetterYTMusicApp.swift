import SwiftUI

@main
struct BetterYTMusicApp: App {
    @StateObject private var library = Library()
    @StateObject private var player = Player()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .environmentObject(player)
                .preferredColorScheme(.dark)
        }
    }
}
