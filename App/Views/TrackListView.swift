import SwiftUI
import AppKit
import UniformTypeIdentifiers
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
                Text(Self.formatMs(lengthMs(for: item)))
            }.width(min: 56, ideal: 60, max: 80)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .background(theme.windowBackground)
        .foregroundStyle(theme.textPrimary)
        .font(.system(size: 12))
        .tint(theme.textAccent)
        .contextMenu(forSelectionType: TuneItem.ID.self) { ids in
            if let id = ids.first {
                rowContextMenu(for: id)
            }
        }
        // Playback is driven by selectedID's didSet in AppState — no onChange
        // here, which would double-trigger play() on skip/auto-advance.
    }

    @ViewBuilder
    private func rowContextMenu(for tuneID: Int64) -> some View {
        Button {
            state.toggleFavorite(tuneID)
        } label: {
            Label(
                state.favoriteIDs.contains(tuneID) ? "Remove from Favorites" : "Add to Favorites",
                systemImage: "star"
            )
        }

        Menu("Add to Playlist") {
            if state.playlists.isEmpty {
                Text("No playlists yet")
            } else {
                ForEach(state.playlists) { p in
                    if let pid = p.id {
                        Button(p.name) {
                            state.addToPlaylist(playlistID: pid, tuneID: tuneID)
                        }
                    }
                }
            }
            Divider()
            Button("New Playlist…") {
                if let pid = state.createPlaylist(name: "New Playlist") {
                    state.addToPlaylist(playlistID: pid, tuneID: tuneID)
                }
            }
        }

        if case .playlist = state.browseMode {
            Divider()
            Button("Remove from Playlist", role: .destructive) {
                // Position in storage order (state.rows), not the possibly-
                // resorted sortedRows view.
                if let idx = state.rows.firstIndex(where: { $0.id == tuneID }) {
                    state.removeFromCurrentPlaylist(at: idx)
                }
            }
        }

        Divider()

        Button("Export as WAV…") {
            guard let db = state.catalog,
                  state.hvscSource != nil,
                  let row = try? db.tune(id: tuneID) else { return }
            let title  = (row.title  ?? "Unknown").replacingOccurrences(of: "/", with: "-")
            let author = (row.author ?? "Unknown").replacingOccurrences(of: "/", with: "-")
            let panel  = NSSavePanel()
            panel.allowedContentTypes = [.wav]
            panel.nameFieldStringValue = "\(title) - \(author).wav"
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            Task { await state.exportTuneAsWAV(tuneID: tuneID, to: dest) }
        }
        .disabled(state.hvscSource == nil)
    }

    private func lengthMs(for item: TuneItem) -> Int {
        if item.id == state.currentTuneID {
            let idx = state.currentSubtune - 1
            if idx >= 0 && idx < state.subtuneLengthsMs.count {
                return state.subtuneLengthsMs[idx]
            }
        }
        return item.row.defaultLengthMs ?? 0
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
