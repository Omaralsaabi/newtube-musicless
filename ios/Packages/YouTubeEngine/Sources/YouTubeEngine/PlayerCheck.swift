import Foundation

/// The request locale (`LocaleManager` on Android: the BCP-47 tag, the country, the UTC offset).
public struct RequestLocale: Sendable {
    public var language: String
    public var region: String
    public var utcOffsetMinutes: Int

    public static var current: RequestLocale {
        RequestLocale(language: Locale.current.identifier(.bcp47),
                      region: Locale.current.region?.identifier ?? "US",
                      utcOffsetMinutes: TimeZone.current.secondsFromGMT() / 60)
    }
}

/// A few fields of a `/player` answer, enough to tell whether it serves (US-009 parses it fully).
public struct PlayerAnswerSummary: Sendable, Equatable {
    public var status: String
    public var reason: String?
    public var adaptiveFormats = 0
    public var withURL = 0
    public var ciphered = 0
    public var hasSABR = false
    public var hasHLS = false
    /// A plain-URL `audio/mp4` format (itag 140 when present), to probe the media.
    public var audioURL: String?
    /// Format counts by MIME type before the `;` (`video/mp4`, `audio/webm`, …).
    public var mimeCounts: [String: Int] = [:]

    public init(json data: Data) {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let playability = root["playabilityStatus"] as? [String: Any]
        status = playability?["status"] as? String ?? "NO_STATUS"
        reason = playability?["reason"] as? String
        let streaming = root["streamingData"] as? [String: Any]
        hasSABR = streaming?["serverAbrStreamingUrl"] != nil
        hasHLS = streaming?["hlsManifestUrl"] != nil
        let formats = streaming?["adaptiveFormats"] as? [[String: Any]] ?? []
        adaptiveFormats = formats.count
        for format in formats {
            let type = (format["mimeType"] as? String ?? "?").split(separator: ";").first.map(String.init) ?? "?"
            mimeCounts[type, default: 0] += 1
            if let url = format["url"] as? String {
                withURL += 1
                let mime = format["mimeType"] as? String ?? ""
                if mime.hasPrefix("audio/mp4"), audioURL == nil || format["itag"] as? Int == 140 { audioURL = url }
            }
            if format["signatureCipher"] != nil || format["cipher"] != nil { ciphered += 1 }
        }
    }
}

/// US-008's device measurement: does a client serve with the real signature timestamp and with -1?
/// Asks once per video and timestamp, then fetches the first KiB of the audio with a `Range` header.
public enum PlayerCheck {
    public static let ordinaryVideos = ["dQw4w9WgXcQ", "jNQXAC9IVRw", "M7lc1UVf-VE", "aqz-KE-bpKQ", "kJQP7kiw5Fk"]

    public struct Line: Sendable {
        public let videoID: String
        public let signatureTimestamp: Int
        public let summary: PlayerAnswerSummary?
        public let mediaStatus: Int?
        public let mediaProtocol: String?
        public let error: String?

        public var logLine: String {
            var text = "player-check video=\(videoID) sts=\(signatureTimestamp)"
            if let summary {
                text += " status=\(summary.status) formats=\(summary.adaptiveFormats) urls=\(summary.withURL)"
                    + " ciphered=\(summary.ciphered) sabr=\(summary.hasSABR ? "y" : "n") hls=\(summary.hasHLS ? "y" : "n")"
                text += " types=" + summary.mimeCounts.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
                if let reason = summary.reason { text += " reason=\"\(reason)\"" }
            }
            text += " media=\(mediaStatus.map(String.init) ?? "-") mediaProtocol=\(mediaProtocol ?? "-")"
            if let error { text += " error=\"\(error)\"" }
            return text
        }
    }

    public static func run(client: ClientProfile = .visionOS, videoIDs: [String] = ordinaryVideos,
                           transport: InnerTubeTransport, identity: VisitorIdentity, media: URLSession,
                           locale: RequestLocale = .current, log: @Sendable (String) -> Void) async -> [Line] {
        var lines: [Line] = []
        let visitor: VisitorState
        do {
            visitor = try await identity.current()
        } catch {
            log("player-check visitor failed: \(error)")
            return []
        }
        let realTimestamp = await identity.signatureTimestamp()
        // Is googlevideo reachable at all from here? A bare path answers 404 quickly when it is.
        let (redirector, redirectorProtocol) = await probe(URL(string: "https://redirector.googlevideo.com/videoplayback")!,
                                                           session: media, assumeHTTP3: false)
        log("player-check redirector status=\(redirector.map(String.init) ?? "-") protocol=\(redirectorProtocol ?? "-")")
        log("player-check start client=\(client.id) visitor=\(visitor.shortVisitor) sts=\(realTimestamp) "
            + "locale=\(locale.language)/\(locale.region)/\(locale.utcOffsetMinutes)")
        for videoID in videoIDs {
            for timestamp in [realTimestamp, -1] where timestamp == -1 || realTimestamp != -1 {
                let body = PlayerRequestBody(client: client, videoID: videoID, cpn: PlayerRequestBody.makeCPN(),
                                             visitorData: visitor.visitorData, signatureTimestamp: timestamp,
                                             acceptLanguage: locale.language, acceptRegion: locale.region,
                                             utcOffsetMinutes: locale.utcOffsetMinutes)
                var line = Line(videoID: videoID, signatureTimestamp: timestamp, summary: nil,
                                mediaStatus: nil, mediaProtocol: nil, error: nil)
                do {
                    let answer = try await transport.send(InnerTubeTransport.playerRequest(body), label: client.id)
                    let summary = PlayerAnswerSummary(json: answer.data)
                    var status: Int?, protocolName: String?
                    if let audio = summary.audioURL, let url = URL(string: audio) {
                        // Without assuming HTTP/3 first: the first device run timed out with it.
                        (status, protocolName) = await probe(url, session: media, assumeHTTP3: false)
                        log("player-check media-host video=\(videoID) host=\(url.host ?? "?")")
                        if status == nil {
                            // The assigned node didn't answer: try the alternate nodes the URL's `mn`
                            // parameter names (what YouTube's own players fall back to).
                            for host in alternateHosts(for: url) {
                                guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { break }
                                parts.host = host
                                guard let alternate = parts.url else { continue }
                                let (altStatus, altProtocol) = await probe(alternate, session: media, assumeHTTP3: false)
                                log("player-check media-alternate video=\(videoID) host=\(host) "
                                    + "status=\(altStatus.map(String.init) ?? "-") protocol=\(altProtocol ?? "-")")
                                if let altStatus {
                                    status = altStatus
                                    protocolName = "via-\(host) " + (altProtocol ?? "-")
                                    break
                                }
                            }
                        }
                    }
                    line = Line(videoID: videoID, signatureTimestamp: timestamp, summary: summary,
                                mediaStatus: status, mediaProtocol: protocolName, error: nil)
                } catch {
                    line = Line(videoID: videoID, signatureTimestamp: timestamp, summary: nil,
                                mediaStatus: nil, mediaProtocol: nil, error: error.localizedDescription)
                }
                log(line.logLine)
                lines.append(line)
            }
        }
        return lines
    }

    /// Hosts of the other nodes in the URL's `mn` list, keeping the replica prefix (`rr5---`) and
    /// also trying the `fvip` replica (`r<fvip>---`), as a debug probe of host fallback (D38).
    static func alternateHosts(for url: URL) -> [String] {
        guard let host = url.host, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let separator = host.range(of: "---") else { return [] }
        let replica = String(host[..<separator.lowerBound])          // e.g. rr5
        let current = String(host[separator.upperBound...].split(separator: ".").first ?? "")
        let items = parts.queryItems ?? []
        let nodes = (items.first { $0.name == "mn" }?.value ?? "").split(separator: ",").map(String.init)
        let fvip = items.first { $0.name == "fvip" }?.value
        var hosts: [String] = []
        for node in nodes where node != current {
            hosts.append("\(replica)---\(node).googlevideo.com")
            if let fvip { hosts.append("r\(fvip)---\(node).googlevideo.com") }
        }
        return hosts
    }

    /// The first KiB through a `Range` header (never `&range=`: PRD §0.4).
    static func probe(_ url: URL, session: URLSession, assumeHTTP3: Bool) async -> (Int?, String?) {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        request.assumesHTTP3Capable = assumeHTTP3
        let metrics = MetricsCollector()
        do {
            let (_, response) = try await session.data(for: request, delegate: metrics)
            return ((response as? HTTPURLResponse)?.statusCode, metrics.protocolName)
        } catch {
            return (nil, "error \((error as? URLError)?.code.rawValue ?? -1): \(error.localizedDescription)")
        }
    }
}
