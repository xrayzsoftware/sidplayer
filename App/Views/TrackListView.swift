import SwiftUI
import SIDCatalog

struct TrackListView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        let theme = state.theme

        // Use pre-sorted snapshot. Re-sorting 60k items in `body` was slow.
        let sortBinding = Binding<[KeyPathComparator<TuneItem>]>(
            get: { state.sortOrder },
            set: { new in
                state.sortOrder = new
                state.applySort()
            }
        )

        Table(state.sortedRows, selection: $state.selectedID, sortOrder: sortBinding) {
            TableColumn("") { (item: TuneItem) in
                if state.currentTuneID == item.id {
                    Image(systemName: state.isPlaying ? "play.fill" : "pause.fill")
                        .foregroundStyle(theme.textAccent)
                        .font(.system(size: 10))
                } else {
                    Color.clear
                }
            }.width(16)

            TableColumn("") { (item: TuneItem) in
                Button {
                    state.toggleFavorite(item.id)
                } label: {
                    Image(systemName: state.favoriteIDs.contains(item.id) ? "star.fill" : "star")
                        .foregroundStyle(state.favoriteIDs.contains(item.id) ? theme.star : theme.textSecondary)
                }
                .buttonStyle(.plain)
            }.width(20)

            TableColumn("Title", value: \.row.title, comparator: OptionalStringComparator()) { (item: TuneItem) in
                Text(item.row.title ?? "—")
            }

            TableColumn("Composer", value: \.row.author, comparator: OptionalStringComparator()) { (item: TuneItem) in
                Text(item.row.author ?? "—")
            }

            TableColumn("Year", value: \.row.released, comparator: OptionalStringComparator()) { (item: TuneItem) in
                Text(Self.extractYear(item.row.released))
            }.width(min: 44, ideal: 50, max: 70)

            TableColumn("Subs", value: \.row.songs) { (item: TuneItem) in
                Text("\(item.row.songs)")
            }.width(min: 36, ideal: 40, max: 50)

            TableColumn("Time", value: \.row.defaultLengthMs, comparator: OptionalIntComparator()) { (item: TuneItem) in
                Text(Self.formatMs(item.row.defaultLengthMs ?? 0))
            }.width(min: 56, ideal: 60, max: 80)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .background(theme.windowBackground)
        .foregroundStyle(theme.textPrimary)
        .font(.system(size: 12))
        .tint(theme.textAccent)
        .onChange(of: state.selectedID) { _, newID in
            guard let id = newID else { return }
            Task { await state.play(tuneID: id) }
        }
    }

    static func formatMs(_ ms: Int) -> String {
        let total = ms / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func extractYear(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "—" }
        if let r = s.range(of: #"\b\d{4}\b"#, options: .regularExpression) {
            return String(s[r])
        }
        return "—"
    }
}

/// Sorts nil values to the end. Uses a cheap case-insensitive ASCII-leaning
/// compare — `localizedStandardCompare` was a serious bottleneck on 60k rows.
struct OptionalStringComparator: SortComparator, Sendable {
    var order: SortOrder = .forward
    func compare(_ a: String?, _ b: String?) -> ComparisonResult {
        let result: ComparisonResult
        switch (a, b) {
        case (nil, nil): result = .orderedSame
        case (nil, _):   return .orderedDescending      // nils always at the end
        case (_, nil):   return .orderedAscending
        case let (x?, y?):
            result = x.compare(y, options: [.caseInsensitive, .numeric])
        }
        return order == .forward ? result : invert(result)
    }
    private func invert(_ r: ComparisonResult) -> ComparisonResult {
        switch r {
        case .orderedAscending:  return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame:       return .orderedSame
        }
    }
}

struct OptionalIntComparator: SortComparator, Sendable {
    var order: SortOrder = .forward
    func compare(_ a: Int?, _ b: Int?) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): return .orderedSame
        case (nil, _):   return .orderedDescending
        case (_, nil):   return .orderedAscending
        case let (x?, y?):
            if x < y { return order == .forward ? .orderedAscending : .orderedDescending }
            if x > y { return order == .forward ? .orderedDescending : .orderedAscending }
            return .orderedSame
        }
    }
}
