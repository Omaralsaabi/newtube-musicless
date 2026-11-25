import AVFoundation
import Foundation
import MediaPipeline
import MusiclessCore
import os
import UIKit
import YouTubeEngine

/// What every player shares: one model runtime (sessions load once and are released 120 s after the
/// last player leaves, or on a memory warning when idle), the InnerTube transport and visitor.
@MainActor
final class PlaybackServices {
    static let shared = PlaybackServices()

    private(set) var runtime: ModelRuntime?
    let transport = InnerTubeTransport(log: { AppLog.netPath.info($0) })
    let identity: VisitorIdentity
    /// The source walk (US-015) and what it asks with.
    let walker: SourceWalker
    let sources: PlayerSources
    /// The signature and n solver (US-016) and the player JS it solves with.
    let solver: ChallengeSolver
    let cipher: CipherResolver
    private var memoryObserver: (any NSObjectProtocol)?

    private init() {
        let log: @Sendable (String) -> Void = { AppLog.netPath.info($0) }
        let youtube = URL.applicationSupportDirectory.appending(path: "youtube", directoryHint: .isDirectory)
        identity = VisitorIdentity(transport: transport, storeURL: youtube.appending(path: "visitor.json"), log: log)
        walker = SourceWalker(network: { await NetworkWatcher.shared.signature() }, log: log)
        sources = PlayerSources(transport: transport, visitor: identity,
                                embed: EmbedIdentityStore(transport: transport, storeURL: youtube.appending(path: "embed.json"), log: log),
                                log: log)
        let players = URL.cachesDirectory.appending(path: "youtube/players", directoryHint: .isDirectory)
        solver = ChallengeSolver(cacheDirectory: players, log: { AppLog.netPath.info($0) })
        cipher = CipherResolver(solver: solver, scripts: PlayerScripts(transport: transport, directory: players))
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AppLog.musicless.info("Memory warning")
                let services = PlaybackServices.shared
                if let runtime = services.runtime { Task { await runtime.didReceiveMemoryWarning() } }
                Task { await services.solver.release() }
            }
        }
    }

    /// At launch, in the background: the visitor, then the current player preprocessed for the
    /// solver, so neither lands on the first tap (US-016).
    func warmUp() {
        let identity = identity, cipher = cipher
        Task(priority: .utility) {
            let start = ContinuousClock.now
            guard let playerURL = try? await identity.current().playerURL else { return }
            do {
                try await cipher.warm(playerURL: playerURL)
                AppLog.netPath.info("solver warm-up done ms=\(Int((ContinuousClock.now - start) / .milliseconds(1)))")
            } catch {
                AppLog.netPath.info("solver warm-up failed error=\(error)")
            }
        }
    }

    func runtime(models: ModelStore) -> ModelRuntime {
        if let runtime { return runtime }
        let made = ModelRuntime(models: models.modelURLs, awaitModels: { try await models.awaitReady() },
                                log: { AppLog.musicless.info($0) })
        runtime = made
        return made
    }
}

/// Whether the app is in the background, readable from any thread for log lines (`appState=fg|bg`,
/// which the PRD adds to Android's `Window pipeline` line).
enum AppActivity {
    private static let background = OSAllocatedUnfairLock(initialState: false)

    static var logValue: String { background.withLock { $0 } ? "bg" : "fg" }

    static func set(background value: Bool) {
        let changed = background.withLock { state -> Bool in
            defer { state = value }
            return state != value
        }
        if changed { AppLog.player.info("appState=\(value ? "bg" : "fg")") }
    }
}

/// The Separator as the player's voice stage (MediaPipeline doesn't link ONNX Runtime).
struct SeparatorStage: VoiceStage {
    let separator: Separator

    func configure(sampleRate: Double, channels: Int) async throws {
        try await separator.configure(sampleRate: sampleRate, channels: channels)
    }

    func flush(passThrough: Bool?) async -> Int { await separator.flush(passThrough: passThrough) }
    func enqueue(_ samples: [Float], generation: Int) async { await separator.enqueue(samples, generation: generation) }
    func endOfStream(generation: Int) async { await separator.endOfStream(generation: generation) }

    func nextChunk() async -> VoiceChunk? {
        guard let chunk = await separator.nextChunk() else { return nil }
        return VoiceChunk(generation: chunk.generation, startFrame: chunk.startFrame, samples: chunk.voices,
                          isEndOfStream: chunk.isEndOfStream, isSilence: chunk.isSilence)
    }

    func beginHold() async { await separator.beginHold() }

    func holdStats() async -> VoiceHoldStats {
        let stats = await separator.holdStats
        return VoiceHoldStats(inputReadyAt: stats.inputReadyAt, queueMs: stats.queueMs,
                              waitModelMs: stats.waitModelMs, inferMs: stats.inferMs)
    }

    func close() async { await separator.close() }
}

/// A video's files as the engine needs them, from one VISIONOS `/player` request (the source walk
/// that tries other clients is US-015): the AAC file and, unless audio only, the H.264 file.
struct ResolvedMedia: Sendable {
    var videoID: String
    var title: String
    var author: String
    var audio: FMP4Source
    var audioMime: String
    var video: FMP4Source?
    /// `1080p60 avc1.640028`, for the screen and the log.
    var videoLabel: String?
    /// Every H.264 quality the answer offers (the quality picker), best first; `video` is one of them.
    var videoOptions: [VideoOption]
    /// The best Opus file (WebM), the sync check's reference: Opus states its encoder delay.
    var opus: MediaFile?
    /// The smallest VP9 file (WebM): the sync check's cross-check of the video timeline.
    var vp9: MediaFile?
    /// Seconds the AAC runs late without declaring it (`YouTubeAudio.delay`), for the engine.
    var audioDelay: Double
    /// The source that served it (the walk's winner).
    var client: String
    var playerMs: Int
}

/// One H.264 quality of a video, for the quality picker.
struct VideoOption: Identifiable, Hashable, Sendable {
    var id: Int { itag }
    var itag: Int
    /// `1080p60`, `720p`, …
    var label: String
    var source: FMP4Source

    static func == (lhs: VideoOption, rhs: VideoOption) -> Bool { lhs.itag == rhs.itag }
    func hash(into hasher: inout Hasher) { hasher.combine(itag) }

    /// The avc1 files the engine can play (≤ 1080p, ≤ 60 fps, with ranges), best first, one per label
    /// (the higher bitrate wins), the same rules as `FormatSelector`.
    static func options(_ formats: [PlayerAnswer.Format], source: (PlayerAnswer.Format) -> FMP4Source?) -> [VideoOption] {
        let playable = formats.filter {
            $0.container == "video/mp4" && $0.codecs.hasPrefix("avc1") && ($0.shortSide ?? .max) <= FormatSelector.maxAVCShortSide
                && ($0.fps ?? 30) <= 60
        }
        .sorted { ($0.shortSide ?? 0, $0.fps ?? 0, $0.bitrate ?? 0) > ($1.shortSide ?? 0, $1.fps ?? 0, $1.bitrate ?? 0) }
        var seen = Set<String>()
        return playable.compactMap { format in
            let fps = format.fps ?? 30
            let label = "\(format.shortSide ?? 0)p" + (fps > 30 ? "\(fps)" : "")
            guard !seen.contains(label), let file = source(format) else { return nil }
            seen.insert(label)
            return VideoOption(itag: format.itag, label: label, source: file)
        }
    }
}

/// YouTube's AAC-LC at 44.1 kHz runs 38.9 ms later than its Opus for the same audio, which no edit
/// list or gapless tag declares: measured by cross-correlating the two decodes of 5 videos (4 at
/// 38.9 ms, an older upload at 33.9 ms) and by a sync test's beeps (39.0 ms). The engine moves the
/// AAC earlier by this much so it lands on the timeline Opus states (DECISIONS D44). Android doesn't.
enum YouTubeAudio {
    static let aacDelay = 0.0389

    static func delay(codecs: String, sampleRate: Int?) -> Double {
        codecs == "mp4a.40.2" && sampleRate == 44_100 ? aacDelay : 0
    }
}

struct ResolveError: Error, CustomStringConvertible {
    let description: String
}

enum VideoResolver {
    /// Walks the sources (US-015), opens a ciphered winner (US-016), and picks the pair to play.
    @MainActor
    static func media(for videoID: String, withVideo: Bool) async throws -> ResolvedMedia {
        let services = PlaybackServices.shared
        let sources = services.sources
        let start = ContinuousClock.now
        let walk = await services.walker.walk(videoID: videoID, context: SourcePlanner.Context(lane: .signedOut)) { client, budget in
            await sources.attempt(client, videoID: videoID, budget: budget)
        }
        let walkMs = Int((ContinuousClock.now - start) / .milliseconds(1))
        AppLog.netPath.info("player-walk video=\(videoID) asked=\(walk.asked.map(\.id)) winner=\(walk.client?.id ?? "none") "
                            + "playable=\(walk.playable ? "y" : "n") ms=\(walkMs)" + (walk.fromCircuit ? " circuit=y" : ""))
        guard var answer = walk.answer else {
            throw ResolveError(description: "couldn't reach YouTube (\(walk.markers.last ?? "no answer"))")
        }
        guard walk.playable else {
            let reason = answer.playability.text ?? answer.playability.status
            throw ResolveError(description: "\(walk.client?.id ?? "?"): \(answer.kind.logValue) \(reason)")
        }
        guard !answer.isLive else { throw ResolveError(description: "live streams don't play yet") }
        let solveStart = ContinuousClock.now
        answer = try await services.cipher.resolve(answer, playerURL: try await services.identity.current().playerURL)
        let solveMs = Int((ContinuousClock.now - solveStart) / .milliseconds(1))
        if solveMs > 1 { AppLog.netPath.info("player-sig video=\(videoID) client=\(walk.client?.id ?? "?") ms=\(solveMs)") }
        let selection = FormatSelector.select(answer)
        guard let audioFormat = selection.audio, let audio = source(audioFormat) else {
            throw ResolveError(description: "no AAC file with ranges in the answer")
        }
        var video: FMP4Source?, label: String?
        var options: [VideoOption] = []
        if withVideo {
            guard let videoFormat = selection.video, let picture = source(videoFormat) else {
                throw ResolveError(description: "no H.264 file with ranges in the answer")
            }
            video = picture
            label = "\(videoFormat.shortSide ?? 0)p\(videoFormat.fps ?? 30) \(videoFormat.codecs)"
            options = VideoOption.options(answer.adaptiveFormats, source: source)
        }
        let opus = answer.adaptiveFormats
            .filter { $0.container == "audio/webm" && $0.codecs == "opus" && $0.url != nil && $0.contentLength != nil }
            .max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
            .flatMap { format in URL(string: format.url!).map {
                MediaFile(itag: format.itag, lastModified: format.lastModified, contentLength: format.contentLength!, url: $0)
            } }
        let vp9 = answer.adaptiveFormats
            .filter { $0.container == "video/webm" && $0.codecs.hasPrefix("vp9") && $0.url != nil && $0.contentLength != nil }
            .min { ($0.shortSide ?? .max) < ($1.shortSide ?? .max) }
            .flatMap { format in URL(string: format.url!).map {
                MediaFile(itag: format.itag, lastModified: format.lastModified, contentLength: format.contentLength!, url: $0)
            } }
        return ResolvedMedia(videoID: videoID, title: answer.details?.title ?? videoID, author: answer.details?.author ?? "",
                             audio: audio, audioMime: audioFormat.mimeType, video: video, videoLabel: label,
                             videoOptions: options, opus: opus, vp9: vp9,
                             audioDelay: YouTubeAudio.delay(codecs: audioFormat.codecs, sampleRate: audioFormat.audioSampleRate),
                             client: walk.client?.id ?? "?",
                             playerMs: Int((ContinuousClock.now - start) / .milliseconds(1)))
    }

    private static func source(_ format: PlayerAnswer.Format) -> FMP4Source? {
        guard let address = format.url, let url = URL(string: address), let length = format.contentLength,
              let initRange = format.initRange, let indexRange = format.indexRange else { return nil }
        return FMP4Source(file: MediaFile(itag: format.itag, lastModified: format.lastModified, contentLength: length, url: url),
                          initRange: initRange.start...initRange.end, indexRange: indexRange.start...indexRange.end)
    }
}

/// The audio session (PRD §4.5): `.playback` / `.moviePlayback`, so voices keep playing with the
/// screen locked (`UIBackgroundModes: audio`). A call or another app's audio pauses the player and
/// resumes it when iOS says so; unplugging headphones pauses it.
@MainActor
final class PlaybackAudioSession {
    static let shared = PlaybackAudioSession()

    /// Called on interruptions and route changes: false = pause, true = resume.
    var onPlayChange: ((Bool) -> Void)?
    private var observers: [any NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            MainActor.assumeIsolated { PlaybackAudioSession.shared.interrupted(type, options: options) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated { PlaybackAudioSession.shared.routeChanged(reason) }
        })
    }

    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .moviePlayback)
        try session.setActive(true)
        AppLog.player.info("audio session active rate=\(Int(session.sampleRate)) ioBufferMs=\(Int(session.ioBufferDuration * 1000)) "
                           + "route=\(session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: "+"))")
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func interrupted(_ type: AVAudioSession.InterruptionType?, options: AVAudioSession.InterruptionOptions?) {
        switch type {
        case .began:
            AppLog.player.info("audio interruption began")
            onPlayChange?(false)
        case .ended:
            let resume = options?.contains(.shouldResume) == true
            AppLog.player.info("audio interruption ended resume=\(resume)")
            if resume { onPlayChange?(true) }
        default:
            break
        }
    }

    private func routeChanged(_ reason: AVAudioSession.RouteChangeReason?) {
        guard reason == .oldDeviceUnavailable else { return }
        AppLog.player.info("audio route lost the output device; pausing")
        onPlayChange?(false)
    }
}
