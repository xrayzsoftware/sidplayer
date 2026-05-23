import SwiftUI
import SIDCatalog

/// What auto-advance will play next: the next subtune of the current tune,
/// or — when on the last subtune / single-subtune tunes — the next track in
/// the visible list.
struct QueueBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("UP NEXT")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(state.theme.textSecondary)
                .tracking(0.5)
            HStack(spacing: 6) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(state.theme.textSecondary)
                Text(upNextText)
                    .font(.system(size: 12))
                    .foregroundStyle(state.theme.textPrimary.opacity(0.85))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(state.theme.panelBackground)
    }

    private var upNextText: String {
        if state.repeatMode == .one {
            return "repeating — \(currentTitle)"
        }
        if state.subtuneCount > 1 && state.currentSubtune < state.subtuneCount {
            return "sub \(state.currentSubtune + 1)/\(state.subtuneCount) — \(currentTitle)"
        }
        if state.shuffleEnabled {
            return "shuffle"
        }
        if let id = state.currentTuneID,
           let idx = state.sortedRows.firstIndex(where: { $0.id == id }),
           !state.sortedRows.isEmpty {
            let next = (idx + 1) % state.sortedRows.count
            let r = state.sortedRows[next].row
            return "\(r.title ?? "—") — \(r.author ?? "—")"
        }
        return "—"
    }

    private var currentTitle: String {
        guard let id = state.currentTuneID,
              let row = try? state.catalog?.tune(id: id) else { return "—" }
        return row.title ?? "—"
    }
}
