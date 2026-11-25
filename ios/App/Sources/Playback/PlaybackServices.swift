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
    private var memoryObserver: (any NSObjectProtocol)?

    private init() {
        identity = VisitorIdentity(transport: transport,
                                   storeURL: URL.applicationSupportDirectory.appending(path: "youtube/visitor.json"),
                                   log: { AppLog.netPath.info($0) })
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AppLog.musicless.info("Memory warning")
                if let runtime = PlaybackServices.shared.runtime { Task { await runtime.didReceiveMemoryWarning() } }
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
    /// The best Opus file (WebM), the sync check's reference: Opus states its encoder delay.
    var opus: MediaFile?
    /// The smallest VP9 file (WebM): the sync check's cross-check of the video timeline.
    var vp9: MediaFile?
    /// Seconds the AAC runs late without declaring it (`YouTubeAudio.delay`), for the engine.
    var audioDelay: Double
    var playerMs: Int
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
    @MainActor
    static func media(for videoID: String, withVideo: Bool) async throws -> ResolvedMedia {
        let services = PlaybackServices.shared
        let transport = services.transport, identity = services.identity
        let start = ContinuousClock.now
        let visitor = try await identity.current()
        let locale = RequestLocale.current
        let body = PlayerRequestBody(client: .visionOS, videoID: videoID, cpn: PlayerRequestBody.makeCPN(),
                                     visitorData: visitor.visitorData, signatureTimestamp: await identity.signatureTimestamp(),
                                     acceptLanguage: locale.language, acceptRegion: locale.region,
                                     utcOffsetMinutes: locale.utcOffsetMinutes)
        let response = try await transport.send(InnerTubeTransport.playerRequest(body), label: "VISIONOS")
        let answer = try PlayerAnswer(json: response.data)
        guard answer.kind == .served else {
            throw ResolveError(description: "VISIONOS: \(answer.kind.logValue) \(answer.playability.reason ?? "")")
        }
        let selection = FormatSelector.select(answer)
        guard let audioFormat = selection.audio, let audio = source(audioFormat) else {
            throw ResolveError(description: "no AAC file with ranges in the answer")
        }
        var video: FMP4Source?, label: String?
        if withVideo {
            guard let videoFormat = selection.video, let picture = source(videoFormat) else {
                throw ResolveError(description: "no H.264 file with ranges in the answer")
            }
            video = picture
            label = "\(videoFormat.shortSide ?? 0)p\(videoFormat.fps ?? 30) \(videoFormat.codecs)"
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
                             audio: audio, audioMime: audioFormat.mimeType, video: video, videoLabel: label, opus: opus, vp9: vp9,
                             audioDelay: YouTubeAudio.delay(codecs: audioFormat.codecs, sampleRate: audioFormat.audioSampleRate),
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
