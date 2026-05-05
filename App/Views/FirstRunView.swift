import SwiftUI
import AppKit

struct FirstRunView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("SID Player")
                .font(.title)
            Text("Point this at the High Voltage SID Collection to get started.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            switch state.bootstrap {
            case .downloadingHVSC(let progress, let label):
                VStack(spacing: 6) {
                    ProgressView(value: progress)
                        .frame(width: 280)
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .indexing(let processed, let total):
                VStack(spacing: 6) {
                    if let total {
                        ProgressView(value: Double(processed), total: Double(total))
                            .frame(width: 280)
                        Text("\(processed) / \(total) tunes indexed")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                        Text("Discovering tunes…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            case .error(let msg):
                Text(msg)
                    .foregroundStyle(.red)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            default:
                HStack(spacing: 8) {
                    Button("Download HVSC (~640 MB)") {
                        Task { await state.downloadHVSC() }
                    }
                    .keyboardShortcut(.defaultAction)

                    Button("Choose Folder…") {
                        chooseFolder()
                    }
                }
            }
        }
        .padding(48)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the HVSC root (the folder containing DOCUMENTS/Songlengths.md5)"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await state.setHVSCFolder(url) }
        }
    }
}
