import SwiftUI

struct TransportBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        let voiceColors: [Color] = [state.theme.voice1, state.theme.voice2, state.theme.voice3]

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

            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { v in
                    let muted = state.voiceMuted[v]
                    Button { state.toggleVoiceMute(v) } label: {
                        Text("V\(v + 1)")
                            .font(.system(size: 10, weight: .heavy, design: .monospaced))
                            .frame(width: 26, height: 18)
                            .foregroundStyle(muted ? Color.secondary : Color.black)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(muted
                                          ? Color.gray.opacity(0.15)
                                          : voiceColors[v].opacity(0.85))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(muted
                                            ? Color.gray.opacity(0.45)
                                            : voiceColors[v],
                                            lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(muted ? "Unmute voice \(v + 1)" : "Mute voice \(v + 1)")
                }
            }

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
