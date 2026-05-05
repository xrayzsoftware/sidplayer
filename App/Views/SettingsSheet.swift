import SwiftUI
import AppKit

struct SettingsSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("HVSC Library")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Current source")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(state.hvscSource?.root.path ?? "— not configured —")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(state.hvscSource == nil ? .red : .primary)
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
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .indexing(let processed, let total):
                VStack(alignment: .leading, spacing: 4) {
                    if let total {
                        ProgressView(value: Double(processed), total: Double(total))
                        Text("\(processed) / \(total) tunes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                        Text("Discovering tunes…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            case .error(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            default:
                EmptyView()
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Catalog")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\((try? state.catalog?.count()) ?? 0) tunes indexed")
                    .font(.callout)
            }

            Divider()

            ThemePickerSection()
        }
        .padding(20)
        .frame(width: 480)
    }

    private struct ThemePickerSection: View {
        @Environment(AppState.self) private var state

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Theme")
                    .font(.headline)

                let cols = [GridItem(.adaptive(minimum: 140), spacing: 8)]
                LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
                    ForEach(AppTheme.allPresets) { theme in
                        ThemeCard(theme: theme,
                                  selected: state.theme.id == theme.id) {
                            state.setTheme(theme)
                        }
                    }
                }
            }
        }
    }

    private struct ThemeCard: View {
        let theme: AppTheme
        let selected: Bool
        let onSelect: () -> Void

        var body: some View {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        // 6 swatches showing the palette
                        swatch(theme.windowBackground)
                        swatch(theme.waveform)
                        swatch(theme.voice2)
                        swatch(theme.voice3)
                        swatch(theme.peakGradient.last ?? theme.textAccent)
                        swatch(theme.textPrimary)
                    }
                    Text(theme.name)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(selected ? Color.accentColor : Color.gray.opacity(0.25),
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
                        .stroke(Color.black.opacity(0.15), lineWidth: 0.5)
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
