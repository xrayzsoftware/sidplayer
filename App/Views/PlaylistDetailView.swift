import SwiftUI

/// Shows the tracks of the playlist currently selected via `.playlist(id)`.
/// Reuses TrackListView; adds a small breadcrumb header that returns to the
/// playlist picker.
struct PlaylistDetailView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let theme = state.theme
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    state.setBrowseMode(.playlists)
                } label: {
                    Label("Playlists", systemImage: "chevron.left")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

                Text("/")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                Text(currentName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)

                Spacer()

                Text("\(state.rows.count) tracks")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(theme.panelBackground.opacity(0.7))

            Divider()
            TrackListView()
        }
    }

    private var currentName: String {
        if case .playlist(let id) = state.browseMode,
           let p = state.playlists.first(where: { $0.id == id }) {
            return p.name
        }
        return "Playlist"
    }
}
