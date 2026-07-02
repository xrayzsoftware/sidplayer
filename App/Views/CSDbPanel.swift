import SwiftUI

/// Sheet showing the playing tune's csdb.dk entry: the SID's name/author/year
/// and the demoscene releases it was used in. Resolution is best-effort (CSDb
/// has no path lookup, so we scrape its search) and cached, so a miss is normal.
struct CSDbPanel: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let path: String
    let title: String?

    @State private var entry: CSDbEntry?
    @State private var loading = true

    var body: some View {
        let theme = state.theme
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("CSDb")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text("csdb.dk")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Button("Done") { dismiss() }
                    .controlSize(.small)
            }
            .padding(12)

            Divider()

            Group {
                if loading {
                    centered { ProgressView("Looking up csdb.dk…").controlSize(.small) }
                } else if let e = entry, e.found {
                    content(e)
                } else if entry == nil {
                    // Transient: csdb.dk didn't answer (it 503s under load).
                    centered {
                        VStack(spacing: 8) {
                            Image(systemName: "wifi.exclamationmark")
                                .font(.system(size: 30))
                                .foregroundStyle(.tertiary)
                            Text("Couldn’t reach csdb.dk")
                                .font(.system(size: 13))
                                .foregroundStyle(theme.textSecondary)
                            Text("The service didn’t respond (it’s often busy). Try again in a moment.")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textSecondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 300)
                            Button("Retry") { Task { await load() } }
                                .controlSize(.small)
                                .padding(.top, 2)
                        }
                    }
                } else {
                    centered {
                        VStack(spacing: 8) {
                            Image(systemName: "questionmark.folder")
                                .font(.system(size: 30))
                                .foregroundStyle(.tertiary)
                            Text("No CSDb entry found")
                                .font(.system(size: 13))
                                .foregroundStyle(theme.textSecondary)
                            Text("This tune isn’t linked on csdb.dk, or the lookup couldn’t match it.")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textSecondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 300)
                        }
                    }
                }
            }
        }
        .frame(width: 440, height: 480)
        .background(theme.windowBackground)
        // id: path — auto-advance can change the track while the sheet is
        // open; without the id the task never re-runs and the panel keeps
        // showing the previous tune's releases.
        .task(id: path) { await load() }
    }

    @ViewBuilder
    private func content(_ e: CSDbEntry) -> some View {
        let theme = state.theme
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(e.name ?? title ?? "—")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                HStack(spacing: 8) {
                    if let a = e.author, !a.isEmpty { Text(a) }
                    if let r = e.released, !r.isEmpty {
                        Text("·").foregroundStyle(theme.textSecondary.opacity(0.6))
                        Text(r)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)

                if let url = e.pageURL {
                    Button {
                        openURL(url)
                    } label: {
                        Label("View on CSDb", systemImage: "arrow.up.right.square")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
            .padding(12)

            Divider()

            HStack {
                Text("USED IN \(e.releases.count) RELEASE\(e.releases.count == 1 ? "" : "S")")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(theme.panelBackground.opacity(0.7))

            if e.releases.isEmpty {
                centered {
                    Text("Not used in any catalogued release.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }
            } else {
                List(e.releases) { rel in
                    Button { if let u = rel.url { openURL(u) } } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(rel.name)
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.textPrimary)
                                Text(rel.type)
                                    .font(.system(size: 10))
                                    .foregroundStyle(theme.textSecondary)
                            }
                            Spacer()
                            if let y = rel.year {
                                Text(String(y))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(theme.textSecondary)
                            }
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9))
                                .foregroundStyle(theme.textSecondary)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
                .scrollContentBackground(.hidden)
                .background(theme.windowBackground)
            }
        }
    }

    private func centered<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        loading = true
        entry = await state.csdb?.entry(forHVSCPath: path, title: title)
        loading = false
    }
}
