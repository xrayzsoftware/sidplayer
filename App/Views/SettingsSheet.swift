import SwiftUI
import AppKit
import SIDEngine

struct SettingsSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let theme = state.theme

        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("HVSC Library")
                    .font(.headline)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Current source")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                Text(state.hvscSource?.root.path ?? "— not configured —")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(state.hvscSource == nil ? Color.red : theme.textPrimary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Button("Download HVSC (~640 MB)") {
                    Task { await state.downloadHVSC() }
                }
                Button("Choose Folder…") {
                    chooseFolder()
                }
                Button("Re-index") {
                    Task { try? await state.reindex() }
                }
                .disabled(state.hvscSource == nil)
            }
            .controlSize(.regular)

            switch state.bootstrap {
            case .downloadingHVSC(let progress, let label):
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                        .tint(theme.textAccent)
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
            case .indexing(let processed, let total):
                VStack(alignment: .leading, spacing: 4) {
                    if let total {
                        ProgressView(value: Double(processed), total: Double(total))
                            .tint(theme.textAccent)
                        Text("\(processed) / \(total) tunes")
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                    } else {
                        ProgressView()
                        Text("Discovering tunes…")
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            case .error(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            default:
                EmptyView()
            }

            Divider().background(theme.separator)

            VStack(alignment: .leading, spacing: 4) {
                Text("Catalog")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                Text("\((try? state.catalog?.count()) ?? 0) tunes indexed")
                    .font(.callout)
                    .foregroundStyle(theme.textPrimary)
            }

            Divider().background(theme.separator)

            EmulationSection()

            Divider().background(theme.separator)

            ThemePickerSection()
        }
        .padding(20)
        .frame(width: 520)
        .background(theme.windowBackground)
    }

    private struct EmulationSection: View {
        @Environment(AppState.self) private var state
        // Local copies so the filter sliders drag smoothly; committed (which
        // reloads the current tune) only on release via onEditingChanged.
        @State private var curve6581: Double = 0.5
        @State private var curve8580: Double = 0.5

        var body: some View {
            let theme = state.theme
            VStack(alignment: .leading, spacing: 10) {
                Text("Emulation")
                    .font(.headline)
                    .foregroundStyle(theme.textPrimary)

                HStack {
                    Text("Engine")
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Picker("", selection: engineBinding) {
                        ForEach(EmulationConfig.EngineChoice.allCases, id: \.self) { c in
                            Text(c.label).tag(c)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }

                HStack {
                    Text("SID Model")
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Picker("", selection: sidModelBinding) {
                        ForEach(EmulationConfig.SIDModelChoice.allCases, id: \.self) { c in
                            Text(c.label).tag(c)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }

                HStack {
                    Text("Clock")
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Picker("", selection: clockBinding) {
                        ForEach(EmulationConfig.ClockChoice.allCases, id: \.self) { c in
                            Text(c.label).tag(c)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }

                HStack {
                    Text("Sampling")
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Picker("", selection: samplingBinding) {
                        ForEach(EmulationConfig.SamplingMethod.allCases, id: \.self) { c in
                            Text(c.label).tag(c)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }

                Toggle(isOn: digiBoostBinding) {
                    Text("8580 DigiBoost")
                        .foregroundStyle(theme.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(theme.textAccent)

                if state.emulationConfig.engine == .residfp {
                    filterCurveRow("6581 Filter", value: $curve6581) {
                        var c = state.emulationConfig
                        c.filter6581Curve = curve6581
                        state.updateEmulationConfig(c)
                    }
                    filterCurveRow("8580 Filter", value: $curve8580) {
                        var c = state.emulationConfig
                        c.filter8580Curve = curve8580
                        state.updateEmulationConfig(c)
                    }
                    Text("Filter curve: 0 = dark, 1 = bright (reSIDfp only).")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                }

                Text("Auto respects each tune's declared chip and clock. Changes reload the current tune.")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            .onAppear {
                curve6581 = state.emulationConfig.filter6581Curve
                curve8580 = state.emulationConfig.filter8580Curve
            }
        }

        private var engineBinding: Binding<EmulationConfig.EngineChoice> {
            Binding(
                get: { state.emulationConfig.engine },
                set: { var c = state.emulationConfig; c.engine = $0; state.updateEmulationConfig(c) }
            )
        }

        @ViewBuilder
        private func filterCurveRow(_ label: String,
                                    value: Binding<Double>,
                                    commit: @escaping () -> Void) -> some View {
            let theme = state.theme
            HStack {
                Text(label)
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 80, alignment: .leading)
                Slider(value: value, in: 0...1) { editing in if !editing { commit() } }
                    .tint(theme.textAccent)
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 34, alignment: .trailing)
            }
        }

        private var sidModelBinding: Binding<EmulationConfig.SIDModelChoice> {
            Binding(
                get: { state.emulationConfig.sidModel },
                set: { var c = state.emulationConfig; c.sidModel = $0; state.updateEmulationConfig(c) }
            )
        }

        private var clockBinding: Binding<EmulationConfig.ClockChoice> {
            Binding(
                get: { state.emulationConfig.clock },
                set: { var c = state.emulationConfig; c.clock = $0; state.updateEmulationConfig(c) }
            )
        }

        private var samplingBinding: Binding<EmulationConfig.SamplingMethod> {
            Binding(
                get: { state.emulationConfig.sampling },
                set: { var c = state.emulationConfig; c.sampling = $0; state.updateEmulationConfig(c) }
            )
        }

        private var digiBoostBinding: Binding<Bool> {
            Binding(
                get: { state.emulationConfig.digiBoost },
                set: { var c = state.emulationConfig; c.digiBoost = $0; state.updateEmulationConfig(c) }
            )
        }
    }

    private struct ThemePickerSection: View {
        @Environment(AppState.self) private var state

        var body: some View {
            let theme = state.theme
            VStack(alignment: .leading, spacing: 8) {
                Text("Theme")
                    .font(.headline)
                    .foregroundStyle(theme.textPrimary)

                let cols = [GridItem(.adaptive(minimum: 150), spacing: 8)]
                LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
                    ForEach(AppTheme.allPresets) { preset in
                        ThemeCard(preset: preset,
                                  selected: state.theme.id == preset.id,
                                  activeTheme: theme) {
                            state.setTheme(preset)
                        }
                    }
                }
            }
        }
    }

    private struct ThemeCard: View {
        let preset: AppTheme
        let selected: Bool
        let activeTheme: AppTheme
        let onSelect: () -> Void

        var body: some View {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        swatch(preset.windowBackground)
                        swatch(preset.waveform)
                        swatch(preset.voice2)
                        swatch(preset.voice3)
                        swatch(preset.peakGradient.last ?? preset.textAccent)
                        swatch(preset.textPrimary)
                    }
                    Text(preset.name)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? activeTheme.textPrimary : activeTheme.textSecondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected
                              ? activeTheme.textAccent.opacity(0.18)
                              : activeTheme.panelBackground.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(selected ? activeTheme.textAccent : activeTheme.separator,
                                lineWidth: selected ? 1.5 : 1)
                )
            }
            .buttonStyle(.plain)
        }

        private func swatch(_ c: Color) -> some View {
            RoundedRectangle(cornerRadius: 2)
                .fill(c)
                .frame(width: 14, height: 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.black.opacity(0.20), lineWidth: 0.5)
                )
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the HVSC root (folder containing DOCUMENTS/Songlengths.md5)"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await state.setHVSCFolder(url) }
        }
    }
}
