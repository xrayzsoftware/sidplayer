import SwiftUI
import SIDCatalog

struct QueueBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let row: TuneRow? = state.currentTuneID.flatMap { id in
            try? state.catalog?.tune(id: id)
        }

        VStack(alignment: .leading, spacing: 2) {
            Text("QUEUE")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
                Text(row?.title ?? "—")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
