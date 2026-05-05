import SwiftUI
import SIDCatalog

struct NowPlayingHeader: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let row: TuneRow? = state.currentTuneID.flatMap { id in
            try? state.catalog?.tune(id: id)
        }
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row?.title ?? "—")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(state.theme.textPrimary)
                HStack(spacing: 12) {
                    Text(row?.author ?? "")
                        .foregroundStyle(state.theme.textSecondary)
                    if state.subtuneCount > 1 {
                        Text("sub \(state.currentSubtune)/\(state.subtuneCount)")
                            .foregroundStyle(state.theme.textSecondary)
                            .monospacedDigit()
                    }
                    Text(row?.model ?? "—")
                        .foregroundStyle(state.theme.textSecondary)
                }
                .font(.system(size: 12))
            }

            Spacer()

            Button { state.toggleScroller() } label: {
                Image(systemName: state.showScroller
                                  ? "text.alignleft"
                                  : "text.alignleft")
                    .font(.system(size: 16))
                    .foregroundStyle(state.showScroller
                                     ? state.theme.textAccent
                                     : state.theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help(state.showScroller ? "Hide STIL scroller" : "Show STIL scroller")
        }
    }
}
