import SwiftUI
import AppKit
import SIDCatalog

struct MiniPlayerView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    /// Cached catalog row for the playing tune. `body` re-evaluates ~10×/sec
    /// while playing (it reads `state.currentTime`), and title/author only
    /// change at track boundaries — don't hit SQLite on every tick.
    @State private var row: TuneRow?

    var body: some View {
        @Bindable var state = state
        let theme = state.theme
        let hasTune = state.currentTuneID != nil

        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row?.title ?? "No tune loaded")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(row?.author ?? "Choose a tune in the main window")
                            .lineLimit(1)
                        if state.subtuneCount > 1 {
                            Text("·")
                                .foregroundStyle(theme.textSecondary.opacity(0.55))
                            Text("sub \(state.currentSubtune)/\(state.subtuneCount)")
                                .monospacedDigit()
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                }

                Spacer(minLength: 8)

                if let id = state.currentTuneID {
                    Button {
                        state.toggleFavorite(id)
                    } label: {
                        Image(systemName: state.favoriteIDs.contains(id) ? "star.fill" : "star")
                            .foregroundStyle(state.favoriteIDs.contains(id) ? theme.star : theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help(state.favoriteIDs.contains(id) ? "Remove from Favorites" : "Add to Favorites")
                }

                Button {
                    dismissWindow(id: "mini-player")
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Show main window")
            }

            MiniProgressBar(progress: progress)
                .frame(height: 4)

            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Button { state.skipBackward() } label: {
                        Image(systemName: "backward.end.fill")
                    }
                    .disabled(!hasTune)

                    Button { state.togglePlayPause() } label: {
                        Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 13)
                    }
                    .disabled(!hasTune)

                    Button { state.skipForward() } label: {
                        Image(systemName: "forward.end.fill")
                    }
                    .disabled(!hasTune)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Text(timeLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .frame(minWidth: 86, alignment: .leading)

                Spacer(minLength: 4)

                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textSecondary)
                Slider(value: $state.volume, in: 0...1)
                    .frame(width: 82)
                    .controlSize(.mini)
            }

        }
        .padding(10)
        .frame(width: 360)
        .background(theme.windowBackground)
        .background(WindowTinter(color: theme.windowBackground, isDark: theme.isDark))
        .background(MiniPlayerWindowSetup())
        .task(id: state.currentTuneID) {
            row = state.currentTuneID.flatMap { try? state.catalog?.tune(id: $0) }
        }
        .onAppear {
            // Give the window a chance to become key, then hide the main window.
            DispatchQueue.main.async {
                MiniPlayerView.hideMainWindow()
            }
        }
        .onDisappear { MiniPlayerView.showMainWindow() }
    }

    static func hideMainWindow() {
        for win in NSApp.windows {
            guard win.isVisible,
                  !(win is NSPanel),
                  win.identifier?.rawValue != "mini-player" else { continue }
            win.orderOut(nil)
        }
    }

    static func showMainWindow() {
        for win in NSApp.windows where win.identifier?.rawValue != "mini-player" && !(win is NSPanel) {
            win.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private var currentLengthMs: Int {
        let idx = state.currentSubtune - 1
        if idx >= 0 && idx < state.subtuneLengthsMs.count {
            return state.subtuneLengthsMs[idx]
        }
        return state.defaultLengthMs
    }

    private var progress: Double {
        guard currentLengthMs > 0 else { return 0 }
        return min(1, max(0, state.currentTime * 1000 / Double(currentLengthMs)))
    }

    private var timeLabel: String {
        let cur = Int(state.currentTime)
        let total = currentLengthMs / 1000
        return String(format: "%d:%02d / %d:%02d", cur / 60, cur % 60, total / 60, total % 60)
    }
}

/// Tags the mini-player window with its identifier as soon as the view
/// is attached to a window. Using viewDidMoveToWindow is more reliable
/// than reading NSApp.keyWindow in onAppear, which races with focus changes.
private struct MiniPlayerWindowSetup: NSViewRepresentable {
    func makeNSView(context: Context) -> _TagView { _TagView() }
    func updateNSView(_ view: _TagView, context: Context) {}

    final class _TagView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = NSUserInterfaceItemIdentifier("mini-player")
        }
    }
}

private struct MiniProgressBar: View {
    @Environment(AppState.self) private var state
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width * progress)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(state.theme.separator.opacity(0.65))
                Capsule()
                    .fill(state.theme.textAccent)
                    .frame(width: width)
            }
        }
        .accessibilityLabel("Playback progress")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}
