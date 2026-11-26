# Browse fixtures

`/youtubei/v1/search` answers for the TV client (TVHTML5 7.x, AppClient.TV), recorded from the Mac
on 2026-11-26 with no visitor and no cookie, then scrubbed: `responseContext`, tracking and logging
fields, `visitorData` and the onesie `initplayback` URLs are removed (they carry googlevideo node
names). `BrowseParserTests` reads them; `fixturesCarryNoAddressOrVisitor` re-checks them.

- `search_bbb.json`: "big buck bunny", one results shelf of 20 videos with a continuation.
- `search_bbb_continuation.json`: that continuation's answer (`continuationContents.sectionListContinuation`).
- `search_channel_shorts_cluster.json`: "mrbeast": results with channel lockups, a Shorts shelf and
  a `clusterShelfRenderer` (Android drops the cluster: only shelves become sections).
