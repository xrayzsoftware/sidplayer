import SwiftUI

/// Old-school horizontal scroller. The position is computed from elapsed
/// real time rather than accumulated per-tick, and `TimelineView(.animation)`
/// drives the redraws at display-refresh rate — so it stays silky smooth on
/// 60 Hz displays and ProMotion alike.
struct STILScrollerView: View {
    @Environment(AppState.self) private var state

    @State private var textWidth: CGFloat = 0
    @State private var startDate = Date()
    @State private var lastLine: String = ""
    // The scroller text is cached and recomputed only when the tune or STIL
    // availability changes. Computing it touches SQLite, and `body` re-runs at
    // the ticker's 10 Hz (currentTime updates) — recomputing it there would
    // fire DB reads dozens of times a second for a string that rarely changes.
    @State private var cachedLine = "★ SID PLAYER ★   select a tune to begin   "

    private let speed: CGFloat = 80   // points / second

    var body: some View {
        let theme = state.theme
        GeometryReader { geo in
            let line = cachedLine
            let cycle = max(1, textWidth + geo.size.width)

            TimelineView(.animation) { context in
                let elapsed = CGFloat(context.date.timeIntervalSince(startDate))
                let scrolled = (elapsed * speed).truncatingRemainder(dividingBy: cycle)
                let offset = geo.size.width - scrolled

                ZStack(alignment: .leading) {
                    theme.visualizerBackground

                    Text(line)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.scrollerText)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: true)
                        .offset(x: offset)
                        .background(
                            GeometryReader { tg in
                                Color.clear
                                    .onAppear  { textWidth = tg.size.width }
                                    .onChange(of: tg.size.width) { _, w in textWidth = w }
                            }
                        )
                }
                .frame(height: 28)
                .clipped()
            }
            .frame(height: 28)
            .onAppear {
                Task { await state.ensureSTILLoaded() }
                cachedLine = scrollText
            }
            .onChange(of: state.currentTuneID) { _, _ in cachedLine = scrollText }
            .onChange(of: state.stil == nil)   { _, _ in cachedLine = scrollText }
            .onChange(of: line) { _, new in
                if new != lastLine {
                    lastLine = new
                    startDate = Date()      // restart from right edge
                }
            }
        }
        .frame(height: 28)
    }

    private var scrollText: String {
        let prefix: String
        if let id = state.currentTuneID,
           let row = try? state.catalog?.tune(id: id) {
            prefix = "★ \(row.title ?? "—") — \(row.author ?? "—") ★   "
        } else {
            prefix = "★ SID PLAYER ★   select a tune to begin   "
        }

        let stilText: String
        if let stilDB = state.stil,
           let id = state.currentTuneID,
           let row = try? state.catalog?.tune(id: id),
           let entry = stilDB.entry(forCatalogPath: row.path) {
            stilText = entry
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        } else if state.stil == nil {
            stilText = "loading STIL..."
        } else {
            stilText = "no STIL annotations for this tune"
        }

        return prefix + stilText + "          "
    }
}
