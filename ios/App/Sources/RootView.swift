import MediaPipeline
import MusiclessCore
import SwiftUI
import YouTubeEngine

/// Phase 0 placeholder: the app's name, its version and commit, and the debug screens.
struct RootView: View {
    @State private var path: [Route] = []

    enum Route: Hashable {
        case probe
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
                }
            }
            .navigationTitle("Musicless")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .probe: DeviceProbeView()
                }
            }
        }
        .onAppear {
            AppLog.probe.info("launch version=\(BuildInfo.version) build=\(BuildInfo.build) commit=\(BuildInfo.commit)")
            // `--run-probe` opens the probe at launch, so it can be captured without touching the phone:
            // xcrun devicectl device process launch --device "$DEVICE_ID" --console <bundle id> --run-probe
            if ProcessInfo.processInfo.arguments.contains("--run-probe"), path.isEmpty {
                path = [.probe]
            }
        }
    }
}
