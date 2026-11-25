import AVFoundation
import Foundation
import MediaPipeline
import MusiclessCore
import Observation
import SwiftUI
import UIKit

/// The debug watch screen: a YouTube video with only the voices, the picture on the same clock
/// (US-012, US-013). US-014 turns it into the proof-of-concept watch screen (link parsing, seek bar,
/// quality picker).
@MainActor @Observable
final class VoicesCheck {
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

    var statusText: String {
        if let error { return "Failed: \(error)" }
        if resolving { return "Resolving…" }
        guard let snapshot else { return "Pick a video" }
        switch snapshot.status {
        case .idle: return "Stopped"
        case .loading: return "Opening…"
        case .holding: return "Preparing voices…"
        case .playing: return snapshot.removeMusic ? "Playing voices only" : "Playing the original audio"
        case .paused: return "Paused"
        case .ended: return "Ended"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    var isActive: Bool { engine != nil }

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
            detail = [media.author, media.videoLabel, "itag \(media.audio.file.itag)"].compactMap { $0 }.joined(separator: " · ")
            playerMs = media.playerMs
            try PlaybackAudioSession.shared.activate()
            let runtime = PlaybackServices.shared.runtime(models: models)
            let separator = Separator(backend: runtime, log: { line in
                AppLog.musicless.info(line.hasPrefix("Window pipeline") ? line + " appState=\(AppActivity.logValue)" : line)
            })
            let netLog: @Sendable (String) -> Void = { AppLog.netPath.info($0) }
            var video: VideoInput?
            if let picture = media.video {
                let layer = AVSampleBufferDisplayLayer()
                layer.videoGravity = .resizeAspect
                layer.backgroundColor = UIColor.black.cgColor
                self.layer = layer
                video = VideoInput(source: picture, fetcher: MediaFetcher(file: picture.file, log: netLog),
                                   renderer: layer.sampleBufferRenderer)
            }
            var configuration = PlayerEngine.Configuration()
            configuration.audioDelay = media.audioDelay
            let engine = PlayerEngine(
                audio: media.audio, fetcher: MediaFetcher(file: media.audio.file, log: netLog),
                stage: SeparatorStage(separator: separator), video: video, configuration: configuration,
                log: { AppLog.player.info($0 + " appState=\(AppActivity.logValue)") },
                holdLog: { AppLog.musicless.info($0) },
                onChange: { [weak self] snapshot in Task { @MainActor in self?.changed(snapshot) } })
            self.engine = engine
            resolving = false
            AppLog.player.info("voices resolved video=\(videoID) title=\"\(media.title)\" video=\"\(media.videoLabel ?? "none")\" "
                               + "playerMs=\(media.playerMs)")
            startPolling()
            await engine.start(at: seconds, removeMusic: removeMusic)
        } catch {
            guard token == generation else { return }
            resolving = false
            self.error = "\(error)"
            AppLog.player.info("voices failed video=\(videoID) error=\(error)")
        }
    }

    func togglePlay() async {
        guard let engine, let snapshot else { return }
        snapshot.wantsToPlay ? await engine.pause() : await engine.play()
        self.snapshot = await engine.snapshot()
    }

    func skip(_ seconds: Double) async {
        guard let engine, let snapshot else { return }
        await engine.seek(to: snapshot.position + seconds)
    }

    func setRemoveMusic(_ on: Bool) async {
        removeMusic = on
        await engine?.setRemoveMusic(on)
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
                if await engine.snapshot().status == .playing { ready = true; break }
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

/// The player lives in `check`, which RootView owns and stops when this screen's route is popped,
/// not on `onDisappear`, so nothing the system does to the view (a lock, a sheet) can stop it.
struct VoicesCheckView: View {
    let check: VoicesCheck
    var autoPlay: (id: String, at: Double)?
    var seekCheck = false
    var backgroundTest = false
    @State private var custom = ""

    var body: some View {
        List {
            if let layer = check.layer {
                Section {
                    VideoLayerView(layer: layer)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay {
                            if case .holding = check.snapshot?.status {
                                ProgressView("Preparing voices…")
                                    .padding(10)
                                    .background(.black.opacity(0.6), in: .rect(cornerRadius: 8))
                            }
                        }
                        .listRowInsets(EdgeInsets())
                }
            }
            if check.isActive || check.error != nil || check.resolving {
                Section("Now playing") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(check.title).font(.headline)
                        if !check.detail.isEmpty {
                            Text(check.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                        Text(check.statusText).font(.callout)
                        if let snapshot = check.snapshot {
                            Text(Self.timeLine(snapshot))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .textSelection(.enabled)
                    HStack(spacing: 24) {
                        Button { Task { await check.skip(-10) } } label: { Image(systemName: "gobackward.10") }
                        Button { Task { await check.togglePlay() } } label: {
                            Image(systemName: check.snapshot?.wantsToPlay == false ? "play.fill" : "pause.fill")
                        }
                        Button { Task { await check.skip(30) } } label: { Image(systemName: "goforward.30") }
                        Spacer()
                        Button("Stop", role: .destructive) { Task { await check.stop(reason: "stop button") } }
                    }
                    .buttonStyle(.borderless)
                    .font(.title3)
                    Toggle("Remove music", isOn: Binding(get: { check.removeMusic },
                                                         set: { on in Task { await check.setRemoveMusic(on) } }))
                }
            }
            Section {
                ModelStatusRow()
                Toggle("Audio only", isOn: Binding(get: { check.audioOnly }, set: { check.audioOnly = $0 }))
            }
            Section {
                ForEach(VoicesCheck.presets) { preset in
                    Button {
                        Task { await check.play(preset.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.title)
                            Text(preset.expect)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    TextField("Video id or link", text: $custom)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Play") {
                        if let id = Self.videoID(in: custom) { Task { await check.play(id) } }
                    }
                    .disabled(Self.videoID(in: custom) == nil)
                }
            } header: {
                Text("Videos")
            } footer: {
                Text("Plays the video with the music removed. Switch Remove music off to hear the "
                     + "original. Lock the screen: the voices should keep playing.")
            }
        }
        .navigationTitle("Watch (debug)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let autoPlay else { return }
            await check.play(autoPlay.id, at: autoPlay.at)
            if seekCheck {
                while check.snapshot?.status != .playing { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .seconds(3))
                await check.runSeekCheck()
            }
            if backgroundTest { await check.runBackgroundTest() }
        }
    }

    static func timeLine(_ snapshot: PlayerEngine.Snapshot) -> String {
        var line = "\(clock(snapshot.position)) / \(clock(snapshot.duration ?? 0)) · "
            + "voices \(String(format: "%.1f", max(0, snapshot.aheadSeconds))) s"
        if let video = snapshot.videoAheadSeconds {
            line += snapshot.videoActive ? " · picture \(String(format: "%.1f", max(0, video))) s" : " · picture off"
        }
        return line
    }

    /// A bare 11-character id, or one inside a watch, youtu.be, shorts or embed link (US-014 parses
    /// links properly).
    static func videoID(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.wholeMatch(of: /[A-Za-z0-9_-]{11}/) != nil { return trimmed }
        return trimmed.firstMatch(of: /(?:v=|youtu\.be\/|shorts\/|embed\/)([A-Za-z0-9_-]{11})/).map { String($0.1) }
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
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
