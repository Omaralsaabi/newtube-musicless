import MusiclessCore
import SwiftUI

@main
struct MusiclessApp: App {
    @State private var models = ModelStore(configuration: .app)

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(models)
                .preferredColorScheme(.dark)
        }
    }
}
