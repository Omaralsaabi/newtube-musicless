import MusiclessCore
import SwiftUI
import UIKit

/// The orientation lock (US-018): portrait everywhere, landscape while the full-screen player shows.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientations: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientations
    }
}

@main
struct MusiclessApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
