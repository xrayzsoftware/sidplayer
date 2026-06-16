import SwiftUI
import SIDEngine

/// Phosphor oscilloscope. Renders the full-mix waveform with CRT-style
/// persistence — keeping the last N snapshots and drawing each at
/// decreasing alpha gives a glowing afterimage as the trace moves. A faint
/// outer stroke layered behind the crisp inner line approximates phosphor
/// bloom.
///
/// (Originally an X-Y vectorscope — replaced with this because the X-Y
/// trace was confusing on most SID tunes.)
private let kVecSampleCount = 1024
private let kVecMaxHistory  = 16

/// Reference-typed ring buffer of waveform snapshots so the timer
/// callback can mutate it in place without re-allocating per frame.
private final class PhosphorHistory {
    /// `kVecMaxHistory` slots, each preallocated to `kVecSampleCount` floats.
    var slots: [[Float]] = Array(
        repeating: [Float](repeating: 0, count: kVecSampleCount),
        count: kVecMaxHistory
    )
    /// Index of the next slot to write — i.e. the oldest slot in the ring.
    var head: Int = 0
    /// Number of valid frames written so far (caps at `kVecMaxHistory`).
    var filled: Int = 0

    func push(_ snap: [Float]) {
        guard snap.count == kVecSampleCount else { return }
        slots[head] = snap
        head = (head + 1) % kVecMaxHistory
        if filled < kVecMaxHistory { filled += 1 }
    }
}

struct VectorscopeView: View {
    let tap: VizTap

    @Environment(AppState.self) private var state

    @State private var ring = PhosphorHistory()

    var body: some View {
        let theme = state.theme
        // Freeze the trace when playback is stopped — no new samples arrive,
        // so redrawing (and re-snapshotting) every frame just burns CPU.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !state.isPlaying)) { timeline in
        Canvas { ctx, size in
            _ = timeline.date
            ring.push(tap.snapshotFloats(count: kVecSampleCount))

            ctx.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(theme.visualizerBackground)
            )

            // Faint horizontal centre line.
            let mid = size.height / 2
            ctx.stroke(
                Path { p in
                    p.move(to: CGPoint(x: 0, y: mid))
                    p.addLine(to: CGPoint(x: size.width, y: mid))
                },
                with: .color(theme.textSecondary.opacity(0.15)),
                lineWidth: 1
            )

            guard ring.filled > 0 else { return }

            // Walk oldest → newest so the newest trace paints over older
            // ones; older slots stay visible at decaying alpha. With a
            // partially-filled ring, oldest = head - filled (mod size).
            let start = (ring.head - ring.filled + kVecMaxHistory) % kVecMaxHistory
            for i in 0..<ring.filled {
                let snap = ring.slots[(start + i) % kVecMaxHistory]
                guard snap.count > 1 else { continue }
                let age = Float(ring.filled - 1 - i)                  // 0 = newest
                let recency = 1 - age / Float(kVecMaxHistory)         // 0..1
                let alpha = max(0, recency * recency)                 // ease-in fade
                if alpha < 0.02 { continue }

                let step = size.width / CGFloat(snap.count - 1)
                let halfH = size.height / 2 * 0.92
                let gain: CGFloat = 1.6

                var path = Path()
                for j in 0..<snap.count {
                    let scaled = max(-1, min(1, CGFloat(snap[j]) * gain))
                    let x = CGFloat(j) * step
                    let y = mid - scaled * halfH
                    if j == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else      { path.addLine(to: CGPoint(x: x, y: y)) }
                }

                // Glow layer (thicker, more transparent) under the crisp trace.
                ctx.stroke(
                    path,
                    with: .color(theme.waveform.opacity(Double(alpha) * 0.25)),
                    lineWidth: 3.5
                )
                ctx.stroke(
                    path,
                    with: .color(theme.waveform.opacity(Double(alpha))),
                    lineWidth: 1.2
                )
            }

            ctx.draw(
                Text("PHOSPHOR")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.textSecondary.opacity(0.85))
                    .tracking(0.5),
                at: CGPoint(x: 8, y: 10),
                anchor: .topLeading
            )
        }
        .background(theme.visualizerBackground)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}
