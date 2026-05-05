import SwiftUI

struct TransportBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Button { state.skipBackward() } label: {
                    Image(systemName: "backward.end.fill")
                }
                .help(state.subtuneCount > 1 ? "Previous subtune" : "Previous track")

                Button { state.togglePlayPause() } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                }
                Button { state.stop() } label: {
                    Image(systemName: "stop.fill")
                }
                Button { state.skipForward() } label: {
                    Image(systemName: "forward.end.fill")
                }
                .help(state.subtuneCount > 1 ? "Next subtune" : "Next track")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if state.subtuneCount > 1 {
                Text("sub \(state.currentSubtune)/\(state.subtuneCount)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(state.theme.textSecondary)
            }

            Spacer()

            Text(timeLabel)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(state.theme.textPrimary)

            Spacer()

            HStack(spacing: 8) {
                Text("VOL")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(state.theme.textSecondary)
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
