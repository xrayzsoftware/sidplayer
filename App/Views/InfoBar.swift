import SwiftUI
import SIDCatalog

struct InfoBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let row: TuneRow? = state.currentTuneID.flatMap { id in
            try? state.catalog?.tune(id: id)
        }
        HStack(spacing: 0) {
            cell(label: "CHIP",   value: row?.model ?? "—")
            cell(label: "VOICES", value: row.map { "\($0.sidChips * 3)" } ?? "—")
            cell(label: "CLOCK",  value: row?.clock ?? "—")
            cell(label: "MODEL",  value: "C64")
        }
        .frame(maxWidth: .infinity)
    }

    private func cell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(state.theme.textSecondary)
                .tracking(0.5)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(state.theme.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            Rectangle().frame(width: 1)
                .foregroundColor(state.theme.separator)
                .opacity(0.6),
            alignment: .trailing
        )
    }
}
