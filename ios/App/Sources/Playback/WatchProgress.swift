import Foundation
import Observation

/// How far each video was watched in this app, for the red bar under its thumbnail (Android's
/// VideoStateService, which fills in `percentWatched` where YouTube's card has none). Kept signed
/// in or out, in Application Support, the most recent 1,000 videos.
@MainActor @Observable
final class WatchProgress {
    static let shared = WatchProgress()

    struct Entry: Codable, Equatable {
        var position: Double
        var length: Double
        var updated: Date
    }

    private(set) var entries: [String: Entry] = [:]
    @ObservationIgnored private let storeURL = URL.applicationSupportDirectory.appending(path: "watch-progress.json")
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    static let limit = 1_000

    private init() {
        if let data = try? Data(contentsOf: storeURL), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    func record(videoID: String, position: Double, length: Double) {
        guard length > 0, position.isFinite else { return }
        entries[videoID] = Entry(position: min(max(position, 0), length), length: length, updated: Date())
        if entries.count > Self.limit {
            for (id, _) in entries.sorted(by: { $0.value.updated < $1.value.updated }).prefix(entries.count - Self.limit) {
                entries[id] = nil
            }
        }
        scheduleSave()
    }

    /// 1–100, or nil when the video wasn't played here. A video closed at once still shows a
    /// sliver (1), and the last 5 % count as watched (100), as on Android.
    func percent(_ videoID: String) -> Int? {
        guard let entry = entries[videoID] else { return nil }
        let share = entry.position / entry.length
        if share >= 0.95 { return 100 }
        return max(1, Int((share * 100).rounded()))
    }

    /// The bar a card shows: this app's own record first (it's the newest thing the viewer did
    /// here), else YouTube's (watched elsewhere, signed in).
    func barPercent(videoID: String, youtube: Int?) -> Int? {
        percent(videoID) ?? youtube
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(entries).write(to: storeURL, options: .atomic)
        }
    }
}
