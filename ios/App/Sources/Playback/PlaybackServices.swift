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

/// A video's audio file as the player needs it, from one VISIONOS `/player` request (the source walk
/// that tries other clients is US-015).
struct ResolvedAudio: Sendable {
    var videoID: String
    var title: String
    var author: String
    var source: VoiceSource
    var mimeType: String
    var playerMs: Int
}

struct ResolveError: Error, CustomStringConvertible {
    let description: String
}

enum VideoResolver {
    @MainActor
    static func audio(for videoID: String) async throws -> ResolvedAudio {
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
        guard let format = FormatSelector.select(answer).audio, let address = format.url, let url = URL(string: address),
              let length = format.contentLength, let initRange = format.initRange, let indexRange = format.indexRange else {
            throw ResolveError(description: "no AAC file with ranges in the answer")
        }
        let file = MediaFile(itag: format.itag, lastModified: format.lastModified, contentLength: length, url: url)
        return ResolvedAudio(videoID: videoID, title: answer.details?.title ?? videoID, author: answer.details?.author ?? "",
                             source: VoiceSource(file: file, initRange: initRange.start...initRange.end,
                                                 indexRange: indexRange.start...indexRange.end),
                             mimeType: format.mimeType, playerMs: Int((ContinuousClock.now - start) / .milliseconds(1)))
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
