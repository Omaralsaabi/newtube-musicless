import MediaPipeline
import MusiclessCore
import SwiftUI
import YouTubeEngine

/// Phase 0 placeholder: the app's name, its version and commit, and the debug screens.
struct RootView: View {
    @Environment(ModelStore.self) private var models
    @State private var path: [Route] = []

    enum Route: Hashable {
        case probe
        /// autoStart: true = locked run, false = foreground run, nil = wait for a tap.
        case benchmark(autoStart: Bool?)
    }

    var body: some View {
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
                    ModelStatusRow()
                }
            }
            .navigationTitle("Musicless")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .probe: DeviceProbeView()
                case .benchmark(let autoStart):
                    BenchmarkView(benchmark: SeparationBenchmark(models: models), autoStart: autoStart)
                }
            }
        }
        .onAppear {
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
            AppLog.musicless.info("Model status \(models.status.logValue)")
            // `--download-models` starts the voice-model download at launch (no auto-start yet: D25).
            if ProcessInfo.processInfo.arguments.contains("--download-models") { models.start() }
        }
        .onChange(of: models.status) { _, status in
            AppLog.musicless.info("Model status \(status.logValue)")
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
