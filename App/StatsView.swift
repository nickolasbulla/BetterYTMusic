import SwiftUI

struct StatsView: View {
    @EnvironmentObject var stats: Stats
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @State private var confirmingReset = false

    var body: some View {
        let top = stats.topTracks(25)
        let artists = stats.topArtists(10)

        NavigationStack {
            List {
                if !top.isEmpty {
                    Section {
                        HStack {
                            StatTile(value: formatDuration(stats.totalSeconds), label: "ouvidos")
                            StatTile(value: "\(stats.totalPlays)", label: "reproduções")
                            StatTile(value: "\(stats.entries.values.filter { $0.plays > 0 }.count)", label: "músicas")
                        }
                        .listRowBackground(Color.clear)
                    }

                    Section("Mais tocadas") {
                        ForEach(Array(top.enumerated()), id: \.element.id) { i, item in
                            let local = library.track(id: item.id)
                            Button {
                                // Toca a lista de mais tocadas a partir desta (só as que ainda estão no iPhone).
                                let playable = top.compactMap { library.track(id: $0.id) }
                                if let local, let start = playable.firstIndex(of: local) {
                                    player.play(playable, startAt: start)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Text("\(i + 1)")
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 24)
                                    Artwork(image: local?.artwork, size: 44)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.entry.title).lineLimit(1)
                                        Text(item.entry.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("\(item.entry.plays)×").font(.subheadline.bold())
                                        Text(formatDuration(item.entry.seconds)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .foregroundStyle(local == nil ? .secondary : .primary)
                            }
                            .disabled(local == nil)
                        }
                    }

                    Section("Artistas") {
                        ForEach(Array(artists.enumerated()), id: \.element.id) { i, artist in
                            HStack(spacing: 12) {
                                Text("\(i + 1)")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                Text(artist.name).lineLimit(1)
                                Spacer()
                                Text(formatDuration(artist.seconds)).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .miniPlayerSpacing()
            .overlay {
                if top.isEmpty {
                    EmptyState(
                        icon: "chart.bar.fill",
                        title: "Nada por aqui ainda",
                        message: "Uma música entra nas estatísticas depois de tocar por 30 segundos (ou metade dela, se for curta).",
                        action: nil
                    )
                }
            }
            .navigationTitle("Estatísticas")
            .toolbar {
                if !top.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Zerar") { confirmingReset = true }
                    }
                }
            }
            .confirmationDialog("Zerar estatísticas?", isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("Zerar", role: .destructive) { stats.reset() }
            } message: {
                Text("Todo o histórico de reproduções e tempo ouvido será apagado. As músicas não são afetadas.")
            }
        }
        .miniPlayer()
    }
}

private struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
}
