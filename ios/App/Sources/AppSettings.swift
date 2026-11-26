import Foundation
import Observation

/// The app's own settings, in UserDefaults (US-020+; the Settings screen, US-024, shows them).
/// Defaults are the musicless fork's (`BuildConfig.MUSICLESS_FORK` in the Android prefs).
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let showUpNext = "showUpNext"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Related videos under the player ("Up next"). Off by default: PlayerTweaksData's
    /// `mIsSuggestionsDisabled` defaults to true in the musicless fork.
    var showUpNext: Bool {
        didSet { defaults.set(showUpNext, forKey: Key.showUpNext) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `--up-next` (debug) shows it for this launch without saving (didSet doesn't run in init).
        showUpNext = ProcessInfo.processInfo.arguments.contains("--up-next") || defaults.object(forKey: Key.showUpNext) as? Bool ?? false
    }
}
