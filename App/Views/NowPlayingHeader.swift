import SwiftUI
import SIDCatalog

struct NowPlayingHeader: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @State private var showCSDb = false
    /// Cached catalog row for the playing tune; `body` re-runs on every
    /// subtune/theme/toggle change and must not hit SQLite each time.
    @State private var row: TuneRow?

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row?.title ?? "—")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(state.theme.textPrimary)
                HStack(spacing: 8) {
                    if let author = row?.author, !author.isEmpty {
                        Text(author)
                    }
                    if state.subtuneCount > 1 {
                        bullet
                        Text("sub \(state.currentSubtune)/\(state.subtuneCount)")
                            .monospacedDigit()
                    }
                    if let model = row?.model, model != "—" {
                        bullet
                        Text(model)
                    }
                    if let clock = row?.clock, clock != "—" {
                        bullet
                        Text(clock)
                    }
                    if let row, row.sidChips * 3 > 0 {
                        bullet
                        Text("\(row.sidChips * 3) voices")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(state.theme.textSecondary)
            }

            Spacer()

            HStack(spacing: 14) {
                Button {
                    // MiniPlayerView.onAppear hides the main window; a second
                    // delayed hide here could fire after the mini player had
                    // already closed and leave the app with no windows.
                    openWindow(id: "mini-player")
                } label: {
                    Image(systemName: "rectangle.inset.filled")
                        .font(.system(size: 16))
                        .foregroundStyle(state.theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Open Mini Player")

                Button { state.toggleVisualizers() } label: {
                    Image(systemName: state.showVisualizers ? "waveform" : "waveform.slash")
                        .font(.system(size: 16))
                        .foregroundStyle(state.showVisualizers
                                         ? state.theme.textAccent
                                         : state.theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(state.showVisualizers
                      ? "Hide visualizers (saves CPU)"
                      : "Show visualizers")

                Button { state.toggleScroller() } label: {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 16))
                        .foregroundStyle(state.showScroller
                                         ? state.theme.textAccent
                                         : state.theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(state.showScroller ? "Hide STIL scroller" : "Show STIL scroller")

                Button { showCSDb = true } label: {
                    Image(systemName: "globe")
                        .font(.system(size: 16))
                        .foregroundStyle(state.theme.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(row == nil)
                .help("Look up on CSDb (csdb.dk)")

                Button { state.showSettingsSheet = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16))
                        .foregroundStyle(state.theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Library settings")
            }
        }
        .sheet(isPresented: $showCSDb) {
            CSDbPanel(path: row?.path ?? "", title: row?.title)
                .environment(state)
        }
        .task(id: state.currentTuneID) {
            row = state.currentTuneID.flatMap { try? state.catalog?.tune(id: $0) }
        }
    }

    private var bullet: some View {
        Text("·")
            .foregroundStyle(state.theme.textSecondary.opacity(0.6))
    }
}
