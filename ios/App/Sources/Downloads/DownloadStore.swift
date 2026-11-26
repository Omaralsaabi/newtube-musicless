import BackgroundTasks
import Foundation
import MediaPipeline
import Observation
import YouTubeEngine

/// One download (US-028), persisted.
struct DownloadItem: Codable, Identifiable, Equatable {
    enum State: Codable, Equatable {
        case queued
        case downloading(Double)
        case removingMusic(Double)
        case saving
        case done(file: String)
        case failed(String)
    }

    var id: UUID
    var videoID: String
    var title: String
    var author: String
    var thumbnail: URL?
    /// The chosen quality's label; nil for "Best", shown in the current language.
    var quality: String?
    var itag: Int?
    /// Saved with the music removed: playing it uses pass-through.
    var voicesOnly: Bool
    var state: State
    var createdAt: Date

    var qualityLabel: String { quality ?? String(localized: "Best") }

    var fileURL: URL? {
        if case .done(let file) = state { URL.documentsDirectory.appending(path: file) } else { nil }
    }

    var isActive: Bool {
        switch state {
        case .queued, .downloading, .removingMusic, .saving: true
        case .done, .failed: false
        }
    }
}

/// Downloads with the music removed (US-028): pick a quality, fetch both files through the media
/// fetcher with playback's 403 recovery, remove the music offline, mux one MP4 into Documents
/// (Files → On My iPhone → the app). One at a time. On iOS 26 each runs inside a
/// `BGContinuedProcessingTask` with the system's progress UI.
@MainActor @Observable
final class DownloadStore {
    static let shared = DownloadStore()

    private(set) var items: [DownloadItem] = []
    @ObservationIgnored private let storeURL = URL.applicationSupportDirectory.appending(path: "downloads.json")
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var runningID: UUID?
    @ObservationIgnored private var backgroundTask: AnyObject?

    private init() {
        if let data = try? Data(contentsOf: storeURL), let saved = try? JSONDecoder().decode([DownloadItem].self, from: data) {
            // A download the app was closed in the middle of didn't finish.
            items = saved.map { item in
                var item = item
                if item.isActive { item.state = .failed(String(localized: "Interrupted. Try again.")) }
                return item
            }
        }
    }

    func start(videoID: String, title: String, author: String, thumbnail: URL?, option: VideoOption?) {
        let item = DownloadItem(id: UUID(), videoID: videoID, title: title, author: author, thumbnail: thumbnail,
                                quality: option?.label, itag: option?.itag,
                                voicesOnly: AppSettings.shared.removeMusic, state: .queued, createdAt: Date())
        items.insert(item, at: 0)
        save()
        AppLog.player.info("download queued video=\(videoID) quality=\(item.quality ?? "best") voicesOnly=\(item.voicesOnly)")
        next()
    }

    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .queued
        items[index].voicesOnly = AppSettings.shared.removeMusic
        save()
        next()
    }

    func cancel(_ id: UUID) {
        if runningID == id {
            running?.cancel()
        } else if let index = items.firstIndex(where: { $0.id == id }), items[index].isActive {
            items[index].state = .failed(String(localized: "Cancelled"))
            save()
        }
    }

    func delete(_ id: UUID) {
        cancel(id)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let url = items[index].fileURL { try? FileManager.default.removeItem(at: url) }
        items.remove(at: index)
        save()
    }

    // MARK: Running

    private func next() {
        guard running == nil, let item = items.last(where: { $0.state == .queued }) else { return }
        runningID = item.id
        beginBackgroundTask(for: item)
        running = Task {
            let outcome: DownloadItem.State
            do {
                let file = try await DownloadJob(item: item) { [weak self] state in
                    Task { @MainActor in self?.update(item.id, state) }
                }.run()
                outcome = .done(file: file)
                AppLog.player.info("download done video=\(item.videoID) file=\(file.count) chars")
            } catch is CancellationError {
                outcome = .failed(String(localized: "Cancelled"))
            } catch {
                AppLog.player.info("download failed video=\(item.videoID) error=\(error)")
                outcome = .failed((error as? DownloadError)?.description == "separation failed"
                                  ? String(localized: "Couldn't remove the music") : String(localized: "Download failed. Try again."))
            }
            update(item.id, outcome)
            endBackgroundTask(success: { if case .done = outcome { true } else { false } }())
            running = nil
            runningID = nil
            next()
        }
    }

    private func update(_ id: UUID, _ state: DownloadItem.State) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = state
        if #available(iOS 26, *), let task = backgroundTask as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = Int64(Self.overall(state) * 1000)
        }
        if !items[index].isActive { save() }
    }

    /// One bar for the system: fetching is the first 60 %, separating the next 35 %, saving the rest.
    static func overall(_ state: DownloadItem.State) -> Double {
        switch state {
        case .queued: 0
        case .downloading(let fraction): fraction * 0.6
        case .removingMusic(let fraction): 0.6 + fraction * 0.35
        case .saving: 0.95
        case .done, .failed: 1
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(items).write(to: storeURL, options: .atomic)
    }

    // MARK: BGContinuedProcessingTask (iOS 26)

    private func beginBackgroundTask(for item: DownloadItem) {
        guard #available(iOS 26, *), let bundle = Bundle.main.bundleIdentifier else { return }
        let identifier = "\(bundle).download.\(item.id.uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            MainActor.assumeIsolated {
                task.progress.totalUnitCount = 1000
                task.expirationHandler = { [weak self] in
                    Task { @MainActor in
                        AppLog.player.info("download background-task expired")
                        self?.running?.cancel()
                    }
                }
                self?.backgroundTask = task
                AppLog.player.info("download background-task running")
            }
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: String(localized: "Downloading"),
                                                       subtitle: item.title)
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            AppLog.player.info("download background-task submitted registered=\(registered)")
        } catch {
            AppLog.player.info("download background-task refused error=\(error)")
        }
    }

    private func endBackgroundTask(success: Bool) {
        guard #available(iOS 26, *), let task = backgroundTask as? BGContinuedProcessingTask else { return }
        task.setTaskCompleted(success: success)
        backgroundTask = nil
    }
}

/// The work of one download, off the main actor except for resolving (the resolver is main-actor).
struct DownloadJob: Sendable {
    let item: DownloadItem
    let report: @Sendable (DownloadItem.State) -> Void

    init(item: DownloadItem, report: @escaping @Sendable (DownloadItem.State) -> Void) {
        self.item = item
        self.report = report
    }

    func run() async throws -> String {
        let work = FileManager.default.temporaryDirectory.appending(path: "download-\(item.id.uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        report(.downloading(0))
        var media = try await resolve()
        let audioURL = work.appending(path: "audio.m4a"), videoURL = work.appending(path: "video.mp4")
        let total = Double(media.audio.file.contentLength + (media.video?.file.contentLength ?? 0))
        let audioBytes = media.audio.file.contentLength
        media = try await fetch(.audio, media: media, to: audioURL) { bytes in
            report(.downloading(Double(bytes) / total))
        }
        if media.video != nil {
            media = try await fetch(.video, media: media, to: videoURL) { bytes in
                report(.downloading(Double(audioBytes + bytes) / total))
            }
        }
        var audioForMux = audioURL
        if item.voicesOnly {
            report(.removingMusic(0))
            let voicesURL = work.appending(path: "voices.m4a")
            let start = ContinuousClock.now
            do {
                let backend = try await PlaybackServices.shared.downloadBackend()
                try await OfflineSeparator.run(input: audioURL, output: voicesURL, backend: backend) { fraction in
                    report(.removingMusic(fraction))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Any failure here (models, reader, a failed window, the writer) is "Couldn't remove the music".
                AppLog.musicless.info("download voices failed video=\(item.videoID) error=\(error)")
                throw DownloadError(description: "separation failed")
            }
            AppLog.musicless.info("download voices video=\(item.videoID) ms=\(Int((ContinuousClock.now - start) / .milliseconds(1)))")
            audioForMux = voicesURL
        }
        report(.saving)
        let name = Self.fileName(title: item.title, videoID: item.videoID)
        try await Muxer.mux(video: media.video == nil ? nil : videoURL, audio: audioForMux, to: URL.documentsDirectory.appending(path: name))
        return name
    }

    private enum Track { case audio, video }

    /// The answer's files at the chosen quality (`itag`, else the settings' choice).
    private func resolve() async throws -> ResolvedMedia {
        var media = try await VideoResolver.media(for: item.videoID, withVideo: true)
        if let itag = item.itag, let option = media.videoOptions.first(where: { $0.itag == itag }) {
            media.video = option.source
        }
        return media
    }

    /// The whole file in ranges through the media fetcher. A 403 is routine: the video is resolved
    /// again and the fetcher repoints to the same file (itag, lmt, length) at its new URL; when the
    /// answer has another encode, the file starts over with it. Never the refused URL again.
    private func fetch(_ track: Track, media: ResolvedMedia, to url: URL, progress: @Sendable (Int64) -> Void) async throws -> ResolvedMedia {
        var media = media
        var file = track == .audio ? media.audio.file : media.video!.file
        var fetcher = MediaFetcher(file: file, log: { AppLog.netPath.info($0) })
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var offset: Int64 = 0
        var recoveries = 0
        let step: Int64 = 4 * 1024 * 1024
        while offset < file.contentLength {
            try Task.checkCancellation()
            let end = min(offset + step, file.contentLength) - 1
            do {
                let data = try await fetcher.read(offset...end)
                try handle.write(contentsOf: data)
                offset += Int64(data.count)
                progress(offset)
            } catch let refused as MediaRefused {
                recoveries += 1
                guard recoveries <= 3 else { throw refused }
                AppLog.netPath.info("download media403 itag=\(refused.itag) at=\(offset) recovery=\(recoveries)")
                let fresh = try await resolve()
                let candidate = track == .audio ? fresh.audio.file : fresh.video?.file
                guard let candidate else { throw refused }
                if candidate.isSameFile(as: file) {
                    try await fetcher.repoint(to: candidate)
                } else {
                    // Another encode: what was written belongs to the old one; start over with it.
                    try handle.truncate(atOffset: 0)
                    try handle.seek(toOffset: 0)
                    offset = 0
                    fetcher = MediaFetcher(file: candidate, log: { AppLog.netPath.info($0) })
                }
                file = candidate
                media = fresh
            }
        }
        return media
    }

    /// `<title>.mp4` in Documents, without characters Files refuses, never overwriting.
    static func fileName(title: String, videoID: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let base = String((cleaned.isEmpty ? videoID : cleaned).prefix(100))
        var name = "\(base).mp4"
        var index = 2
        while FileManager.default.fileExists(atPath: URL.documentsDirectory.appending(path: name).path) {
            name = "\(base) (\(index)).mp4"
            index += 1
        }
        return name
    }
}
