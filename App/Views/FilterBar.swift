import SwiftUI

struct FilterBar: View {
    @Binding var text: String
    @Environment(AppState.self) private var state

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(state.theme.textSecondary)
            TextField("Filter catalog…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(state.theme.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(state.theme.panelBackground)
    }
}
