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
                .background(WindowTinter(color: state.theme.windowBackground))
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
    }
}

private struct WindowTinter: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { apply(to: v) }
        return v
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: view) }
    }

    private func apply(to view: NSView) {
        guard let window = view.window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.backgroundColor = NSColor(color)
        window.isOpaque = true
    }
}
