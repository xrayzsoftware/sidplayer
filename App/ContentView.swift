import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            if state.bootstrap == .ready || !state.rows.isEmpty {
                NowPlayingHeader()
                    .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)

                if state.showVisualizers {
                    HStack(spacing: 8) {
                        WaveformView(taps: state.player.voiceTaps)
                        SecondaryVisualizer()
                    }
                    .frame(height: 96)
                    .padding(.horizontal, 12)
                }

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

                switch state.browseMode {
                case .browse:    BrowseView()
                case .playlists: PlaylistsRootView()
                case .playlist:  PlaylistDetailView()
                default:         TrackListView()
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

/// Right-hand visualizer slot. Cycles through peak meter / spectrogram /
/// vectorscope via a small button overlaid in the top-right corner. The
/// per-voice waveform on the left is always shown.
private struct SecondaryVisualizer: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack(alignment: .topTrailing) {
            switch state.secondaryViz {
            case .peakMeter:
                PeakMeterView(tap: state.player.vizTap)
            case .spectrogram:
                SpectrogramView(tap: state.player.vizTap)
            case .vectorscope:
                VectorscopeView(tap: state.player.vizTap)
            }

            Button {
                state.cycleSecondaryViz()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(5)
            }
            .buttonStyle(.plain)
            .foregroundStyle(state.theme.textSecondary.opacity(0.85))
            .help("Cycle visualizer (peak / waterfall / phosphor)")
            .padding(4)
        }
    }
}
