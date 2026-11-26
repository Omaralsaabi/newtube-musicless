import MediaPipeline
import MusiclessCore
import SwiftUI
import YouTubeEngine

/// The app's tabs (PRD FR-18): Subscriptions first, Search, You. You holds the debug screens until
/// Settings (US-024) takes them over.
struct RootView: View {
    @Environment(ModelStore.self) private var models
    @State private var tab: Tab = .subscriptions
    @State private var path: [Route] = []
    @State private var searchPath: [BrowseRoute] = []
    @State private var search = SearchModel(browse: PlaybackServices.shared.browse)
    /// The watch screen's player; it outlives the view and stops when its route is popped.
    @State private var watch: PlayerModel?

    enum Tab: Hashable { case subscriptions, search, you }

    enum Route: Hashable {
        case probe
        /// autoStart: true = locked run, false = foreground run, nil = wait for a tap.
        case benchmark(autoStart: Bool?)
        /// US-012; `id` plays at once (from `--voices`).
        case voices(id: String?, at: Double)
    }

    var body: some View {
        TabView(selection: $tab) {
            SubscriptionsPlaceholder()
                .tabItem { Label("Subscriptions", systemImage: "play.square.stack") }
                .tag(Tab.subscriptions)
            SearchView(model: search, path: $searchPath) { AnyView(destination($0, path: $searchPath)) }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)
            you
                .tabItem { Label("You", systemImage: "person.crop.circle") }
                .tag(Tab.you)
        }
        .onAppear(perform: launch)
        .onChange(of: path) { _, _ in stopPlayerIfHidden() }
        .onChange(of: searchPath) { _, _ in stopPlayerIfHidden() }
        .onChange(of: models.status) { _, status in
            AppLog.musicless.info("Model status \(status.logValue)")
        }
    }

    /// A list's tap: the watch page (US-020), the channel and playlist pages (US-021).
    @ViewBuilder private func destination(_ route: BrowseRoute, path: Binding<[BrowseRoute]>) -> some View {
        switch route {
        case .watch(let videoID):
            if let watch { WatchView(videoID: videoID, player: watch, path: path) }
        case .channel(let id, let title):
            ChannelView(id: id, title: title, path: path)
        case .playlist(let id, let title):
            PlaylistView(id: id, title: title, path: path)
        }
    }

    private func stopPlayerIfHidden() {
        let showsVoices = path.contains { if case .voices = $0 { true } else { false } }
        let showsWatch = searchPath.contains { if case .watch = $0 { true } else { false } }
        if !showsVoices, !showsWatch, let watch, watch.isActive { Task { await watch.stop(reason: "left the screen") } }
    }

    private var you: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("NewTube Musicless")
                            .font(.title2.bold())
                        Text(BuildInfo.summary)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Version \(BuildInfo.version), build \(BuildInfo.build), commit \(BuildInfo.commit)")
                        Text([MusiclessCoreModule.name, YouTubeEngineModule.name, MediaPipelineModule.name]
                            .joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
                Section("Debug") {
                    NavigationLink(value: Route.probe) {
                        Label("Device probe", systemImage: "cpu")
                    }
                    NavigationLink(value: Route.benchmark(autoStart: nil)) {
                        Label("Separation benchmark", systemImage: "speedometer")
                    }
                    NavigationLink(value: Route.voices(id: nil, at: 0)) {
                        Label("Watch (debug)", systemImage: "play.rectangle")
                    }
                    ModelStatusRow()
                }
                // Until Settings (US-024) has its own screen.
                Section("Playback") {
                    Toggle(isOn: Binding(get: { AppSettings.shared.showUpNext }, set: { AppSettings.shared.showUpNext = $0 })) {
                        Label("Show Up next", systemImage: "list.bullet.below.rectangle")
                    }
                }
            }
            .navigationTitle("You")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .probe: DeviceProbeView()
                case .benchmark(let autoStart):
                    BenchmarkView(benchmark: SeparationBenchmark(models: models), autoStart: autoStart)
                case .voices(let id, let at):
                    if let watch {
                        let arguments = ProcessInfo.processInfo.arguments
                        WatchDebugView(watch: watch, autoPlay: id.map { ($0, at) },
                                       seekCheck: arguments.contains("--seek-check"),
                                       backgroundTest: arguments.contains("--background-test"),
                                       qualityCheck: arguments.contains("--quality-check"),
                                       wallCheck: arguments.contains("--wall-check"),
                                       systemCheck: arguments.contains("--system-check"))
                    }
                }
            }
        }
    }

    /// Launch flags open their screen (on the You tab) or start their check.
    private func launch() {
        if watch == nil { watch = PlayerModel(models: models) }
        PlaybackServices.shared.warmUp()
        AppLog.probe.info("launch version=\(BuildInfo.version) build=\(BuildInfo.build) commit=\(BuildInfo.commit)")
        // `--run-probe` opens the probe at launch, so it can be captured without touching the phone:
        // xcrun devicectl device process launch --device "$DEVICE_ID" --console <bundle id> --run-probe
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--run-probe"), path.isEmpty {
            path = [.probe]
        }
        // `--benchmark` / `--benchmark-locked` start the US-006 benchmark at launch (add
        // `--console-log` to a Release build to see its lines in `devicectl … --console`).
        if path.isEmpty, arguments.contains("--benchmark") || arguments.contains("--benchmark-locked") {
            path = [.benchmark(autoStart: arguments.contains("--benchmark-locked"))]
        }
        // `--player-check` asks VISIONOS for five ordinary videos with the real and a -1 timestamp (US-008).
        if arguments.contains("--player-check") { Task { await PlayerCheckRunner.run() } }
        if arguments.contains("--resolve-check") { Task { await PlayerCheckRunner.runUS009(record: false) } }
        if arguments.contains("--record-answers") { Task { await PlayerCheckRunner.runUS009(record: true) } }
        if arguments.contains("--fetch-check") { Task { await FetchCheckRunner.run() } }
        // `--sync-check [<id>] [--sync-seconds <s>]`: beep and flash timing of a sync test video (US-013).
        if let index = arguments.firstIndex(of: "--sync-check") {
            let next = arguments.indices.contains(index + 1) ? arguments[index + 1] : ""
            let seconds = arguments.firstIndex(of: "--sync-seconds")
                .flatMap { arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil } ?? 40
            Task { await SyncCheck.run(videoID: next.hasPrefix("--") || next.isEmpty ? nil : next, seconds: seconds) }
        }
        // `--solver-check`: the challenge solver's cold and warm speed on this phone (US-016).
        if arguments.contains("--solver-check") { Task { await SolverCheck.run() } }
        // `--delay-check [<id> …]`: AAC vs Opus delay by cross-correlation (US-013); presets by default.
        if let index = arguments.firstIndex(of: "--delay-check") {
            let ids = arguments[(index + 1)...].prefix { !$0.hasPrefix("--") }
            let seconds = arguments.firstIndex(of: "--sync-seconds")
                .flatMap { arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil } ?? 30
            Task { await SyncCheck.runDelay(videoIDs: ids.isEmpty ? PlayerModel.presets.map(\.id) + SyncCheck.candidates : Array(ids),
                                            seconds: seconds) }
        }
        // `--voices [<id>] [--voices-at <seconds>]` plays a video's voices at launch (US-012).
        if path.isEmpty, arguments.contains("--wall-check") { path = [.voices(id: nil, at: 0)] }
        if path.isEmpty, let index = arguments.firstIndex(of: "--voices") {
            let next = arguments.indices.contains(index + 1) ? arguments[index + 1] : ""
            let id = next.hasPrefix("--") || next.isEmpty ? PlayerModel.presets[0].id : next
            let at = arguments.firstIndex(of: "--voices-at").flatMap { arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil }
            path = [.voices(id: id, at: at ?? 0)]
        }
        if arguments.contains("--record-media") { Task { await MediaRecorder.run() } }
        AppLog.musicless.info("Model status \(models.status.logValue)")
        // `--download-models` starts the voice-model download at launch (no auto-start yet: D25).
        if ProcessInfo.processInfo.arguments.contains("--download-models") { models.start() }
        if path.isEmpty, let index = arguments.firstIndex(of: "--search") {
            // `--search [<query>]`: the Search tab, searching at once (screenshots, phone checks).
            tab = .search
            let next = arguments.indices.contains(index + 1) ? arguments[index + 1] : ""
            if !next.isEmpty, !next.hasPrefix("--") {
                Task {
                    await search.submit(next)
                    // `--search-more`: two more pages, as two scrolls to the end would ask.
                    guard arguments.contains("--search-more") else { return }
                    for _ in 0..<2 { await search.loadMore() }
                    AppLog.netPath.info("browse search-more done kept=\(search.items.count) droppedShorts=\(search.list.droppedShorts) "
                                        + "more=\(search.list.hasMore ? "y" : "n")")
                }
            }
        }
        // `--channel <id>` / `--playlist <id>`: those pages (US-021), on the Search tab's stack.
        for (flag, route) in [("--channel", { BrowseRoute.channel(id: $0, title: "") }),
                              ("--playlist", { BrowseRoute.playlist(id: $0, title: "") })] as [(String, (String) -> BrowseRoute)] {
            if path.isEmpty, let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) {
                tab = .search
                searchPath = [route(arguments[index + 1])]
            }
        }
        // `--watch <id>`: the watch page for a video (US-020), on the Search tab's stack.
        if path.isEmpty, let index = arguments.firstIndex(of: "--watch"), arguments.indices.contains(index + 1) {
            tab = .search
            searchPath = [.watch(videoID: arguments[index + 1])]
        }
        if !path.isEmpty { tab = .you }
    }
}

/// Signed out, Subscriptions asks for sign-in (US-023); until sign-in exists (US-022), it says so.
struct SubscriptionsPlaceholder: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Subscriptions", systemImage: "play.square.stack")
            } description: {
                Text("Sign in to see videos from the channels you follow.")
            }
            .navigationTitle("Subscriptions")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// The voice models' state, with Download or Retry (US-004). Settings take this over in US-024.
struct ModelStatusRow: View {
    @Environment(ModelStore.self) private var models

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice models")
                    Text(models.status.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "waveform")
            }
            Spacer()
            switch models.status {
            case .notDownloaded: Button("Download") { models.start() }
            case .failed: Button("Retry") { models.retry() }
            case .downloading: ProgressView()
            case .ready: EmptyView()
            }
        }
        .accessibilityElement(children: .combine)
    }
}
