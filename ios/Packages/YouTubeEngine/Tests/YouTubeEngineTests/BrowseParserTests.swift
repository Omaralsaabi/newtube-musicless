import Foundation
import Testing
@testable import YouTubeEngine

/// US-019: the TV client's search request and its answers (Fixtures/browse, recorded 2026-11-26).
@Suite struct BrowseParserTests {
    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/browse"))
        return try Data(contentsOf: url)
    }

    @Test func aSearchPageReadsTheLockupCards() throws {
        let page = try FeedParser.page(try Self.fixture("search_bbb"))
        #expect(page.items.count == 20)
        #expect(page.continuation?.isEmpty == false)
        let first = try #require(page.items.first)
        #expect(first.kind == .video && first.id == "aqz-KE-bpKQ")
        #expect(first.title == "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film")
        #expect(first.channel == "Blender" && first.channelID == "UCSMOQeBJ2RAnuFungnQOxLg", "the long-press menu's Go to channel")
        #expect(first.duration == "10:35")
        #expect(first.details == ["23M views", "12 years ago"])
        #expect(first.badges.contains("4K"))
        #expect(first.thumbnail?.scheme == "https" && first.thumbnail?.host == "i.ytimg.com")
        #expect(page.items.allSatisfy { $0.isPlayable && !$0.title.isEmpty && $0.thumbnail != nil })
    }

    @Test func aContinuationPageKeepsItsShortsMarkedAndItsNextToken() throws {
        let page = try FeedParser.page(try Self.fixture("search_bbb_continuation"))
        #expect(page.items.count == 20)
        #expect(page.items.filter { $0.kind == .short }.count == 9, "a Short says so by its content type or reel tap")
        #expect(page.items.filter { $0.kind == .short }.allSatisfy { $0.duration == nil })
        #expect(page.continuation != nil)
    }

    @Test func channelsAndShelvesAndTheClusterAreReadAsAndroidDoes() throws {
        let page = try FeedParser.page(try Self.fixture("search_channel_shorts_cluster"))
        // The results shelf (20) and the Shorts shelf (20); the clusterShelfRenderer is no section.
        #expect(page.items.count == 40)
        let channel = try #require(page.items.first)
        #expect(channel.kind == .channel && channel.id == "UCX6OQ3DkcsbYNE6H8uQQuVA" && channel.title == "MrBeast")
        #expect(channel.channel == "@MrBeast" && channel.details == ["528M subscribers"])
        #expect(channel.thumbnail?.absoluteString.hasPrefix("https://yt3.ggpht.com/") == true, "protocol-relative avatars get https")
        #expect(page.items.filter { $0.kind == .channel }.count == 2)
        #expect(page.items.filter { $0.kind == .short }.count == 25)
        #expect(page.continuation != nil, "the results shelf continues; the Shorts shelf doesn't")
    }

    @Test func watchNextReadsTheMetadataTheDescriptionAndTheRelatedTiles() throws {
        let next = try FeedParser.watchNext(try Self.fixture("next_bbb"), videoID: "aqz-KE-bpKQ")
        #expect(next.title == "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film")
        #expect(next.channel == "Blender" && next.channelID == "UCSMOQeBJ2RAnuFungnQOxLg")
        #expect(next.subscribers == "1.26M subscribers")
        #expect(next.channelAvatar?.host == "yt3.ggpht.com")
        #expect(next.views == "23,592,420 views" && next.shortViews == "23M views")
        #expect(next.published == "Published on Nov 10, 2014" && next.age == "12y ago")
        #expect(next.likes == "110K")
        #expect(next.description?.hasPrefix("UHD High Frame rate version of the iconic short film by Blender") == true,
                "the description panel: the TV metadata renderer has none")
        #expect(next.commentCount == "5.2K" && next.commentsToken?.isEmpty == false)
        // The pivot: 10 grid shelves of 3 tiles, continued by the list.
        #expect(next.related.items.count == 30)
        #expect(next.related.continuation != nil)
        let first = try #require(next.related.items.first)
        #expect(first.kind == .video && first.id == "vE57fPUAQh0" && first.title == "The Good Dinosaur -  Best Scenes")
        #expect(first.channel == "Hinl" && first.duration == "23:57" && first.details == ["19M views", "9 years ago"],
                "tile lines: the channel, then views and age without the bullet")
        let more = try FeedParser.page(try Self.fixture("next_bbb_continuation"))
        #expect(more.items.count >= 30 && more.continuation == nil)
    }

    @Test func anAnswerWithoutSectionsIsAnError() {
        #expect(throws: BrowseError.self) { try FeedParser.page(Data(#"{"estimatedResults":"0"}"#.utf8)) }
        #expect(throws: BrowseError.self) { try FeedParser.page(Data("<html>".utf8)) }
    }

    @Test func theRequestIsTheTVClientsBrowseShape() throws {
        let locale = RequestLocale(language: "ar-SA", region: "SA", utcOffsetMinutes: 180)
        let request = BrowseClient.request("search", fields: ["query": "big \"buck\" bunny"], visitorData: "visitor-x", locale: locale)
        #expect(request.url?.absoluteString == "https://www.youtube.com/youtubei/v1/search?prettyPrint=false")
        #expect(request.value(forHTTPHeaderField: "X-Youtube-Client-Name") == "7")
        #expect(request.value(forHTTPHeaderField: "X-Youtube-Client-Version") == "7.20260707.07.00")
        #expect(request.value(forHTTPHeaderField: "X-Goog-Visitor-Id") == "visitor-x")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Cobalt") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil, "signed-out browse carries no account")
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["query"] as? String == "big \"buck\" bunny", "quotes survive (JSON, not the Java string format)")
        let client = JSONNode(body)["context"]["client"]
        #expect(client["clientName"].string == "TVHTML5" && client["visitorData"].string == "visitor-x")
        #expect(client["tvAppInfo"]["appQuality"].string == "TV_APP_QUALITY_FULL_ANIMATION")
        #expect(client["acceptLanguage"].string == "ar-SA" && client["acceptRegion"].string == "SA" && client["utcOffsetMinutes"].string == "180")
        #expect(body["racyCheckOk"] as? Bool == true && body["contentCheckOk"] as? Bool == true)
    }
}
