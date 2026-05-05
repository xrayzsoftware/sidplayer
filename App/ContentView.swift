import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            if state.bootstrap == .ready || !state.rows.isEmpty {
                NowPlayingHeader()
                    .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)

                HStack(spacing: 8) {
                    WaveformView(taps: state.player.voiceTaps)
                    PeakMeterView(tap: state.player.vizTap)
                }
                .frame(height: 96)
                .padding(.horizontal, 12)

                TransportBar()
                    .padding(.horizontal, 12).padding(.vertical, 8)

                Divider()

                if state.showScroller {
                    STILScrollerView()
                        .frame(height: 28)
                    Divider()
                }

                if let err = state.lastError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Spacer()
                        Button("Settings") { state.showSettingsSheet = true }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                        Button {
                            state.lastError = nil
                        } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.orange.opacity(0.12))
                }

                TabBarView()
                Divider()
                FilterBar(text: $state.searchQuery)
                Divider()

                if state.browseMode == .browse {
                    BrowseView()
                } else {
                    TrackListView()
                }

                Divider()
                QueueBar()
            } else {
                FirstRunView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(state.theme.windowBackground)
        .sheet(isPresented: $state.showSettingsSheet) {
            SettingsSheet()
        }
        .task(id: state.searchQuery) {
            try? await Task.sleep(nanoseconds: 150_000_000)
            try? await state.refreshSearch()
        }
    }
}
