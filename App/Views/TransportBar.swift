import SwiftUI

struct TransportBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Button { state.previousSubtune() } label: {
                    Image(systemName: "backward.end.fill")
                }
                Button { state.togglePlayPause() } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                }
                Button { state.nextSubtune() } label: {
                    Image(systemName: "forward.end.fill")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            Text(timeLabel)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.primary)

            Spacer()

            HStack(spacing: 8) {
                Text("VOL")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Slider(value: $state.volume, in: 0...1)
                    .frame(width: 100)
                    .controlSize(.mini)
            }
        }
    }

    private var timeLabel: String {
        let cur = Int(state.currentTime)
        let total = state.defaultLengthMs / 1000
        return String(format: "%d:%02d / %d:%02d", cur / 60, cur % 60, total / 60, total % 60)
    }
}
