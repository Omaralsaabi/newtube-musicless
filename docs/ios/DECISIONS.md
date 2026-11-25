# iOS decisions

Every decision taken while building the iOS app, with its evidence. Numbering continues from the
PRD's §3 (D1–D10). When iOS deliberately behaves differently from the Android app, it is recorded
here too (`ios/CLAUDE.md`). Settled `[verify]` items from the PRD are at the end.

## Baseline

- Branch `ios/poc`, cut from `musicless` at `7ed92917`: the fork's tip, two commits past the
  `d074c0c6` the PRD was written from (`616e43d5`, `7ed92917`, small local-files follow-ups in
  `localmedia/` and `MobileBrowseActivity`). Neither touches Musicless code.
- Submodules initialised: `MediaServiceCore` at `52fecea0`, `SharedModules` at `25213805`.
- Toolchain (checked 2026-11-25): Xcode 26.4 (17E192), Swift 6.3, XcodeGen 2.46.0, Python 3.11.14,
  JDK 17.0.18. Matches PRD Appendix A.

## Phase 0

### D11. Minimum iOS 17.0 (closes Q7) — US-001

As D9 says. Nothing in Phase 0 needs more; the iOS 26 APIs the probe calls are behind `#available`
(`BGTaskScheduler.supportedResources` 26.0, `VTRegisterSupplementalVideoDecoderIfAvailable` 26.2).
**Evidence:** the app builds with deployment target 17.0 and runs on iOS 26.6.2 and the 26.4
simulator.

### D12. Where settings live: identity in xcconfig, structure in project.yml — US-001

- `Config/Base.xcconfig` (attached to the app target) holds the identity: `BUNDLE_ID_PREFIX`,
  `DEVELOPMENT_TEAM`, `PAID_TEAM`, `PRODUCT_BUNDLE_IDENTIFIER = $(BUNDLE_ID_PREFIX).musicless`,
  versions. It includes `Paid.xcconfig`, then the optional `Local.xcconfig` (`#include?`) last.
- `project.yml` holds the structure: `SWIFT_VERSION 6.0`, `SWIFT_STRICT_CONCURRENCY complete`,
  `TARGETED_DEVICE_FAMILY 1` (iPhone only), no Catalyst / Designed-for-iPhone on Mac or Vision.
- **Why:** XcodeGen writes its presets (for example `TARGETED_DEVICE_FAMILY "1,2"`) as target
  settings, which outrank a target's xcconfig. Settings that must win go in project.yml.
- **Evidence:** `xcodebuild -showBuildSettings` resolves `PRODUCT_BUNDLE_IDENTIFIER`,
  `DEVELOPMENT_TEAM`, `TARGETED_DEVICE_FAMILY = 1`, `SWIFT_VERSION = 6.0`,
  `SWIFT_STRICT_CONCURRENCY = complete`, `IPHONEOS_DEPLOYMENT_TARGET = 17.0`.
- App target `Musicless` → `Musicless.app` (the PRD §11 paths), display name "NewTube Musicless".
  The home screen truncates it ("NewTube Musi…"); kept as US-001 says.
- `App/Info.plist` is a committed, hand-written file. Not XcodeGen's `info:` (it rewrites the file
  on every generate) and not `GENERATE_INFOPLIST_FILE` (it can't carry custom keys such as
  `GitCommit` now, `UIBackgroundModes` and `MusiclessModelBaseURL` later).

### D13. Commit stamp: a post-build phase edits the processed Info.plist — US-001

- The "Stamp git commit" phase writes `git rev-parse --short HEAD` into the built Info.plist as
  `GitCommit`, with `-dirty` when `git status --porcelain -- ios/` is not empty, and `unknown` without
  git (a zip download). The placeholder screen and the probe show it.
- Its input file is `$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)`. **Evidence:** without it, the parallel
  build ran the phase before `ProcessInfoPlistFile`, which then overwrote the value: the app showed
  `commit=unknown`. With the input, the log orders `ProcessInfoPlistFile` (line 67) before the phase
  (line 134) and the app shows `7ed92917-dirty`.
- `ENABLE_USER_SCRIPT_SANDBOXING = NO` on the app target: the phase reads `.git` and edits the
  processed plist, both outside what a sandboxed phase may touch.
- "Based on dependency analysis" is off, so it runs every build. Xcode prints a *note* about it, not
  a warning (the result bundle counts 0 warnings).

### D14. The paid switch picks files by variable name — US-001

xcconfig has no conditionals, so `Paid.xcconfig` sets
`CODE_SIGN_ENTITLEMENTS = $(MUSICLESS_ENTITLEMENTS_$(PAID_TEAM))`, with `_NO` →
`App/Musicless.entitlements` and `_YES` → `App/MusiclessPaid.entitlements`. Both are empty in
Phase 0; Phase 1 adds the memory entitlements to the paid file. **Evidence:** with `PAID_TEAM = YES`,
`-showBuildSettings` gives `CODE_SIGN_ENTITLEMENTS = App/MusiclessPaid.entitlements`; the device build
signs with the paid team's wildcard profile ("iOS Team Provisioning Profile: *"), as expected with
no capability.

### D15. Free Personal Team test deferred to the first paid-only capability (Q8) — US-001

Phase 0 has no capability, so building with a free team now proves nothing. The test belongs with
the first paid-only entitlement (Increased Memory Limit, US-005/US-006). It also costs something:
a Personal Team can register only a few App IDs a week, and it needs a bundle id of its own (bundle
ids are global and the paid team now holds this one). Ask the developer before running it.

### D16. Packages: tools 6.0, Swift Testing, placeholder modules — US-001

- `swift-tools-version: 6.0`: Swift 6 language mode, so complete strict concurrency without flags.
  Platforms iOS 17 and macOS 14 (PRD §4.8).
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`). `swift test` and Xcode run them.
- Each package's placeholder is `public enum <Name>Module { static let name }` with one test. The app
  imports all three and shows their names, so the wiring is exercised from the first build.
- The scheme's test action lists the three package test targets.

### D17. Logging: one helper, Android's line formats, stdout mirror in Debug — US-002

- `AppLog` channels `Musicless`, `NetPath`, `Player` (PRD §11) plus `Probe`, all with subsystem =
  bundle id. Messages keep Android's text (`Window pipeline …`, `hold reason=…`) when those arrive.
- Debug builds mirror every line to stdout as `[<category>] <message>` through
  `FileHandle.standardOutput` (an unbuffered `write`). **Why:** OSLog never reaches
  `devicectl … --console`; `print` is buffered when the console isn't a terminal; and Swift 6
  rejects touching the C `stdout` global. **Evidence:** the device console shows the `[Probe]` lines.
- It lives in the app for now. When a package first logs (US-003/US-005), decide whether each
  package gets its own `Logger` or a small shared module.

### D18. `--run-probe` opens the probe at launch — US-002

So the report can be captured from the Mac with `devicectl … --console`, without touching the
phone. Used for `DEVICE-PROBE.md`.

### D19. Probe contents beyond the acceptance list — US-002

Added because later stories need them: `phys_footprint` (what jetsam compares with the limit, for
the 700 MB budget), CPU cores, Metal GPU, screen pixels and refresh rate, the probe's own duration,
and a "bare session" test that opens any decoder for a format description without codec
configuration. That test tells a software decoder from none, which `VTIsHardwareDecodeSupported`
can't (`-8971` = a decoder exists and wants its config atom; `-12906` = none).

The audio session is read inactive, then active with `.playback` / `.moviePlayback` and
`.mixWithOthers`, so probing doesn't stop whatever else is playing; it is deactivated with
`.notifyOthersOnDeactivation`.

### D20. App icon and accent colour from the Android fork's icon — US-001

- `ios/tools/render_app_icon.swift` draws `smarttubetv/src/musicless/res/drawable/ic_launcher_*.xml`
  (the emerald background, the white arch, the gold voice bars) to a 1024 px opaque PNG. It maps the
  middle 72 of the vector's 108 units (what Android launchers show) to the full icon.
- **Why now:** an icon set without an image makes actool warn, and the definition of done says zero
  warnings. The PRD's §8 asks for this conversion anyway.
- Accent: `#0E6B52` (the icon's emerald) in light, `#2EC48F` in dark, where `#0E6B52` is too dark
  to read. Placeholder until the UI phase. The app forces dark appearance (§8, "dark theme first").

### D21. A dedicated simulator — US-001

"Musicless iPhone 13 mini" (iOS 26.4), created with `simctl create`: the same screen as the test
phone. The Mac's only other simulator belongs to another project. Its id is local and not committed.

### D22. Device ids and tool quirks — US-001

- `devicectl` takes the CoreDevice identifier, `xcodebuild` the hardware UDID (PRD §11). Both live in
  the shell (`$DEVICE_ID`, `$IOS_UDID`), never in committed files.
- `xcrun xctrace list devices` lists the phone under "Devices Offline" while `devicectl` reports it
  "available (paired)" and `xcodebuild` builds and installs to it. Use
  `xcodebuild -showdestinations` to check a destination, not xctrace's state.
- Every `devicectl` command prints "Failed to load provisioning paramter list … No provider was
  found." It is harmless.

## Settled `[verify]` items

| PRD item | Result | Evidence |
|---|---|---|
| §9: Xcode 26.4 vs iOS 26.6.2 on the device | **Works.** No Xcode update needed | `xcodebuild` built for the pinned phone, `devicectl` installed and launched it, the console showed the app's log (2026-11-25) |
| §0.3 row 9: engine paths "after the submodule init" | Present, with corrections: `QueryBuilder` and `AppClient` are Kotlin, at `youtubeapi/…/common/helpers/QueryBuilder.kt` and `AppClient.kt`; `app/` has `AppService*` (visitor) and `PoTokenGate.kt`; `videoinfo/V2/VideoInfoService.java` and `videoinfo/V2/sources/PhoneSourcePlanner.java` as stated. The search, browse, next and sign-in services are located when their stories start | `ls`/`find` in `MediaServiceCore/youtubeapi/src/main/java/com/liskovsoft/youtubeapi` |
| §4.4: where the EJS solver bundle lives | `MediaServiceCore/youtubeapi/src/main/assets/nsigsolver/`: `yt.solver.core.js`, `meriyah-6.1.4.min.js`, `astring-1.9.0.min.js`, `polyfill.js`, `newtube.memo.js`; run by `app/nsigsolver/impl/V8ChallengeProvider.kt` | `find` |
| §4.6: the background GPU resource on the A15 | **Not available**: `BGTaskScheduler.supportedResources` = 0. The `continued-processing.gpu` entitlement buys nothing on this phone; background separation stays CPU + Neural Engine (§4.5 already plans `.cpuAndNeuralEngine`). Measured without the entitlement and the `processing` mode; recheck once in Phase 5 | `DEVICE-PROBE.md` |
| §0.3 row 10: string counts | Confirmed: `strings_mobile.xml` 373 en / 356 ar (plus 1 plural each). `strings_settings.xml`, which the PRD didn't count: 257 en / 255 ar | `grep -c '<string '` |
