import AVFoundation
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
final class WatchDebug {
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

    @ObservationIgnored private let models: ModelStore
    @ObservationIgnored private var engine: PlayerEngine?
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
        for (name, active) in [(UIApplication.didEnterBackgroundNotification, false),
                               (UIApplication.willEnterForegroundNotification, true),
                               (UIApplication.didBecomeActiveNotification, true)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let engine = self?.engine else { return }
                    Task { await engine.setVideoActive(active) }
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
            let media = try await VideoResolver.media(for: videoID, withVideo: !audioOnly)
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
            }
            var configuration = PlayerEngine.Configuration()
            configuration.audioDelay = media.audioDelay
            let engine = PlayerEngine(
                audio: media.audio, fetcher: Self.fetcher(media.audio),
                stage: SeparatorStage(separator: separator), video: video, configuration: configuration,
                log: { AppLog.player.info($0 + " appState=\(AppActivity.logValue)") },
                holdLog: { AppLog.musicless.info($0) },
                onChange: { [weak self] snapshot in Task { @MainActor in self?.changed(snapshot) } })
            self.engine = engine
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
            await engine.close()
            PlaybackAudioSession.shared.deactivate()
        }
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
    @State private var link = ""
    /// The seek bar's value while it is being dragged; nil otherwise.
    @State private var scrub: Double?

    var body: some View {
        List {
            Section {
                if let layer = watch.layer {
                    VideoLayerView(layer: layer)
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
                    if !watch.qualities.isEmpty {
                        Picker("Quality", selection: Binding(get: { watch.quality ?? watch.qualities[0] },
                                                             set: { option in Task { await watch.setQuality(option) } })) {
                            ForEach(watch.qualities) { option in Text(option.label).tag(option) }
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
            }
        }
        .navigationTitle("Watch (debug)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let autoPlay else { return }
            await watch.play(autoPlay.id, at: autoPlay.at)
            if seekCheck {
                while watch.snapshot?.status != .playing { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .seconds(3))
                await watch.runSeekCheck()
            }
            if backgroundTest { await watch.runBackgroundTest() }
            if qualityCheck { await watch.runQualityCheck() }
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

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.backgroundColor = .black
        view.host(layer)
        return view
    }

    func updateUIView(_ view: HostView, context: Context) { view.host(layer) }

    final class HostView: UIView {
        private var hosted: CALayer?

        func host(_ layer: CALayer) {
            guard hosted !== layer else { return }
            hosted?.removeFromSuperlayer()
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
