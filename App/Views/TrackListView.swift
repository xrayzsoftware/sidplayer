import SwiftUI
import SIDCatalog

struct TrackListView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        Table(state.rows, selection: $state.selectedID) {
            TableColumn("#") { item in
                Text(String(format: "%02d", item.id))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }.width(min: 36, ideal: 40, max: 50)

            TableColumn("Title") { item in
                Text(item.row.title ?? "—")
                    .font(.system(size: 13))
            }

            TableColumn("Sub") { _ in
                Text("0")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }.width(min: 28, ideal: 32, max: 40)

            TableColumn("Time") { item in
                Text(formatMs(item.row.defaultLengthMs ?? 0))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }.width(min: 56, ideal: 60, max: 80)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .onChange(of: state.selectedID) { _, newID in
            guard let id = newID else { return }
            Task { await state.play(tuneID: id) }
        }
    }

    private func formatMs(_ ms: Int) -> String {
        let total = ms / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
