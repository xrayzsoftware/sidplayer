import SwiftUI

struct TransportBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        HStack(spacing: 12) {
            Button { state.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(state.shuffleEnabled
                        ? state.theme.textAccent
                        : state.theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Shuffle")

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

            Button { state.cycleRepeat() } label: {
                Image(systemName: state.repeatMode.icon)
                    .foregroundStyle(state.repeatMode == .off
                        ? state.theme.textSecondary
                        : state.theme.textAccent)
            }
            .buttonStyle(.plain)
            .help(state.repeatMode == .off ? "Repeat off"
                : state.repeatMode == .all ? "Repeat all"
                : "Repeat one")

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
        let idx = state.currentSubtune - 1
        let lenMs = (idx >= 0 && idx < state.subtuneLengthsMs.count)
            ? state.subtuneLengthsMs[idx]
            : state.defaultLengthMs
        let total = lenMs / 1000
        return String(format: "%d:%02d / %d:%02d", cur / 60, cur % 60, total / 60, total % 60)
    }
}
