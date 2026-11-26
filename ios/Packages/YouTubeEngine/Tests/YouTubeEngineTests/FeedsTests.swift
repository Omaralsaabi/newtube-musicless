import Foundation
import Testing
@testable import YouTubeEngine

/// US-023: the signed-in feeds. A Subscriptions answer can't be recorded without an account, so
/// these build one in BrowseHelper.kt's shape from recorded tiles.
@Suite struct FeedsTests {
    /// Tiles from the recorded channel answer.
    static func tiles(_ count: Int) throws -> [Any] {
        let data = try BrowseParserTests.fixture("channel_blender")
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sections = JSONNode(root)["contents"]["tvBrowseRenderer"]["content"]["tvSurfaceContentRenderer"]["content"]["sectionListRenderer"]["contents"]
        let items = try #require(sections[1]["shelfRenderer"]["content"]["horizontalListRenderer"]["items"].value as? [Any])
        return Array(items.prefix(count))
    }

    static func answer(_ contents: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["contents": ["tvBrowseRenderer": ["content": contents]]])
    }

    @Test func subscriptionsReadTheAllTabsGrid() throws {
        let grid: [String: Any] = ["gridRenderer": ["items": try Self.tiles(4),
                                                    "continuations": [["nextContinuationData": ["continuation": "NEXT"]]]]]
        let channelTab: [String: Any] = ["tabRenderer": ["title": "A channel", "endpoint": ["browseEndpoint": ["browseId": "UCxyz"]],
                                                         "content": ["tvSurfaceContentRenderer": ["content": ["gridRenderer": ["items": try Self.tiles(1)]]]]]]
        let allTab: [String: Any] = ["tabRenderer": ["title": "All", "endpoint": ["browseEndpoint": ["browseId": "FEsubscriptions"]],
                                                     "content": ["tvSurfaceContentRenderer": ["content": grid]]]]
        let data = try Self.answer(["tvSecondaryNavRenderer": ["sections": [["tvSecondaryNavSectionRenderer": ["tabs": [channelTab, allTab]]]]]])
        let page = try FeedParser.feed(data)
        #expect(page.items.count == 4 && page.continuation == "NEXT", "the FEsubscriptions tab, not the first one")
    }

    @Test func homeReadsShelvesAndRowsAndSignedOutIsEmpty() throws {
        let shelves: [String: Any] = ["sectionListRenderer": ["contents": [
            ["shelfRenderer": ["content": ["horizontalListRenderer": ["items": try Self.tiles(3),
                                                                      "continuations": [["nextContinuationData": ["continuation": "SHELF"]]]]]]],
            ["itemSectionRenderer": ["contents": try Self.tiles(2)]],
        ]]]
        let page = try FeedParser.feed(try Self.answer(["tvSurfaceContentRenderer": ["content": shelves]]))
        #expect(page.items.count == 5 && page.continuation == "SHELF")
        let signedOut = try FeedParser.feed(try BrowseParserTests.fixture("home_signed_out"))
        #expect(signedOut.items.isEmpty && signedOut.continuation == nil)
    }
}
