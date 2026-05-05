import SwiftUI
import SIDEngine

/// Three stacked oscilloscope traces, one per SID voice, each in the active
/// theme's voice colour. The traces are populated by extra libsidplayfp
/// instances running in lockstep with two voices muted; they're producer-side
/// (so ~93 ms ahead of audio with the current 4k-sample ring), but the audio
/// path is independent — viz engine failures cannot break sound.
struct WaveformView: View {
    let taps: [VizTap]
    @Environment(AppState.self) private var state

    var body: some View {
        let theme = state.theme
        let colors = [theme.voice1, theme.voice2, theme.voice3]
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { i in
                VoicePanel(
                    tap: taps[i],
                    color: colors[i],
                    label: "V\(i + 1)",
                    background: theme.visualizerBackground,
                    centerLineColor: theme.textSecondary.opacity(0.20)
                )
                if i < 2 {
                    Rectangle()
                        .fill(theme.textSecondary.opacity(0.10))
                        .frame(height: 1)
                }
            }
        }
        .background(theme.visualizerBackground)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct VoicePanel: View {
    let tap: VizTap
    let color: Color
    let label: String
    let background: Color
    let centerLineColor: Color

    @State private var tick: UInt64 = 0
    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Canvas { ctx, size in
            _ = tick
            let snap = tap.snapshotFloats(count: 1024)

            let mid = size.height / 2
            ctx.stroke(
                Path { p in
                    p.move(to: CGPoint(x: 0, y: mid))
                    p.addLine(to: CGPoint(x: size.width, y: mid))
                },
                with: .color(centerLineColor),
                lineWidth: 1
            )

            if snap.count > 1 {
                let step = size.width / CGFloat(snap.count - 1)
                let halfH = size.height / 2 * 0.94
                let gain: CGFloat = 4.5  // single voice carries ~1/3 of the mix
                var path = Path()
                for (i, s) in snap.enumerated() {
                    let x = CGFloat(i) * step
                    let scaled = max(-1, min(1, CGFloat(s) * gain))
                    let y = mid - scaled * halfH
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else      { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                ctx.stroke(path, with: .color(color), lineWidth: 1.2)
            }

            ctx.draw(
                Text(label)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(color.opacity(0.85))
                    .tracking(0.5),
                at: CGPoint(x: 6, y: 8),
                anchor: .topLeading
            )
        }
        .background(background)
        .onReceive(timer) { _ in tick &+= 1 }
    }
}
