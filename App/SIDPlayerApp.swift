import SwiftUI
import AppKit

@main
struct SIDPlayerApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(state)
                .frame(minWidth: 540, minHeight: 600)
                .task { await state.bootstrap() }
                // Reach into NSWindow to tint the title-bar area to match
                // the active theme. macOS 14 doesn't expose
                // .containerBackground(..., for: .window).
                .background(WindowTinter(
                    color: state.theme.windowBackground,
                    isDark: state.theme.isDark
                ))
        }
        // hiddenTitleBar removes the system title-bar chrome layer entirely
        // (vibrancy backdrop + title text). Traffic lights remain in their
        // standard position. The SwiftUI background now fills the window
        // edge-to-edge, so theme color reaches the very top.
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}

private struct WindowTinter: NSViewRepresentable {
    let color: Color
    let isDark: Bool

    func makeNSView(context: Context) -> WindowAwareView {
        let v = WindowAwareView()
        v.tint = NSColor(color)
        v.isDark = isDark
        return v
    }

    func updateNSView(_ view: WindowAwareView, context: Context) {
        view.tint = NSColor(color)
        view.isDark = isDark
        view.applyTint()
    }
}

/// NSView that knows when it joins a window so we can tint reliably —
/// dispatching async on view init often runs before the view is attached
/// to a window, leaving the title bar at the system default.
private final class WindowAwareView: NSView {
    var tint: NSColor = .windowBackgroundColor
    var isDark: Bool = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTint()
    }

    func applyTint() {
        guard let window else { return }
        // Two pieces matter:
        //  1) NSAppearance — drives the title bar's chrome (text, traffic
        //     lights, vibrancy backdrop). Without this, light themes get a
        //     dark bar (or vice-versa) regardless of backgroundColor.
        //  2) backgroundColor + titlebarAppearsTransparent + fullSizeContentView
        //     so the theme color shows through the now-transparent bar.
        window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = tint
        window.isOpaque = true
    }
}
