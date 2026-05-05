import SwiftUI
import SIDCatalog

struct NowPlayingHeader: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let row: TuneRow? = state.currentTuneID.flatMap { id in
            try? state.catalog?.tune(id: id)
        }
        VStack(alignment: .leading, spacing: 2) {
            Text(row?.title ?? "—")
                .font(.system(size: 15, weight: .semibold))
            HStack(spacing: 12) {
                Text(row?.author ?? "")
                    .foregroundStyle(.secondary)
                Text("sub: \(state.currentSubtune > 0 ? state.currentSubtune - 1 : 0)")
                    .foregroundStyle(.secondary)
                Text(row?.model ?? "—")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
