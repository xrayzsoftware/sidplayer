import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SIDCatalog

/// Lists the user's playlists. Click one to enter `.playlist(id)` mode and see
/// its tracks. Right-click for rename / export / delete.
struct PlaylistsRootView: View {
    @Environment(AppState.self) private var state

    @State private var newSheetVisible = false
    @State private var newName = ""
    @State private var renameTarget: Playlist?
    @State private var renameText = ""

    var body: some View {
        let theme = state.theme
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("YOUR PLAYLISTS")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Button {
                    newName = ""
                    newSheetVisible = true
                } label: {
                    Label("New Playlist", systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(theme.panelBackground.opacity(0.7))

            Divider()

            if state.playlists.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("No playlists yet")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                    Text("Right-click a track in any tab and choose “Add to Playlist”.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(state.playlists) { p in
                        Button { if let id = p.id { state.enterPlaylist(id) } } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "music.note.list")
                                    .foregroundStyle(theme.textAccent)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.name)
                                        .font(.system(size: 13))
                                        .foregroundStyle(theme.textPrimary)
                                    Text("\(state.playlistCounts[p.id ?? 0] ?? 0) tracks")
                                        .font(.system(size: 10))
                                        .foregroundStyle(theme.textSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10))
                                    .foregroundStyle(theme.textSecondary)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Rename…") {
                                renameTarget = p
                                renameText = p.name
                            }
                            Button("Export as M3U…") { export(p) }
                                .disabled(state.hvscSource == nil)
                            Divider()
                            Button("Delete", role: .destructive) {
                                if let id = p.id { state.deletePlaylist(id) }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(theme.windowBackground)
                .tint(theme.textAccent)
            }
        }
        .alert("New Playlist", isPresented: $newSheetVisible) {
            TextField("Name", text: $newName)
            Button("Create") {
                _ = state.createPlaylist(name: newName)
                newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .alert(
            "Rename Playlist",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let p = renameTarget, let id = p.id {
                    state.renamePlaylist(id, to: renameText)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    private func export(_ p: Playlist) {
        guard let db = state.catalog,
              let source = state.hvscSource,
              let id = p.id else { return }
        let panel = NSSavePanel()
        if let m3u = UTType(filenameExtension: "m3u8") {
            panel.allowedContentTypes = [m3u]
        }
        panel.nameFieldStringValue = "\(p.name).m3u8"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try db.exportM3U(playlistId: id, hvscRoot: source.root)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            state.lastError = "Export failed: \(error.localizedDescription)"
        }
    }
}
