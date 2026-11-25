import Foundation
import YouTubeEngine

/// Runs `PlayerCheck` (US-008) from the `--player-check` launch argument; results go to the log.
enum PlayerCheckRunner {
    static func run() async {
        let log: @Sendable (String) -> Void = { AppLog.netPath.info($0) }
        let transport = InnerTubeTransport(log: log)
        let store = URL.applicationSupportDirectory.appending(path: "youtube/visitor.json")
        let identity = VisitorIdentity(transport: transport, storeURL: store, log: log)
        let media = URLSession(configuration: .ephemeral)
        let lines = await PlayerCheck.run(transport: transport, identity: identity, media: media, log: log)
        let served = lines.filter { $0.mediaStatus == 206 }
        log("player-check done answers=\(lines.count) mediaServed=\(served.count) "
            + "minusOneServed=\(served.filter { $0.signatureTimestamp == -1 }.count)/\(lines.filter { $0.signatureTimestamp == -1 }.count)")
    }
}
