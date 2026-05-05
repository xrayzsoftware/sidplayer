import SwiftUI
import SIDEngine

struct WaveformView: View {
    let tap: VizTap
    private let samples = 1024

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            Canvas { ctx, size in
                let snap = tap.snapshotFloats(count: samples)
                guard !snap.isEmpty else { return }

                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color.black))

                // Subtle grid line through the centre.
                let mid = size.height / 2
                ctx.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: mid))
                        p.addLine(to: CGPoint(x: size.width, y: mid))
                    },
                    with: .color(.white.opacity(0.08)),
                    lineWidth: 1
                )

                let step = size.width / CGFloat(snap.count - 1)
                var path = Path()
                for (i, s) in snap.enumerated() {
                    let x = CGFloat(i) * step
                    let y = mid - CGFloat(s) * mid
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                ctx.stroke(path, with: .color(Color(red: 0.55, green: 0.95, blue: 0.45)), lineWidth: 1.2)

                // Label
                ctx.draw(
                    Text("WAVEFORM")
                        .font(.system(size: 9, weight: .semibold, design: .default))
                        .foregroundColor(.white.opacity(0.45))
                        .tracking(0.5),
                    at: CGPoint(x: 8, y: 10),
                    anchor: .topLeading
                )
            }
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}
