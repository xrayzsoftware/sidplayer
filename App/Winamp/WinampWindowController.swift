import AppKit

/// A window with no system frame at all: the skin draws its own title bar,
/// and classic skins are square-cornered. Borderless windows refuse focus by
/// default, which would leave the skin's title bar permanently dimmed and
/// the keyboard dead.
final class WinampWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// ⌘W reaches performClose, which only works on windows that have a
    /// system close button.
    override func performClose(_ sender: Any?) { close() }
}

/// Owns the one Winamp-view window. AppKit rather than a SwiftUI scene
/// because SwiftUI cannot make a borderless window that still takes focus.
@MainActor
final class WinampWindowController: NSObject, NSWindowDelegate {
    static let shared = WinampWindowController()

    private var window: WinampWindow?

    func show(state: AppState) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        state.loadWinampSettings()
        let view = WinampSkinView(state: state)
        let window = WinampWindow(
            contentRect: NSRect(origin: .zero, size: view.contentSize),
            styleMask: [.borderless, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Winamp View"
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.delegate = self
        window.center()
        // Remembers where the window was left. The saved size is ignored:
        // the view sizes the window to the skin on its first tick.
        window.setFrameAutosaveName("WinampView")
        view.fitWindow()
        window.makeFirstResponder(view)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
