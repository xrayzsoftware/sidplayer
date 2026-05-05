import SwiftUI

struct TabBarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 0) {
            tab(.all,        title: "All",       icon: "magnifyingglass")
            tab(.favorites,  title: "Favorites", icon: "star.fill",
                badge: state.favoriteIDs.isEmpty ? nil : "\(state.favoriteIDs.count)")
            tab(.browse,     title: "Browse",    icon: "folder.fill")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(state.theme.panelBackground)
    }

    private func tab(_ mode: AppState.BrowseMode,
                     title: String,
                     icon: String,
                     badge: String? = nil) -> some View {
        let selected = state.browseMode == mode
        let theme = state.theme
        return Button {
            state.setBrowseMode(mode)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(theme.textSecondary.opacity(0.25)))
                }
            }
            .foregroundStyle(selected ? theme.textPrimary : theme.textSecondary)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? theme.selection : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}
