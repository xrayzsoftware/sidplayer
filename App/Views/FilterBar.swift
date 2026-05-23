import SwiftUI

struct FilterBar: View {
    @Binding var text: String
    @Environment(AppState.self) private var state
    @State private var showFilters = false

    var body: some View {
        let theme = state.theme

        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(theme.textSecondary)
                TextField("Filter catalog…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textPrimary)

                if state.hasActiveFilters {
                    Button { state.clearFilters() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear all filters")
                }

                Button { withAnimation(.easeInOut(duration: 0.15)) { showFilters.toggle() } } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(state.hasActiveFilters
                            ? theme.textAccent
                            : theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Show/hide filters")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if showFilters {
                HStack(spacing: 12) {
                    filterPicker("Chip", values: AppState.ModelFilter.allCases,
                                 current: state.filterModel) { state.filterModel = $0 }
                    filterPicker("Clock", values: AppState.ClockFilter.allCases,
                                 current: state.filterClock) { state.filterClock = $0 }

                    HStack(spacing: 4) {
                        Text("Year")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                        TextField("from", text: Binding(
                            get: { state.filterYearFrom },
                            set: { state.filterYearFrom = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                        .font(.system(size: 11))
                        Text("–").foregroundStyle(theme.textSecondary)
                        TextField("to", text: Binding(
                            get: { state.filterYearTo },
                            set: { state.filterYearTo = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                        .font(.system(size: 11))
                    }

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .background(theme.panelBackground)
    }

    private func filterPicker<T: RawRepresentable & CaseIterable & Hashable>(
        _ label: String,
        values: T.AllCases,
        current: T,
        set: @escaping (T) -> Void
    ) -> some View where T.RawValue == String {
        let theme = state.theme
        return HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Picker("", selection: Binding(get: { current }, set: { set($0) })) {
                ForEach(Array(values), id: \.self) { v in
                    Text(v.rawValue).tag(v)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.mini)
        }
    }
}
