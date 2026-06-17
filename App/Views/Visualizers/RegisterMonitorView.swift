import SwiftUI
import SIDEngine

/// Live SID register readout: per-voice note, waveform, gate, pulse width and
/// ADSR, plus the filter / volume state. Driven from the producer-thread
/// register latch — the last values the tune wrote to $D400–$D418.
///
/// These are the *programmed* settings. `getSidStatus` doesn't expose the live
/// envelope amplitude, so ADSR is shown as the configured rates/level, not a
/// moving playhead.
struct RegisterMonitorView: View {
    let latch: RegisterLatch
    @Environment(AppState.self) private var state

    var body: some View {
        let theme = state.theme
        let voiceColors = [theme.voice1, theme.voice2, theme.voice3]
        let clock = effectiveClock

        // Registers change at the tune's play rate (~50 Hz); 30 Hz keeps fast
        // arpeggios legible without re-laying-out text 60×/s. Frozen when
        // stopped — the latch receives no updates while paused.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !state.isPlaying)) { _ in
            let regs = SIDRegisters(image: latch.latest())
            VStack(alignment: .leading, spacing: 2) {
                Text("REGISTERS")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textSecondary.opacity(0.85))
                    .tracking(0.5)

                ForEach(0..<3, id: \.self) { i in
                    voiceRow(index: i, voice: regs.voices[i], color: voiceColors[i], clock: clock)
                }

                filterRow(regs)
            }
            .font(.system(size: 10, design: .monospaced))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(theme.visualizerBackground)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    /// PAL/NTSC actually driving playback: an emulation override wins, otherwise
    /// the loaded tune's own clock (defaulting to PAL when unknown).
    private var effectiveClock: SIDRegisters.Clock {
        switch state.emulationConfig.clock {
        case .ntsc: return .ntsc
        case .pal:  return .pal
        case .auto: return state.currentTuneClock == .ntsc ? .ntsc : .pal
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func voiceRow(index: Int, voice v: SIDRegisters.Voice,
                          color: Color, clock: SIDRegisters.Clock) -> some View {
        let theme = state.theme
        let note = v.note(clock: clock)
        let active = v.gate && v.frequency != 0

        HStack(spacing: 7) {
            Text("V\(index + 1)")
                .foregroundStyle(color)
                .frame(width: 16, alignment: .leading)

            // Note + cents
            Text(note?.display ?? "—")
                .foregroundStyle(active ? theme.textPrimary : theme.textSecondary.opacity(0.55))
                .frame(width: 30, alignment: .leading)
            Text(note.map { String(format: "%+d", $0.cents) } ?? "")
                .foregroundStyle(theme.textSecondary.opacity(0.6))
                .frame(width: 26, alignment: .leading)

            // Waveform(s) + modulation flags
            Text(waveformText(v))
                .foregroundStyle(active ? theme.textPrimary : theme.textSecondary.opacity(0.55))
                .frame(width: 74, alignment: .leading)

            // Gate
            Text(v.gate ? "●" : "○")
                .foregroundStyle(v.gate ? color : theme.textSecondary.opacity(0.4))
                .frame(width: 12, alignment: .center)

            // Pulse width (only when pulse waveform selected)
            Text(v.pulse ? String(format: "%2.0f%%", v.pulseWidthPercent) : "")
                .foregroundStyle(theme.textSecondary.opacity(0.75))
                .frame(width: 36, alignment: .leading)

            // ADSR as hex nibbles A·D·S·R
            HStack(spacing: 0) {
                Text("adsr ").foregroundStyle(theme.textSecondary.opacity(0.5))
                Text(hexNibbles(v)).foregroundStyle(theme.textSecondary.opacity(0.85))
            }

            Spacer(minLength: 0)
        }
        .lineLimit(1)
        // Pin the row height so changing values (and symbol glyphs that fall
        // back to a non-monospaced font) can't nudge rows up/down.
        .frame(height: 15)
    }

    @ViewBuilder
    private func filterRow(_ regs: SIDRegisters) -> some View {
        let theme = state.theme
        HStack(spacing: 7) {
            Text("FLT")
                .foregroundStyle(theme.textSecondary.opacity(0.85))
                .frame(width: 16, alignment: .leading)
            Text("cut \(regs.cutoff)")
                .foregroundStyle(theme.textSecondary)
                .frame(width: 76, alignment: .leading)
            Text("res \(regs.resonance)")
                .foregroundStyle(theme.textSecondary)
                .frame(width: 44, alignment: .leading)
            // LP / BP / HP — active modes pop, inactive dim.
            HStack(spacing: 3) {
                modeBadge("LP", on: regs.lowpass)
                modeBadge("BP", on: regs.bandpass)
                modeBadge("HP", on: regs.highpass)
            }
            Text("vol \(regs.volume)")
                .foregroundStyle(theme.textSecondary)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        // Pin the row height so changing values (and symbol glyphs that fall
        // back to a non-monospaced font) can't nudge rows up/down.
        .frame(height: 15)
    }

    private func modeBadge(_ label: String, on: Bool) -> some View {
        Text(label)
            .foregroundStyle(on ? state.theme.textAccent : state.theme.textSecondary.opacity(0.35))
    }

    // MARK: - Formatting

    private func waveformText(_ v: SIDRegisters.Voice) -> String {
        var parts: [String] = []
        if v.triangle { parts.append("tri") }
        if v.sawtooth { parts.append("saw") }
        if v.pulse    { parts.append("pul") }
        if v.noise    { parts.append("nse") }
        var s = parts.isEmpty ? "—" : parts.joined(separator: "+")
        // Modulation flags only when set — rare but musically meaningful.
        var flags: [String] = []
        if v.ringMod { flags.append("ring") }
        if v.sync    { flags.append("sync") }
        if v.test    { flags.append("test") }
        if !flags.isEmpty { s += " " + flags.joined(separator: " ") }
        return s
    }

    private func hexNibbles(_ v: SIDRegisters.Voice) -> String {
        func h(_ n: UInt8) -> String { String(n, radix: 16, uppercase: true) }
        return "\(h(v.attack))·\(h(v.decay))·\(h(v.sustain))·\(h(v.release))"
    }
}
