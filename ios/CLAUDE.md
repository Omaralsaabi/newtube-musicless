# NewTube Musicless for iPhone — Claude Code context

The native iOS app (Swift 6, SwiftUI) under `ios/`. The plan is **`docs/ios/PRD.md`** (read it
first; its §3 decisions are fixed, ask before deviating). Decisions taken since, with evidence:
**`docs/ios/DECISIONS.md`**; add every new one there. Device measurements:
`docs/ios/DEVICE-PROBE.md`; benchmarks: `docs/ios/BENCHMARKS.md`.

None of the Android code runs here. The Android app is the reference: port behaviour by reading
`smarttubetv/src/stmobile/…` and `MediaServiceCore`, never change them.

## Rules (PRD §0.4)

**Carried over from the root `CLAUDE.md`; still true on iOS:**
- **A googlevideo 403 is routine.** Recover by asking the next client for the same itags (PRD
  §4.4). Never retry the same URL.
- **Byte ranges go in a `Range:` header,** never a `&range=` query parameter. See the
  416/cache-poisoning post-mortem in `docs/mobile-port/HANDOFF.md`.
- **Single-slot caches evict themselves.** Walk the eviction timeline before adding "remember one
  thing" logic.
- **InnerTube must run over HTTP/2.** URLSession negotiates it on its own, but log
  `URLSessionTaskMetrics` → `networkProtocolName` on every API request (the iOS counterpart of
  NetPath's `protocol=h2`) and check it.
- **Never edit `VIDEO_INFO_TYPE_LIST`** or other Android engine code. The iOS app ports logic; it
  doesn't change the source.

**New for iOS:**
- **Always pin the device:** `--device "$DEVICE_ID"` for `devicectl`,
  `-destination "platform=iOS,id=$IOS_UDID"` for `xcodebuild`. The counterpart of the `adb -s` rule.
- **Never commit device names, UDIDs, Team IDs, OAuth tokens or visitor ids.** They live in
  `ios/Config/Local.xcconfig` (gitignored), shell variables, or nowhere. Logs truncate visitor ids to
  10 characters, as Android does. Before committing, grep the diff for them.
- **Separation speed is only measured on the iPhone.** The simulator runs on the Mac's CPU and
  proves nothing about it.
- **Keep the Android log formats** (`Window pipeline …`, `hold reason=…`) so the same tools read both
  platforms' logs.
- **The Android app is the reference.** When iOS behaves differently on purpose, say so in
  `docs/ios/DECISIONS.md`.

## Definition of done (every story, PRD §5)

- Zero warnings in Swift 6 language mode with complete strict concurrency. Check the result bundle,
  not a log grep: `xcrun xcresulttool get build-results --path <bundle>` → `warningCount: 0`.
- `swift test` passes for every touched package.
- The app installs and launches on the pinned iPhone.
- No file changes outside `ios/`, `docs/ios/`, `tasks/` and `.gitignore` (plus the one pointer line in
  the root `CLAUDE.md`).
- UI stories: simulator screenshots, and a check on the phone in English and Arabic (RTL).

## Commands

```sh
# Ids, once per shell (never in committed files)
xcrun devicectl list devices                                       # CoreDevice id -> DEVICE_ID
xcodebuild -showdestinations -project ios/Musicless.xcodeproj -scheme Musicless   # UDID -> IOS_UDID
# (xctrace may list the phone as "Offline" while it works; trust -showdestinations.)

(cd ios && ./bootstrap.sh)                                         # after pulling or editing project.yml
swift test --package-path ios/Packages/MusiclessCore               # also YouTubeEngine, MediaPipeline

# Simulator: the dedicated "Musicless iPhone 13 mini" (simctl list devices available)
xcodebuild -project ios/Musicless.xcodeproj -scheme Musicless \
  -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath ios/build \
  -resultBundlePath ios/build/results/sim-$(date +%H%M%S).xcresult build

# iPhone
xcodebuild -project ios/Musicless.xcodeproj -scheme Musicless \
  -destination "platform=iOS,id=$IOS_UDID" -derivedDataPath ios/build -allowProvisioningUpdates \
  -resultBundlePath ios/build/results/device-$(date +%H%M%S).xcresult build
xcrun devicectl device install app --device "$DEVICE_ID" ios/build/Build/Products/Debug-iphoneos/Musicless.app
xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing --console "$BUNDLE_ID"
#   add --run-probe to open the device probe at launch and print its report
```

- Debug builds mirror every log line to stdout as `[<category>] …`, which is what `--console`
  shows; OSLog alone never reaches it. Categories: `Musicless`, `NetPath`, `Player`, `Probe`.
- `xcodebuild` refuses an existing `-resultBundlePath`; use a fresh name rather than deleting.
- Every `devicectl` call prints "Failed to load provisioning paramter list … No provider was
  found." — harmless.

## Layout

`project.yml` (XcodeGen; the `.xcodeproj` is generated and gitignored), `Config/` (Base, Paid, Local
xcconfigs), `App/` (the SwiftUI app; `Sources/Debug/` holds the debug screens), `Packages/`
(`MusiclessCore`, `YouTubeEngine`, `MediaPipeline`: build for iOS 17 and macOS 14, tests in Swift
Testing), `tools/`. Identity settings go in xcconfig, structural ones in project.yml (DECISIONS D12).
