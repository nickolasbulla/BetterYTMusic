import SwiftUI
import AVFoundation

@main
struct BetterYTMusicApp: App {
    init() {
        // Modo playback: continua tocando em segundo plano, com tela bloqueada e no modo silencioso.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            print("AVAudioSession error: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MusicWebView()
        }
        .preferredColorScheme(.dark)
    }
}
