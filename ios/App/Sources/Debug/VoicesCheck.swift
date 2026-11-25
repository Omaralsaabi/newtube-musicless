import Foundation
import MediaPipeline
import MusiclessCore
import Observation
import SwiftUI

/// US-012's audio-only proof: a YouTube video's audio with only the voices, screen lock included.
/// A debug screen for the ear test; US-014's watch screen replaces it.
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
    private(set) var snapshot: VoicePlayer.Snapshot?
    private(set) var error: String?
    private(set) var resolving = false
    var removeMusic = true

    @ObservationIgnored private let models: ModelStore
    @ObservationIgnored private var player: VoicePlayer?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var tapAt: ContinuousClock.Instant?
    @ObservationIgnored private var playerMs = 0
    @ObservationIgnored private var generation = 0

    init(models: ModelStore) {
        self.models = models
        PlaybackAudioSession.shared.onPlayChange = { [weak self] play in
            guard let player = self?.player else { return }
            Task { play ? await player.play() : await player.pause() }
        }
    }

    var statusText: String {
        if let error { return "Failed: \(error)" }
        if resolving { return "Resolving…" }
        guard let snapshot else { return "Pick a video" }
        switch snapshot.status {
        case .idle: return "Stopped"
        case .loading: return "Opening the audio…"
        case .holding: return "Preparing voices…"
        case .playing: return snapshot.removeMusic ? "Playing voices only" : "Playing the original audio"
        case .paused: return "Paused"
        case .ended: return "Ended"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    var isActive: Bool { player != nil }

    func play(_ videoID: String, at seconds: Double = 0) async {
        await stop(reason: "new video")
        generation += 1
        let token = generation
        error = nil
        resolving = true
        title = videoID
        tapAt = .now
        AppLog.player.info("voices tap video=\(videoID) at=\(seconds) removeMusic=\(removeMusic)")
        do {
            let audio = try await VideoResolver.audio(for: videoID)
            guard token == generation else { return }
            title = audio.title
            detail = "\(audio.author) · itag \(audio.source.file.itag)"
            playerMs = audio.playerMs
            try PlaybackAudioSession.shared.activate()
            let runtime = PlaybackServices.shared.runtime(models: models)
            let separator = Separator(backend: runtime, log: { line in
                AppLog.musicless.info(line.hasPrefix("Window pipeline") ? line + " appState=\(AppActivity.logValue)" : line)
            })
            let fetcher = MediaFetcher(file: audio.source.file, log: { AppLog.netPath.info($0) })
            let player = VoicePlayer(
                source: audio.source, fetcher: fetcher, stage: SeparatorStage(separator: separator),
                log: { AppLog.player.info($0 + " appState=\(AppActivity.logValue)") },
                holdLog: { AppLog.musicless.info($0) },
                onChange: { [weak self] snapshot in Task { @MainActor in self?.changed(snapshot) } })
            self.player = player
            resolving = false
            AppLog.player.info("voices resolved video=\(videoID) title=\"\(audio.title)\" mime=\"\(audio.mimeType)\" playerMs=\(audio.playerMs)")
            startPolling()
            await player.start(at: seconds, removeMusic: removeMusic)
        } catch {
            guard token == generation else { return }
            resolving = false
            self.error = "\(error)"
            AppLog.player.info("voices failed video=\(videoID) error=\(error)")
        }
    }

    func togglePlay() async {
        guard let player, let snapshot else { return }
        snapshot.wantsToPlay ? await player.pause() : await player.play()
        self.snapshot = await player.snapshot()
    }

    func skip(_ seconds: Double) async {
        guard let player, let snapshot else { return }
        await player.seek(to: snapshot.position + seconds)
    }

    func setRemoveMusic(_ on: Bool) async {
        removeMusic = on
        await player?.setRemoveMusic(on)
    }

    /// Ends playback; `reason` goes to the log (`voices stop reason=…`).
    func stop(reason: String) async {
        poll?.cancel()
        poll = nil
        if let player {
            AppLog.player.info("voices stop reason=\(reason) appState=\(AppActivity.logValue)")
            self.player = nil
            await player.close()
            PlaybackAudioSession.shared.deactivate()
        }
        snapshot = nil
    }

    private func changed(_ snapshot: VoicePlayer.Snapshot) {
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
                guard let player = self?.player else { return }
                let snapshot = await player.snapshot()
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
    @State private var custom = ""

    var body: some View {
        List {
            Section {
                ModelStatusRow()
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
                Text("Plays the audio only, with the music removed. Switch Remove music off to hear the "
                     + "original. Lock the screen: the voices should keep playing.")
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
                            Text("\(Self.clock(snapshot.position)) / \(Self.clock(snapshot.duration ?? 0)) · "
                                 + "\(String(format: "%.1f", max(0, snapshot.aheadSeconds))) s queued")
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
        }
        .navigationTitle("Voices only")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let autoPlay { await check.play(autoPlay.id, at: autoPlay.at) }
        }
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
