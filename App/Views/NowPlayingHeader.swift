import SwiftUI
import SIDCatalog

struct NowPlayingHeader: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let row: TuneRow? = state.currentTuneID.flatMap { id in
            try? state.catalog?.tune(id: id)
        }
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
                    openWindow(id: "mini-player")
                    // Delay so the mini player window appears and gets tagged first.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        MiniPlayerView.hideMainWindow()
                    }
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

                Button { state.showSettingsSheet = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16))
                        .foregroundStyle(state.theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Library settings")
            }
        }
    }

    private var bullet: some View {
        Text("·")
            .foregroundStyle(state.theme.textSecondary.opacity(0.6))
    }
}
