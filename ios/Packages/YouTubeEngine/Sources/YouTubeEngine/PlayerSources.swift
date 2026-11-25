import Foundation

/// WEB_EMBED's identity: the embed page's `encryptedHostFlags` and the visitor that page was served
/// to. YouTube binds the two: flags with any other visitor (or none) are answered "Error code:
/// 152-18" on every video. The pair isn't bound to the video, so it is cached 6 h (MediaServiceCore
/// `YtCfgService.getEmbedIdentity`, `EMBED_IDENTITY_TTL_MS`).
public struct EmbedIdentity: Sendable, Codable, Equatable {
    public var encryptedHostFlags: String
    public var visitorData: String
    public var fetchedAt: Date
}

public actor EmbedIdentityStore {
    public static let ttl: TimeInterval = 6 * 3_600
    private let transport: InnerTubeTransport
    private let storeURL: URL?
    private let log: @Sendable (String) -> Void
    private var cached: EmbedIdentity?

    public init(transport: InnerTubeTransport, storeURL: URL?, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.transport = transport
        self.storeURL = storeURL
        self.log = log
        cached = storeURL.flatMap { try? JSONDecoder().decode(EmbedIdentity.self, from: Data(contentsOf: $0)) }
    }

    /// The cached pair while fresh; otherwise the embed page of `videoID` (any video serves).
    public func identity(videoID: String) async -> EmbedIdentity? {
        if let cached, Date().timeIntervalSince(cached.fetchedAt) < Self.ttl { return cached }
        let start = ContinuousClock.now
        guard let page = try? await transport.send(Self.pageRequest(videoID: videoID), label: "embed-page"),
              let html = String(data: page.data, encoding: .utf8),
              let identity = Self.parse(html) else {
            log("embed-identity failed video=\(videoID)")
            return nil
        }
        cached = identity
        if let storeURL {
            try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(identity).write(to: storeURL, options: .atomic)
        }
        log("embed-identity source=fetched ms=\(Int((ContinuousClock.now - start) / .milliseconds(1))) "
            + "visitor=\(identity.visitorData.prefix(10))")
        return identity
    }

    /// A refused embed answer (152) may mean a stale pair: the next WEB_EMBED request fetches a page.
    public func invalidate() {
        cached = nil
        if let storeURL { try? FileManager.default.removeItem(at: storeURL) }
    }

    /// `GET https://www.youtube.com/embed/<id>?html5=1` with WEB_EMBED's Safari user agent and a
    /// reddit Referer (`YtCfgApi`, `AppClient.getRefererUrl`).
    static func pageRequest(videoID: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/embed/\(videoID)?html5=1")!, timeoutInterval: 8)
        request.setValue(ClientProfile.webEmbed.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.reddit.com/", forHTTPHeaderField: "Referer")
        return request
    }

    /// The first `ytcfg.set({…});` of the page (`YtCfgResult`'s regex), then the flags and the visitor.
    static func parse(_ html: String) -> EmbedIdentity? {
        guard let match = html.firstMatch(of: /ytcfg\.set\(\s*(\{[\s\S]*?\})\s*\);/),
              let object = try? JSONSerialization.jsonObject(with: Data(match.1.utf8)) as? [String: Any] else { return nil }
        let flags = ((object["WEB_PLAYER_CONTEXT_CONFIGS"] as? [String: Any])?["WEB_PLAYER_CONTEXT_CONFIG_ID_EMBEDDED_PLAYER"]
            as? [String: Any])?["encryptedHostFlags"] as? String
        let visitor = object["VISITOR_DATA"] as? String
            ?? (((object["INNERTUBE_CONTEXT"] as? [String: Any])?["client"] as? [String: Any])?["visitorData"] as? String)
        guard let flags, !flags.isEmpty, let visitor, !visitor.isEmpty else { return nil }
        return EmbedIdentity(encryptedHostFlags: flags, visitorData: visitor, fetchedAt: Date())
    }
}

/// The walk's requests (US-015): one `/player` per source, the body QueryBuilder would build for
/// it, on its identity (the youtube.com/tv visitor; WEB_EMBED its embed page's), within the
/// attempt's budget. ANDROID_REEL goes to `reel/reel_item_watch`, whose answer wraps the player
/// response in `playerResponse`.
public struct PlayerSources: Sendable {
    public let transport: InnerTubeTransport
    public let visitor: VisitorIdentity
    public let embed: EmbedIdentityStore
    public var locale: RequestLocale
    private let log: @Sendable (String) -> Void

    public init(transport: InnerTubeTransport, visitor: VisitorIdentity, embed: EmbedIdentityStore,
                locale: RequestLocale = .current, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.transport = transport
        self.visitor = visitor
        self.embed = embed
        self.locale = locale
        self.log = log
    }

    public static let reelURL = URL(string: "https://youtubei.googleapis.com/youtubei/v1/reel/reel_item_watch")!

    /// One attempt, bounded by `budget` end to end (a source that hangs is a no-response).
    public func attempt(_ client: ClientProfile, videoID: String, budget: Duration) async -> WalkAttempt {
        await withTaskGroup(of: WalkAttempt?.self) { group in
            group.addTask { await self.request(client, videoID: videoID) }
            group.addTask {
                try? await Task.sleep(for: budget)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            guard let first else {
                log("player-ring attempt-timeout client=\(client.id) video=\(videoID) ms=\(Int(budget / .milliseconds(1)))")
                return .noResponse
            }
            return first
        }
    }

    private func request(_ client: ClientProfile, videoID: String) async -> WalkAttempt {
        var visitorData: String?
        var flags: String?
        if client.isEmbedded {
            guard let identity = await embed.identity(videoID: videoID) else { return .failed("no embed identity") }
            visitorData = identity.visitorData
            flags = identity.encryptedHostFlags
        } else {
            guard let state = try? await visitor.current() else { return .noResponse }
            visitorData = state.visitorData
        }
        let body = PlayerRequestBody(client: client, videoID: videoID, cpn: PlayerRequestBody.makeCPN(),
                                     visitorData: visitorData, signatureTimestamp: await visitor.signatureTimestamp(),
                                     acceptLanguage: locale.language, acceptRegion: locale.region,
                                     utcOffsetMinutes: locale.utcOffsetMinutes, encryptedHostFlags: flags)
        var request = InnerTubeTransport.playerRequest(body)
        if client == .androidReel {
            request.url = Self.reelURL
            request.setValue(nil, forHTTPHeaderField: "Origin")  // VideoInfoApi.getVideoInfoReel sends none
        }
        do {
            let response = try await transport.send(request, label: client.id)
            guard response.status == 200 else { return .failed("HTTP \(response.status)") }
            var data = response.data
            if client == .androidReel {
                guard let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let player = wrapper["playerResponse"],
                      let unwrapped = try? JSONSerialization.data(withJSONObject: player) else { return .failed("no playerResponse") }
                data = unwrapped
            }
            let answer = try PlayerAnswer(json: data)
            if client.isEmbedded, answer.playability.text?.contains("152") == true { await embed.invalidate() }
            return .answer(answer)
        } catch let error as URLError where [.timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
                                             .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed].contains(error.code) {
            return .noResponse
        } catch is CancellationError {
            return .noResponse
        } catch {
            return .failed("\(error)")
        }
    }
}
