import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            FilterBar(text: $state.searchQuery)
            Divider()

            if state.bootstrap == .ready || !state.rows.isEmpty {
                NowPlayingHeader()
                    .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)

                HStack(spacing: 8) {
                    WaveformView(tap: state.player.vizTap)
                    WaterfallSpectrumView(tap: state.player.vizTap)
                }
                .frame(height: 80)
                .padding(.horizontal, 12)

                InfoBar()
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

                Divider()

                TransportBar()
                    .padding(.horizontal, 12).padding(.vertical, 8)

                Divider()

                TrackListView()

                Divider()
                QueueBar()
            } else {
                FirstRunView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: state.searchQuery) {
            try? await Task.sleep(nanoseconds: 150_000_000)
            try? await state.refreshSearch()
        }
    }
}
