import MusiclessCore
import SwiftUI

@main
struct MusiclessApp: App {
    @State private var models = ModelStore(configuration: .app)
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(models)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            // `appState=` on playback log lines (the locked screen is `.background`).
            AppLog.player.info("scenePhase=\(phase)")
            if phase != .inactive { AppActivity.set(background: phase == .background) }
        }
    }
}
