import SwiftUI

struct BrowseView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbBar()
            Divider()

            if state.browseDirs.isEmpty && state.rows.isEmpty {
                Text("Empty folder")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                BrowseList()
            }
        }
    }
}

private struct BreadcrumbBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 4) {
            Button {
                state.setBrowsePath("")
            } label: {
                Image(systemName: "house.fill")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("HVSC root")

            ForEach(crumbs, id: \.path) { crumb in
                Text("/")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                Button {
                    state.setBrowsePath(crumb.path)
                } label: {
                    Text(crumb.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(state.theme.panelBackground.opacity(0.7))
    }

    private var crumbs: [(name: String, path: String)] {
        guard !state.browsePath.isEmpty else { return [] }
        var acc = ""
        var out: [(String, String)] = []
        for seg in state.browsePath.split(separator: "/") {
            acc = acc.isEmpty ? String(seg) : "\(acc)/\(seg)"
            out.append((String(seg), acc))
        }
        return out
    }
}

private struct BrowseList: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        let theme = state.theme

        List(selection: $state.selectedID) {
            if !state.browsePath.isEmpty {
                Button { state.browseUp() } label: {
                    Label("..", systemImage: "arrow.turn.left.up")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain)
            }

            if !state.browseDirs.isEmpty {
                Section {
                    ForEach(state.browseDirs, id: \.self) { name in
                        Button { state.enterBrowseDir(name) } label: {
                            Label(name, systemImage: "folder.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(theme.textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !state.rows.isEmpty {
                Section {
                    ForEach(state.rows) { item in
                        HStack(spacing: 8) {
                            Button { state.toggleFavorite(item.id) } label: {
                                Image(systemName: state.favoriteIDs.contains(item.id) ? "star.fill" : "star")
                                    .foregroundStyle(state.favoriteIDs.contains(item.id) ? theme.star : theme.textSecondary)
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)

                            Image(systemName: "music.note")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textSecondary)

                            Text(item.row.title ?? "—")
                                .font(.system(size: 13))
                                .foregroundStyle(theme.textPrimary)

                            Spacer()

                            if let ms = item.row.defaultLengthMs {
                                Text(formatMs(ms))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(theme.textSecondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            state.selectedID = item.id
                            Task { await state.play(tuneID: item.id) }
                        }
                        .tag(item.id)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.windowBackground)
        .tint(theme.textAccent)
    }

    private func formatMs(_ ms: Int) -> String {
        let total = ms / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
