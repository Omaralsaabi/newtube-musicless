import AVFoundation
import AVKit
import MediaPlayer
import Foundation
import MediaPipeline
import MusiclessCore
import Observation
import SwiftUI
import UIKit
import YouTubeEngine

/// The debug watch screen (US-014, the proof-of-concept milestone; US-012 and US-013 grew it): paste
/// a link and watch it without music. Play/pause, a seek bar, a quality picker, the Remove-music
/// switch (a flush, the engine is kept), "Preparing voices…" while holding, and the voice models'
/// progress while playback waits for them. The watch page proper is US-020.
@MainActor @Observable
final class WatchDebug: SystemPlaybackTarget {
    struct Preset: Identifiable, Hashable {
        let id: String
        let title: String
        let expect: String
    }

    /// Music-heavy videos for the ear test (PRD US-012), each testing a different mix.
    static let presets = [
        Preset(id: "aqz-KE-bpKQ", title: "Big Buck Bunny", expect: "Orchestral score, no speech: should be near silence"),
        Preset(id: "eRsGyueVLvQ", title: "Sintel", expect: "Dialogue over a loud score: voices only"),
        Preset(id: "h6fcK_fRYaI", title: "Kurzgesagt: The Egg", expect: "Narration over music: narration only"),
        Preset(id: "dQw4w9WgXcQ", title: "Rick Astley: Never Gonna Give You Up", expect: "A song: the singing without the band"),
    ]

    private(set) var title = ""
    private(set) var detail = ""
    private(set) var snapshot: PlayerEngine.Snapshot?
    private(set) var error: String?
    private(set) var resolving = false
    /// The picture of the current video; a new layer per video.
    private(set) var layer: AVSampleBufferDisplayLayer?
    private(set) var qualities: [VideoOption] = []
    private(set) var quality: VideoOption?
    var removeMusic = true
    /// Plays the voices without the picture (US-012's mode).
    var audioOnly = false

    /// Debug (US-017): the first answer's links refuse past 60 s of stream (`--synthetic-wall`).
    var syntheticWall = ProcessInfo.processInfo.arguments.contains("--synthetic-wall")
        || ProcessInfo.processInfo.arguments.contains("--wall-check")

    @ObservationIgnored private let models: ModelStore
    @ObservationIgnored private var engine: PlayerEngine?
    @ObservationIgnored private var playing: PlayingFiles?
    @ObservationIgnored private var pip: PictureInPicture?
    @ObservationIgnored private var nowPlayingTitle = ""
    @ObservationIgnored private var nowPlayingArtwork: URL?
    /// The speeds the picker offers (US-018).
    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    private(set) var speed: Float = 1
    /// The full-screen landscape view is showing.
    var fullScreen = false
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var tapAt: ContinuousClock.Instant?
    @ObservationIgnored private var playerMs = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init(models: ModelStore) {
        self.models = models
        PlaybackAudioSession.shared.onPlayChange = { [weak self] play in
            guard let engine = self?.engine else { return }
            Task { play ? await engine.play() : await engine.pause() }
        }
        // Background without PiP (PRD §4.2): stop feeding the picture; catch it up on the way back.
        let center = NotificationCenter.default
        // With PiP running (it starts as the app leaves), the picture keeps decoding.
        for (name, active) in [(UIApplication.didEnterBackgroundNotification, false),
                               (UIApplication.willEnterForegroundNotification, true),
                               (UIApplication.didBecomeActiveNotification, true)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let engine = self.engine else { return }
                    if active {
                        Task { await engine.setVideoActive(true) }
                        self.updateIdleTimer()
                        return
                    }
                    UIApplication.shared.isIdleTimerDisabled = false
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(600))  // PiP's will-start comes during the transition
                        if self.pip?.isActive == true {
                            AppLog.player.info("video stays on (pip) appState=\(AppActivity.logValue)")
                        } else {
                            await engine.setVideoActive(false)
                        }
                    }
                }
            })
        }
    }

    var isActive: Bool { engine != nil }

    var statusText: String {
        if let error { return "Failed: \(error)" }
        if resolving { return "Resolving…" }
        guard let snapshot else { return "Paste a link or pick a video" }
        switch snapshot.status {
        case .idle: return "Stopped"
        case .loading: return "Opening…"
        case .holding: return waitingText
        case .playing: return snapshot.removeMusic ? "Playing voices only" : "Playing the original audio"
        case .paused: return "Paused"
        case .ended: return "Ended"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    /// While holding: the models' download (playback waits for it) or the separation itself.
    var waitingText: String {
        guard snapshot?.removeMusic != false else { return "Loading…" }
        switch models.status {
        case .downloading(let percent): return "Downloading voice models… \(percent)%"
        case .notDownloaded: return "Downloading voice models…"
        case .failed(let message): return "Voice models failed: \(message)"
        case .ready: return "Preparing voices…"
        }
    }

    var isHolding: Bool {
        if case .holding = snapshot?.status { true } else { false }
    }

    func play(_ link: VideoLink) async {
        await play(link.videoID, at: link.startSeconds ?? 0)
    }

    func play(_ videoID: String, at seconds: Double = 0) async {
        await stop(reason: "new video")
        generation += 1
        let token = generation
        error = nil
        resolving = true
        title = videoID
        tapAt = .now
        AppLog.player.info("voices tap video=\(videoID) at=\(seconds) removeMusic=\(removeMusic) audioOnly=\(audioOnly)")
        do {
            let media = try await VideoResolver.media(for: videoID, withVideo: !audioOnly, synthetic: syntheticWall)
            guard token == generation else { return }
            title = media.title
            qualities = media.videoOptions
            quality = media.videoOptions.first { $0.source.file.itag == media.video?.file.itag }
            detail = [media.author, "itag \(media.audio.file.itag)"].joined(separator: " · ")
            playerMs = media.playerMs
            try PlaybackAudioSession.shared.activate()
            let runtime = PlaybackServices.shared.runtime(models: models)
            let separator = Separator(backend: runtime, log: { line in
                AppLog.musicless.info(line.hasPrefix("Window pipeline") ? line + " appState=\(AppActivity.logValue)" : line)
            })
            var video: VideoInput?
            if let picture = media.video {
                let layer = AVSampleBufferDisplayLayer()
                layer.videoGravity = .resizeAspect
                layer.backgroundColor = UIColor.black.cgColor
                self.layer = layer
                video = VideoInput(source: picture, fetcher: Self.fetcher(picture), renderer: layer.sampleBufferRenderer)
                pip = PictureInPicture(layer: layer, target: self)
                // PiP closed while the app is away: the background rule applies again.
                pip?.onStop = { [weak self] in
                    guard let engine = self?.engine, UIApplication.shared.applicationState == .background else { return }
                    Task { await engine.setVideoActive(false) }
                }
            }
            nowPlayingTitle = media.title
            nowPlayingArtwork = media.thumbnail
            NowPlaying.shared.begin(target: self, title: media.title, author: media.author, duration: nil, artwork: media.thumbnail)
            var configuration = PlayerEngine.Configuration()
            configuration.audioDelay = media.audioDelay
            if syntheticWall { configuration.syntheticWallSeconds = 60 }
            let playing = PlayingFiles(media)
            self.playing = playing
            let synthetic = syntheticWall
            let engine = PlayerEngine(
                audio: media.audio, fetcher: Self.fetcher(media.audio),
                stage: SeparatorStage(separator: separator), video: video, configuration: configuration,
                recover: { refusal in
                    await VideoResolver.recover(videoID: videoID, playing: playing, refusal: refusal, synthetic: synthetic)
                },
                log: { AppLog.player.info($0 + " appState=\(AppActivity.logValue)") },
                holdLog: { AppLog.musicless.info($0) },
                onChange: { [weak self] snapshot in Task { @MainActor in self?.changed(snapshot) } })
            self.engine = engine
            if speed != 1 { await engine.setSpeed(speed) }
            resolving = false
            AppLog.player.info("voices resolved video=\(videoID) title=\"\(media.title)\" video=\"\(media.videoLabel ?? "none")\" "
                               + "qualities=\(media.videoOptions.map(\.label).joined(separator: ",")) playerMs=\(media.playerMs)")
            startPolling()
            await engine.start(at: seconds, removeMusic: removeMusic)
        } catch {
            guard token == generation else { return }
            resolving = false
            self.error = "\(error)"
            AppLog.player.info("voices failed video=\(videoID) error=\(error)")
        }
    }

    private static func fetcher(_ source: FMP4Source) -> MediaFetcher {
        MediaFetcher(file: source.file, log: { AppLog.netPath.info($0) })
    }

    func togglePlay() async {
        guard let engine, let snapshot else { return }
        snapshot.wantsToPlay ? await engine.pause() : await engine.play()
        self.snapshot = await engine.snapshot()
    }

    func seek(to seconds: Double) async {
        await engine?.seek(to: seconds)
    }

    func skip(_ seconds: Double) async {
        guard let snapshot else { return }
        await seek(to: snapshot.position + seconds)
    }

    func setSpeed(_ value: Float) async {
        speed = value
        await engine?.setSpeed(value)
        if let engine { changed(await engine.snapshot()) }
    }

    func startPictureInPicture() { pip?.start() }

    // MARK: SystemPlaybackTarget (lock screen, Control Center, PiP)

    var systemSnapshot: PlayerEngine.Snapshot? { snapshot }
    func systemPlay() { Task { await engine?.play(); await refresh() } }
    func systemPause() { Task { await engine?.pause(); await refresh() } }
    func systemSkip(_ seconds: Double) { Task { await skip(seconds); await refresh() } }
    func systemSeek(to seconds: Double) { Task { await seek(to: seconds); await refresh() } }

    private func refresh() async {
        guard let engine else { return }
        changed(await engine.snapshot())
    }

    private func updateIdleTimer() {
        // The screen doesn't sleep while a picture plays in the foreground (US-018).
        UIApplication.shared.isIdleTimerDisabled = layer != nil && snapshot?.status == .playing
            && UIApplication.shared.applicationState == .active
    }

    func setRemoveMusic(_ on: Bool) async {
        removeMusic = on
        await engine?.setRemoveMusic(on)
    }

    func setQuality(_ option: VideoOption) async {
        guard let engine, option != quality else { return }
        quality = option
        AppLog.player.info("voices quality=\(option.label) itag=\(option.itag)")
        do {
            try await engine.switchVideo(to: option.source, fetcher: Self.fetcher(option.source))
            await playing?.video(option.source.file)
        } catch {
            AppLog.player.info("voices quality failed error=\(error)")
        }
    }

    /// Ends playback; `reason` goes to the log (`voices stop reason=…`).
    func stop(reason: String) async {
        poll?.cancel()
        poll = nil
        if let engine {
            AppLog.player.info("voices stop reason=\(reason) appState=\(AppActivity.logValue)")
            self.engine = nil
            pip?.stop()
            pip = nil
            NowPlaying.shared.end()
            await engine.close()
            PlaybackAudioSession.shared.deactivate()
        }
        UIApplication.shared.isIdleTimerDisabled = false
        layer = nil
        snapshot = nil
        qualities = []
        quality = nil
    }

    /// US-013's seek measurement (`--seek-check`): 10 seeks spread over the video, each timed from the
    /// call until the voices and the picture play again, then 3 s of playback.
    func runSeekCheck() async {
        guard let engine, let duration = await engine.snapshot().duration, duration > 60 else {
            AppLog.player.info("seek-check needs a playing video longer than a minute")
            return
        }
        let fractions = [0.15, 0.62, 0.33, 0.81, 0.07, 0.48, 0.91, 0.26, 0.70, 0.40]
        var results: [Int] = []
        for (number, fraction) in fractions.enumerated() {
            let target = (duration * fraction).rounded()
            let start = ContinuousClock.now
            await engine.seek(to: target)
            var ready = false
            while ContinuousClock.now - start < .seconds(10) {
                if await engine.snapshot().status == .playing {
                    ready = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            let ms = Int((ContinuousClock.now - start) / .milliseconds(1))
            results.append(ready ? ms : 10_000)
            AppLog.player.info("seek-check n=\(number + 1) to=\(Int(target)) readyMs=\(ready ? "\(ms)" : "timeout")")
            try? await Task.sleep(for: .seconds(3))
        }
        let sorted = results.sorted()
        AppLog.player.info("seek-check done median=\((sorted[4] + sorted[5]) / 2) min=\(sorted.first!) max=\(sorted.last!) "
                           + "values=\(results.map(String.init).joined(separator: ","))")
    }

    /// US-013's background measurement (`--background-test`), unattended: 3 times, after 10 s of
    /// playback in the foreground, open the Files app so this one goes to the background (the voices
    /// play on), and wait for something to bring it back (`devicectl device process launch` without
    /// terminating it, from the Mac). The engine logs `video resume` and `video first-frame reason=resume`.
    func runBackgroundTest() async {
        for round in 1...3 {
            while UIApplication.shared.applicationState != .active || snapshot?.status != .playing {
                try? await Task.sleep(for: .milliseconds(200))
            }
            try? await Task.sleep(for: .seconds(10))
            AppLog.player.info("background-test round=\(round) leaving")
            await UIApplication.shared.open(URL(string: "shareddocuments://")!)
            while UIApplication.shared.applicationState == .active { try? await Task.sleep(for: .milliseconds(100)) }
            while UIApplication.shared.applicationState != .active { try? await Task.sleep(for: .milliseconds(100)) }
            AppLog.player.info("background-test round=\(round) back")
        }
        try? await Task.sleep(for: .seconds(5))
        AppLog.player.info("background-test done")
    }

    /// US-017's synthetic-wall check (`--wall-check`): 4 videos, each from 0:50 with its first
    /// answer's links refusing past 60 s of stream. A round passes when playback reaches 1:15 with no
    /// failure and no rewind (the position never goes back more than 0.2 s).
    func runWallCheck() async {
        var passed = 0
        for (round, preset) in Self.presets.enumerated() {
            await play(preset.id, at: 50)
            let start = ContinuousClock.now
            var highest = 0.0, rewind = false, result = "timeout"
            while ContinuousClock.now - start < .seconds(75) {
                try? await Task.sleep(for: .milliseconds(100))
                guard let snapshot else { continue }
                if case .failed = snapshot.status {
                    result = "failed"
                    break
                }
                if snapshot.position < highest - 0.2 { rewind = true }
                highest = max(highest, snapshot.position)
                if snapshot.position >= 75 {
                    result = rewind ? "rewind" : "ok"
                    break
                }
            }
            if result == "ok" { passed += 1 }
            AppLog.player.info("wall-check round=\(round + 1) video=\(preset.id) result=\(result) highest=\(String(format: "%.1f", highest)) "
                               + "rewind=\(rewind ? "y" : "n") error=\(error ?? "none")")
        }
        await stop(reason: "wall-check done")
        AppLog.player.info("wall-check done passed=\(passed)/\(Self.presets.count)")
    }

    /// US-018's `--system-check`: each speed against the clock, Now Playing and the remote-command
    /// handlers, the idle timer, full screen, then PiP started by leaving for the Files app (bring the
    /// app back with `devicectl … process launch` without `--terminate-existing`).
    func runSystemCheck() async {
        func log(_ line: String) { AppLog.player.info("system-check \(line) appState=\(AppActivity.logValue)") }
        func current() async -> PlayerEngine.Snapshot? { await engine?.snapshot() }
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
        while snapshot?.status != .playing { await wait(0.2) }
        await wait(4)
        var passed = 0, total = 0
        func result(_ ok: Bool) -> String {
            total += 1
            if ok { passed += 1 }
            return ok ? "ok" : "failed"
        }

        // Speeds: the playhead's advance over 6 s of wall time.
        for value in [0.5, 1.5, 2, 1] as [Float] {
            await setSpeed(value)
            await wait(1)
            guard let start = await current() else { return }
            let began = ContinuousClock.now
            await wait(6)
            guard let end = await current() else { return }
            let measured = (end.position - start.position) / ((ContinuousClock.now - began) / .milliseconds(1) / 1000)
            let ok = abs(measured - Double(value)) / Double(value) < 0.05
            log("speed=\(value) measured=\(String(format: "%.3f", measured)) status=\(end.status) result=\(result(ok))")
        }

        // Now Playing (the system extrapolates the position from the last elapsed and rate), and the
        // handlers the remote commands call.
        func published() -> (elapsed: Double, rate: Double, info: [String: Any]) {
            let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            let rate = (info[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue ?? -1
            let elapsed = (info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber)?.doubleValue ?? -1
            return (elapsed + max(rate, 0) * NowPlaying.shared.secondsSincePublish, rate, info)
        }
        let now = published(), position = await current()?.position ?? 0
        let infoOK = now.info[MPMediaItemPropertyTitle] as? String == title && now.info[MPMediaItemPropertyArtist] != nil
            && now.info[MPMediaItemPropertyPlaybackDuration] != nil && abs(now.elapsed - position) < 1 && now.rate == 1
        log("now-playing title=\(now.info[MPMediaItemPropertyTitle] != nil ? "y" : "n") artist=\(now.info[MPMediaItemPropertyArtist] != nil ? "y" : "n") "
            + "artwork=\(now.info[MPMediaItemPropertyArtwork] != nil ? "y" : "n") duration=\(now.info[MPMediaItemPropertyPlaybackDuration] ?? "none") "
            + "elapsed=\(String(format: "%.2f", now.elapsed)) position=\(String(format: "%.2f", position)) rate=\(now.rate) "
            + "publishes=\(NowPlaying.shared.publishes) result=\(result(infoOK))")
        let idlePlaying = UIApplication.shared.isIdleTimerDisabled
        systemPause()
        await wait(1)
        let pausedRate = published().rate
        let paused = await current()
        let idlePaused = UIApplication.shared.isIdleTimerDisabled
        log("pause wantsToPlay=\(paused?.wantsToPlay ?? true) rate=\(pausedRate) idleTimerOff=\(idlePaused) "
            + "result=\(result(paused?.wantsToPlay == false && pausedRate == 0 && !idlePaused))")
        systemPlay()
        await wait(1.5)
        log("idle-timer playing=\(idlePlaying ? "off" : "on") paused=\(idlePaused ? "off" : "on") result=\(result(idlePlaying && !idlePaused))")
        let before = await current()?.position ?? 0
        systemSkip(10)
        await wait(2)
        let skipped = await current()?.position ?? 0
        log("skip from=\(String(format: "%.1f", before)) to=\(String(format: "%.1f", skipped)) result=\(result(skipped - before > 10 && skipped - before < 13.5))")
        systemSeek(to: 30)
        await wait(2)
        let sought = await current()?.position ?? 0
        log("scrub to=30 at=\(String(format: "%.1f", sought)) result=\(result(sought >= 30 && sought < 33.5))")

        // Full screen: the scene turns landscape, the layer fills it, and back.
        func orientation() -> String {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return "none" }
            return scene.effectiveGeometry.interfaceOrientation.isLandscape ? "landscape" : "portrait"
        }
        fullScreen = true
        await wait(3)
        let landscape = orientation(), bounds = layer?.bounds.size ?? .zero
        log("full-screen showing")
        await wait(2)
        log("full-screen orientation=\(landscape) layer=\(Int(bounds.width))x\(Int(bounds.height)) "
            + "result=\(result(landscape == "landscape" && bounds.width > bounds.height))")
        fullScreen = false
        await wait(3)
        let inline = layer?.superlayer != nil && (layer?.bounds.width ?? 0) < (layer?.bounds.height ?? 0) * 3
        log("full-screen closed orientation=\(orientation()) layer=\(Int(layer?.bounds.width ?? 0))x\(Int(layer?.bounds.height ?? 0)) "
            + "hosted=\(layer?.superlayer != nil) result=\(result(orientation() == "portrait" && inline))")
        await wait(2)

        // PiP: starts on its own as the app leaves; the picture keeps decoding while away.
        log("pip supported=\(AVPictureInPictureController.isPictureInPictureSupported()) controller=\(pip != nil) possible=\(pip?.isPossible == true)")
        await UIApplication.shared.open(URL(string: "shareddocuments://")!)
        while UIApplication.shared.applicationState == .active { await wait(0.1) }
        await wait(3)
        let started = pip?.isActive == true
        var aheads: [Double] = []
        let awayStart = await current()?.position ?? 0
        for _ in 0..<8 {
            await wait(1)
            if let now = await current() { aheads.append(now.videoActive ? now.videoAheadSeconds ?? 0 : -1) }
        }
        let awayEnd = await current()?.position ?? 0
        let decoding = !aheads.isEmpty && aheads.allSatisfy { $0 > 0 }
        log("pip started=\(started) videoAhead=\(aheads.map { String(format: "%.2f", $0) }) moved=\(String(format: "%.1f", awayEnd - awayStart)) "
            + "result=\(result(started && decoding && awayEnd - awayStart > 6))")
        log("waiting for the app to come back")
        while UIApplication.shared.applicationState != .active { await wait(0.2) }
        pip?.stop()
        await wait(3)
        log("back pip=\(pip?.isActive == true) status=\(snapshot.map { "\($0.status)" } ?? "none")")
        log("done passed=\(passed)/\(total)")
    }

    /// `--quality-check`: after 8 s of playback, step through every quality, 8 s each.
    func runQualityCheck() async {
        while snapshot?.status != .playing { try? await Task.sleep(for: .milliseconds(200)) }
        for option in qualities.reversed() + qualities.prefix(1) {
            try? await Task.sleep(for: .seconds(8))
            await setQuality(option)
        }
        try? await Task.sleep(for: .seconds(8))
        AppLog.player.info("quality-check done")
    }

    private func changed(_ snapshot: PlayerEngine.Snapshot) {
        self.snapshot = snapshot
        NowPlaying.shared.update(snapshot)
        pip?.invalidate()
        updateIdleTimer()
        if snapshot.status == .playing, let tapAt {
            self.tapAt = nil
            AppLog.player.info("voices tap-to-first-audio ms=\(Int((ContinuousClock.now - tapAt) / .milliseconds(1))) "
                               + "playerMs=\(playerMs) appState=\(AppActivity.logValue)")
        }
    }

    private func startPolling() {
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let engine = self?.engine else { return }
                let snapshot = await engine.snapshot()
                self?.snapshot = snapshot
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

/// The player lives in `watch`, which RootView owns and stops when this screen's route is popped,
/// not on `onDisappear`, so nothing the system does to the view (a lock, a sheet) can stop it.
struct WatchDebugView: View {
    let watch: WatchDebug
    var autoPlay: (id: String, at: Double)?
    var seekCheck = false
    var backgroundTest = false
    var qualityCheck = false
    var wallCheck = false
    var systemCheck = false
    @State private var link = ""
    /// The seek bar's value while it is being dragged; nil otherwise.
    @State private var scrub: Double?

    var body: some View {
        List {
            Section {
                if let layer = watch.layer {
                    VideoLayerView(layer: layer, active: !watch.fullScreen)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay { overlay }
                        .listRowInsets(EdgeInsets())
                } else if watch.isActive {
                    Color.black.aspectRatio(16 / 9, contentMode: .fit)
                        .overlay { overlay }
                        .listRowInsets(EdgeInsets())
                }
                linkRow
            }
            if watch.isActive || watch.error != nil || watch.resolving {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(watch.title).font(.headline)
                        if !watch.detail.isEmpty {
                            Text(watch.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                        Text(watch.statusText).font(.callout)
                    }
                    .textSelection(.enabled)
                    if let snapshot = watch.snapshot { seekBar(snapshot) }
                    controls
                    Toggle("Remove music", isOn: Binding(get: { watch.removeMusic },
                                                         set: { on in Task { await watch.setRemoveMusic(on) } }))
                    Picker("Speed", selection: Binding(get: { watch.speed }, set: { value in Task { await watch.setSpeed(value) } })) {
                        ForEach(WatchDebug.speeds, id: \.self) { value in Text(value == 1 ? "Normal" : "\(value.formatted())×").tag(value) }
                    }
                    if watch.layer != nil {
                        HStack {
                            Button("Full screen") { watch.fullScreen = true }
                            Spacer()
                            Button("Picture in Picture") { watch.startPictureInPicture() }
                        }
                        .buttonStyle(.borderless)
                    }
                    if !watch.qualities.isEmpty {
                        // Selected by itag: SwiftUI may read the binding once more after `stop()` empties the list.
                        Picker("Quality", selection: Binding(get: { watch.quality?.itag ?? watch.qualities.first?.itag ?? 0 },
                                                             set: { itag in
                                                                 guard let option = watch.qualities.first(where: { $0.itag == itag }) else { return }
                                                                 Task { await watch.setQuality(option) }
                                                             })) {
                            ForEach(watch.qualities) { option in Text(option.label).tag(option.itag) }
                        }
                    }
                }
            }
            Section {
                ForEach(WatchDebug.presets) { preset in
                    Button {
                        Task { await watch.play(preset.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.title)
                            Text(preset.expect).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Videos")
            } footer: {
                Text("Plays the video with the music removed. Switch Remove music off to hear the original. "
                     + "Lock the screen: the voices keep playing.")
            }
            Section("Debug") {
                ModelStatusRow()
                Toggle("Audio only", isOn: Binding(get: { watch.audioOnly }, set: { watch.audioOnly = $0 }))
                Toggle("Synthetic wall at 1:00", isOn: Binding(get: { watch.syntheticWall }, set: { watch.syntheticWall = $0 }))
            }
        }
        .navigationTitle("Watch (debug)")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: Binding(get: { watch.fullScreen }, set: { watch.fullScreen = $0 })) {
            if let layer = watch.layer { FullScreenVideo(watch: watch, layer: layer) }
        }
        .onChange(of: watch.fullScreen) { _, on in FullScreenVideo.rotate(on ? .landscape : .portrait) }
        .task {
            if wallCheck {
                await watch.runWallCheck()
                return
            }
            guard let autoPlay else { return }
            await watch.play(autoPlay.id, at: autoPlay.at)
            if seekCheck {
                while watch.snapshot?.status != .playing { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .seconds(3))
                await watch.runSeekCheck()
            }
            if backgroundTest { await watch.runBackgroundTest() }
            if qualityCheck { await watch.runQualityCheck() }
            if systemCheck { await watch.runSystemCheck() }
        }
    }

    @ViewBuilder private var overlay: some View {
        if watch.isHolding {
            VStack(spacing: 8) {
                ProgressView()
                Text(watch.waitingText).font(.callout)
            }
            .padding(12)
            .background(.black.opacity(0.65), in: .rect(cornerRadius: 10))
            .foregroundStyle(.white)
        }
    }

    private var linkRow: some View {
        HStack {
            TextField("YouTube link or video id", text: $link)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit(open)
            // PasteButton reads the clipboard without the paste prompt.
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first else { return }
                Task { @MainActor in
                    link = text
                    open()
                }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.capsule)
            Button("Play", action: open)
                .disabled(VideoLink.parse(link) == nil)
        }
    }

    private func open() {
        guard let parsed = VideoLink.parse(link) else { return }
        Task { await watch.play(parsed) }
    }

    private func seekBar(_ snapshot: PlayerEngine.Snapshot) -> some View {
        let duration = max(snapshot.duration ?? 0, 1)
        return VStack(spacing: 2) {
            Slider(value: Binding(get: { scrub ?? min(snapshot.position, duration) }, set: { scrub = $0 }),
                   in: 0...duration) { editing in
                if !editing, let target = scrub {
                    Task {
                        await watch.seek(to: target)
                        scrub = nil
                    }
                }
            }
            HStack {
                Text(Self.clock(scrub ?? snapshot.position))
                Spacer()
                Text(Self.buffers(snapshot)).foregroundStyle(.tertiary)
                Spacer()
                Text(Self.clock(snapshot.duration ?? 0))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        // Timelines and playback controls show the tape's direction, so they aren't mirrored in
        // right-to-left languages (Apple HIG, "Right to left").
        .environment(\.layoutDirection, .leftToRight)
    }

    private var controls: some View {
        HStack(spacing: 28) {
            Button { Task { await watch.skip(-10) } } label: { Image(systemName: "gobackward.10") }
                .accessibilityLabel("Back 10 seconds")
            Button { Task { await watch.togglePlay() } } label: {
                Image(systemName: watch.snapshot?.wantsToPlay == false ? "play.fill" : "pause.fill")
            }
            .accessibilityLabel(watch.snapshot?.wantsToPlay == false ? "Play" : "Pause")
            Button { Task { await watch.skip(10) } } label: { Image(systemName: "goforward.10") }
                .accessibilityLabel("Forward 10 seconds")
            Spacer()
            Button("Stop", role: .destructive) { Task { await watch.stop(reason: "stop button") } }
        }
        .buttonStyle(.borderless)
        .font(.title3)
        .environment(\.layoutDirection, .leftToRight)
    }

    static func buffers(_ snapshot: PlayerEngine.Snapshot) -> String {
        var line = "voices \(String(format: "%.1f", max(0, snapshot.aheadSeconds))) s"
        if let video = snapshot.videoAheadSeconds {
            line += snapshot.videoActive ? " · picture \(String(format: "%.1f", max(0, video))) s" : " · picture off"
        }
        return line
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return total >= 3_600 ? String(format: "%d:%02d:%02d", total / 3_600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Hosts the engine's display layer (the app keeps the layer; the engine feeds its renderer).
struct VideoLayerView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    /// Whether this view should hold the layer: the inline view and the full-screen one share it, and
    /// the change of this flag is what makes SwiftUI call `updateUIView` so the layer moves back.
    var active = true

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.backgroundColor = .black
        if active { view.host(layer) }
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {
        if active { view.host(layer) }
    }

    final class HostView: UIView {
        private var hosted: CALayer?

        func host(_ layer: CALayer) {
            // Also when the layer was moved away (the full-screen view hosts the same layer).
            guard hosted !== layer || layer.superlayer !== self.layer else { return }
            if hosted !== layer, hosted?.superlayer === self.layer { hosted?.removeFromSuperlayer() }
            self.layer.addSublayer(layer)
            hosted = layer
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.frame = bounds
            CATransaction.commit()
        }
    }
}

/// Full-screen landscape (US-018): the same display layer, rotated to landscape; a tap shows the
/// controls. Closing it puts the layer back in the screen.
struct FullScreenVideo: View {
    let watch: WatchDebug
    let layer: AVSampleBufferDisplayLayer
    @Environment(\.dismiss) private var dismiss
    @State private var controls = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoLayerView(layer: layer, active: watch.fullScreen).ignoresSafeArea()
            if controls {
                VStack {
                    HStack {
                        Button { dismiss() } label: { Image(systemName: "xmark").font(.title2) }
                            .accessibilityLabel("Close full screen")
                        Spacer()
                        Text(watch.title).lineLimit(1).font(.headline)
                        Spacer()
                    }
                    Spacer()
                    HStack(spacing: 40) {
                        Button { Task { await watch.skip(-10) } } label: { Image(systemName: "gobackward.10") }
                        Button { Task { await watch.togglePlay() } } label: {
                            Image(systemName: watch.snapshot?.wantsToPlay == false ? "play.fill" : "pause.fill")
                        }
                        Button { Task { await watch.skip(10) } } label: { Image(systemName: "goforward.10") }
                    }
                    .font(.largeTitle)
                    .environment(\.layoutDirection, .leftToRight)
                    Spacer()
                }
                .padding()
                .foregroundStyle(.white)
                .background(.black.opacity(0.35))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { controls.toggle() }
        .statusBarHidden()
    }

    /// The orientation lock changes, and telling the controllers so rotates the scene: the current
    /// orientation is no longer allowed. (An explicit `requestGeometryUpdate` on top of it raced the
    /// controllers' update and was refused, though the rotation happened.)
    static func rotate(_ orientations: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        AppDelegate.orientations = orientations
        var controller = scene.windows.first { $0.isKeyWindow }?.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
    }
}
