import SwiftUI

@main
struct SIDPlayerApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(state)
                .frame(minWidth: 540, minHeight: 600)
                .task { await state.bootstrap() }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
    }
}
