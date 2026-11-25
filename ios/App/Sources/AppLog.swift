import Foundation
import OSLog

/// OSLog with subsystem = bundle id (PRD §11). Debug builds mirror every line to stdout, so
/// `xcrun devicectl device process launch --console` shows it; OSLog alone never reaches that console.
enum AppLog {
    static let musicless = Channel("Musicless")
    static let netPath = Channel("NetPath")
    static let player = Channel("Player")
    static let probe = Channel("Probe")

    struct Channel: Sendable {
        let category: String
        private let logger: Logger

        init(_ category: String) {
            self.category = category
            logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "musicless", category: category)
        }

        func info(_ message: String) {
            logger.info("\(message, privacy: .public)")
            #if DEBUG
            // FileHandle writes straight to fd 1: stdout's C buffer would hold lines back when the
            // console is not a terminal, and Swift 6 rejects touching the `stdout` global anyway.
            FileHandle.standardOutput.write(Data("[\(category)] \(message)\n".utf8))
            #endif
        }
    }
}
