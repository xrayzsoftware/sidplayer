import SwiftUI
import SIDCatalog

/// The Most-Played tab: tunes ranked by cumulative play count. A dedicated
/// List (rather than the shared `Table`) so each row can show its play count —
/// conditional `Table` columns require macOS 14.4, but the deployment target is
/// 14.0. Rows are already count-ordered in `state.sortedRows`; tapping one sets
/// `selectedID`, which drives playback exactly like the table.
struct MostPlayedView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        let theme = state.theme

        if state.sortedRows.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "chart.bar")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("Nothing played yet")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                Text("Your most-played tunes will appear here as you listen.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.windowBackground)
        } else {
            List(selection: $state.selectedID) {
                ForEach(Array(state.sortedRows.enumerated()), id: \.element.id) { idx, item in
                    row(rank: idx + 1, item: item, theme: theme)
                        .tag(item.id)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.windowBackground)
            .tint(theme.textAccent)
        }
    }

    @ViewBuilder
    private func row(rank: Int, item: TuneItem, theme: AppTheme) -> some View {
        let plays = state.playCounts[item.id] ?? 0
        HStack(spacing: 10) {
            Text("\(rank)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 26, alignment: .trailing)

            if state.currentTuneID == item.id {
                Image(systemName: state.isPlaying ? "play.fill" : "pause.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textAccent)
                    .frame(width: 12)
            } else {
                Color.clear.frame(width: 12)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(item.row.title ?? "—")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textPrimary)
                Text(item.row.author ?? "—")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textSecondary)
            }

            Spacer()

            Text("\(plays) play\(plays == 1 ? "" : "s")")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 1)
        .contextMenu {
            Button {
                state.toggleFavorite(item.id)
            } label: {
                Label(state.favoriteIDs.contains(item.id) ? "Remove from Favorites"
                                                           : "Add to Favorites",
                      systemImage: "star")
            }
            Menu("Add to Playlist") {
                if state.playlists.isEmpty {
                    Text("No playlists yet")
                } else {
                    ForEach(state.playlists) { p in
                        if let pid = p.id {
                            Button(p.name) { state.addToPlaylist(playlistID: pid, tuneID: item.id) }
                        }
                    }
                }
            }
        }
    }
}
