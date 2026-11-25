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

## Phase 1

### D23. DSP golden fixtures: integer-generated input, reduced F=512 — US-003

- `ios/tools/dsp-golden/` compiles the **unchanged** `MusiclessDsp.java` with `DspGolden.java` (same
  package) and writes little-endian float32 arrays plus `manifest.json` into MusiclessCore's test
  resources (`run.sh`; JDK 17).
- The input comes from integer arithmetic only (a sine table rounded to int16, phase accumulators,
  xorshift32 noise), so Swift regenerates it **bit for bit**; the manifest's FNV-1a hash of the int16
  stream proves it (the test fails if it ever drifts). The input itself isn't stored.
- F=64: full spectrum, magnitude and synthesis output. F=512: frames {0, 1, 2, 255, 256, 509/510,
  511, 512} and three output ranges, plus sum / sum of squares / max |x| over the full arrays. Full
  F=512 fixtures would be ~20 MB; these total 2.3 MB.
- The synthesis mask is `((c·7 + f·13 + k·31) mod 101) / 100`, exact in float in both languages.
- **Measured** (tolerance = the PRD's): spectrum max error 1.3e-7 of the peak (≤ 1e-3), magnitude
  2.2e-7 of the peak (≤ 1e-3), synthesis output 8.9e-8 absolute (≤ 1e-4), same at F=512. Float32
  vDSP clears the PRD's `[verify]` tolerances by four orders of magnitude.

### D24. The Swift DSP — US-003

- vDSP's packed real FFT (`vDSP_fft_zrip`, log2n 12) in Float32. Its forward output is twice the DFT
  (halved on store); fed true DFT values, its inverse returns the unnormalised IDFT, and Java's
  `/ FFT` is folded into the synthesis window. The Nyquist bin (packed in `imag[0]`) is zero, as
  Java zeroes bins ≥ 1024.
- The gain sums Float squares in Double, as Java does. Interior frames gather and overlap-add with
  strided vDSP calls; only the reflect-padded edge frames use scalar loops.
- `Dsp` owns its scratch (not thread-safe; one per executor); results are arrays (copy-on-write).
  The per-size setup (Hann² weights) is vectorised: it runs for every ramp window, on the path to the
  first voices (debug build, first 512 window: 242 → 46 ms).
- Mac (M4), release: analyze 4.3 ms + synthesize 4.4 ms for F=512, against 96 ms for the Java DSP.

### D25. Model store: streaming download, own gunzip, no auto-start yet — US-004

- Behaviour ported from `MusiclessModels.java`: `Range` resume; a 206 must carry
  `Content-Range: bytes <offset>-`; a 416 on resume means the gzip is complete; a server that
  ignores `Range` (200) restarts the file; 100 MB cap on the download and on each model; SHA-256
  (CryptoKit) streamed with the gunzip; atomic publish as `<sha>-<name>` (`rename(2)`); the partial
  file is deleted on any unpack or hash failure; errors read `Voice model: <message>`.
- The body streams through a per-task `URLSessionDataDelegate` into an `AsyncThrowingStream`, so the
  cap cancels mid-download. Gunzip: Apple's Compression `OutputFilter` (raw DEFLATE) after parsing the
  RFC 1952 header ourselves; the trailer's CRC-32 isn't checked because the SHA-256 covers it.
- Files live in Application Support/musicless, excluded from backup (directory and files; seen as
  the `com_apple_backup_excludeItem` attribute on the simulator).
- `ModelStore` is a main-actor `@Observable` (`notDownloaded`, `downloading(percent)`, `ready`,
  `failed(message)`, `start`/`retry`, `awaitReady`).
- **No download at launch yet.** Android starts it at launch when Remove music is on; here a debug
  row (and `--download-models`) starts it until the Remove-music setting exists (US-014/US-024), so
  a debug build doesn't spend 36 MB of someone's data unasked.
- Verified with the real release: both files gunzip to the pinned hashes (Mac test `liveRelease`,
  and in the app on the simulator).

### D26. `MusiclessModelBaseURL` comes from xcconfig — US-004

`Base.xcconfig` sets `MUSICLESS_MODEL_BASE_URL` (written `https:/$()/…` because xcconfig treats `//`
as a comment); Info.plist reads it. Like Android's `musiclessModelBaseUrl` Gradle property, a builder
can point it elsewhere in `Local.xcconfig`; empty means "not configured".

### D27. ONNX Runtime 1.32.0 from Microsoft's NuGet package — US-005 (developer's decision)

- **Why:** the PRD's `[verify]` URL is dead. `microsoft/onnxruntime-swift-package-manager` and
  `microsoft/onnxruntime` return 404 on GitHub (pulled around 2026-11-17, per several mirrors), and
  `download.onnxruntime.ai`, where the Swift package fetched its binary, fails TLS (certificate for
  another host; checked with curl on 2026-11-25). Third-party mirrors exist; one of them carries a
  re-tagged `1.24.2` that differs from the commit four others agree on (`b7fb7f7`). The developer
  chose the official NuGet package over a mirror or skipping ORT.
- **Source:** `Microsoft.ML.OnnxRuntime` 1.32.0 on nuget.org (published 2026-11-13), 184 MB,
  SHA-256 `a9150bc2…5641db`. Its SHA-512 matches nuget.org's catalog; it carries Microsoft
  Corporation's author signature and NuGet.org's repository signature (not cryptographically verified
  here: that needs `dotnet nuget verify`).
- **Assembly** (`ios/tools/fetch_onnxruntime.sh`, run by `bootstrap.sh`; output gitignored in
  `Packages/MusiclessCore/Vendor/`): the package's `ios-arm64` and simulator frameworks (a static
  library, CoreML execution provider included) plus a module map, and a `macos-arm64` framework
  wrapping the package's osx-arm64 dylib for `swift test` on the Mac. That dylib's install name is
  changed, so its Microsoft signature is stripped and it is signed ad hoc; it never ships.
- The static library needs `libc++`, `libz`, `libsqlite3`, Core ML and UIKit (it reads `UIDevice`);
  Package.swift links them (UIKit on iOS only).
- Licences: the package's `LICENSE` and `ThirdPartyNotices.txt` are copied next to the xcframework for
  About (US-024).

### D28. ONNX Runtime through its C API — US-005

NuGet ships no Objective-C wrapper, so `OnnxSession` calls the C API (`OrtApi`, version 32) directly.
Session options match Android's: intra-op 2, inter-op 1, no CPU arena, no memory pattern,
`session.intra_op.allow_spinning=0`, basic optimisation, free dimension `num_splits` = 1; telemetry
off on the one process-wide environment. The CoreML execution provider gets `ModelFormat=MLProgram`,
`MLComputeUnits` = `ALL` or `CPUAndNeuralEngine`, and a `ModelCacheDirectory` so compiles are reused.

### D29. `ModelRuntime`: an actor on one serial queue — US-005

The actor's executor is a `DispatchSerialQueue` ("Musicless-ORT"), the counterpart of Android's single
model thread: loading, the whole window pipeline (DSP, both models, mask) and disposal run there, so
`cpuMs` is one thread's CPU time as on Android. Only the 512-frame `Dsp` is kept; ramp sizes are built
per use (Android's ~22 MB saving). Release after 120 s idle; a memory warning releases only when no
player holds the runtime (iOS has no `TRIM_MEMORY_UI_HIDDEN`; "idle" is the PRD's rule).

### D30. `Separator`: Android's grid behind an async API — US-005

- `configure(sampleRate:channels:)`, `enqueue(_:) async`, `endOfStream() async`,
  `flush(passThrough:)`, `close()`, and chunks pulled with `nextChunk()` (or `chunks`). Each chunk has
  its generation, start frame, voices, and flags for silence and end of stream.
- Backpressure: where Android's `queueInput` returns without consuming while 2 windows are
  outstanding, `enqueue` suspends; a flush or close wakes it, and it drops the rest of its samples
  (they belong to the old position).
- A flush drops queued windows at once (Android skips them when the worker reaches them); the running
  window keeps its slot until it returns and sees the new generation. Same bound, freed sooner.
- Failure: everything received and not yet taken comes out as silence, further input too, with the
  error in `failureMessage` and a log line; never the original audio. A flush clears it, as Android's
  `onFlush` does.
- Other rates and mono go through `AVAudioConverter` (PRD §4.3), with mono copied to both channels
  (`channelMap [0, 0]`) instead of mixed down.
- Every window logs Android's line: `Window pipeline ms=… processor=… generation=… window=… frames=…
  outputStartFrame=… outputFrames=… queueMs=… waitModelMs=… analyzeMs=… vocalsMs=… accompanimentMs=…
  maskMs=… synthesizeMs=… otherMs=… cpuMs=… backend=…`. `appState=` is the app's to append when
  playback logs it (Phase 2).

### D31. Backend names in logs — US-005

`backend=ort-cpu`, `ort-coreml-all` or `ort-coreml-ane` (the PRD wrote `ort-coreml`): the two CoreML
compute-unit settings behave differently enough (locked GPU failures) to need separate names.

### D32. End-to-end fixture: the Sintel trailer, not committed — US-005

- 30 s (15–45 s) of the Blender Foundation's Sintel trailer (CC BY 3.0), decoded once by `afconvert`.
  `ios/tools/separation_fixture.sh` downloads it (SHA-256 pinned), cuts it and runs
  `ios/tools/reference_two_models.py` (numpy + onnxruntime 1.32.0 from PyPI, in a venv under
  `ios/.vendor`). Clip and reference (16 MB) live in gitignored `ios/.fixtures/`, like the models;
  the licence, attribution and hashes are committed in `Tests/…/Fixtures/separation/LICENSE.md`.
- The Swift test runs when the models and the fixture are present and skips otherwise.
- **Measured: SNR 124.3 dB** against the Python reference on the Mac (max error 2.1e-6), 123.3 dB on
  the iOS simulator. The PRD's 35 dB threshold is easily met.

### D33. Benchmark method — US-006

A deterministic tone-and-noise signal instead of a bundled clip: the models do the same arithmetic
for any audio, and nothing has to be licensed or shipped. Timings come from a Release build (the
debug build's Swift loops are unoptimised); `--console-log` mirrors its log to stdout. Windows run
back to back (harder on thermals than playback, which waits ~12 s per window). The locked run waits
for the app to be backgrounded, so Auto-Lock can do the locking unattended. Results:
`docs/ios/BENCHMARKS.md`.

### D34. D-backend: ONNX Runtime on the CPU — US-006 (closes Q1)

ORT CPU: F=512 in 258 ms foreground and 264 ms locked (gate: 3,000 / 6,000 ms), first window 38 ms,
load 131 ms, peak 116 MB, and numerically identical to the reference. The CoreML execution provider
loads in 0.8–2.2 s, needs 284–1,827 ms for the first window of each shape and 450–570 MB, fails
every locked inference with `ALL` (no background GPU), and its `CPUAndNeuralEngine` sessions show no
sign of using the Neural Engine (thread CPU = wall time). **US-007 is skipped.** `InferenceBackend`
stays switchable for a later energy comparison.

### D35. Background audio and Files access now, not in Phases 2 and 5 — US-006

The locked benchmark needs `UIBackgroundModes: audio` (PRD: Phase 2) and its CSV in Files needs
`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` (PRD: Phase 5). Neither needs an
entitlement, so free Apple IDs still sign the app.

### D36. No Increased Memory Limit entitlement yet — US-006

PRD §4.6 lists Increased Memory Limit and Extended Virtual Addressing for Phase 1. They aren't added:
with ORT CPU, separation peaks at 116 MB while `os_proc_available_memory()` reports 2,088 MiB at
launch (DEVICE-PROBE.md), so they would buy nothing and would make the app need a paid team. Revisit
when playback (video + audio + separation, Phase 2) is measured against the 700 MB budget. The free
Personal Team test (Q8, D15) moves with them: there is still no paid-only capability to test.

## Phase 2

### D37. InnerTube requests: QueryBuilder's template, ported literally — US-008

- `ClientProfile` holds VISIONOS, TV_TIZEN, WEB_EMBED, ANDROID_VR, ANDROID_REEL and IOS, copied from
  MediaServiceCore `52fecea0` (2026-10-20) with the source of every value in comments.
- `PlayerRequestBody` builds the body the way `QueryBuilder.build()` does (a multi-line template,
  lines trimmed and joined, trailing object commas removed outside strings), so spacing quirks such
  as `"clientName": "…"` next to `"osName":"visionOS"` come out identical. The test compares the
  VISIONOS body with one reconstructed by hand from the Kotlin template, byte for byte.
- `acceptLanguage` is the BCP-47 tag (Android's `Locale.toLanguageTag()`, e.g. `en-US`), not the bare
  language code.
- Headers as `VideoInfoApi`: Content-Type, Origin, `X-Goog-Visitor-Id` (same visitor as the body), the
  client's UA, name id and version; no Referer, no Cookie, no key; 8 s timeout. One URLSession with no
  cookie jar and no cache.
- The visitor comes from `youtube.com/tv` with the Fire TV UA, replaying the stored
  `VISITOR_INFO1_LIVE` plus the SOCS consent cookie (`AppServiceInt`, including `nextVisitorCookie`'s
  rule that an answer without the cookie can't erase the identity); it persists for 10 h in
  Application Support. The signature timestamp comes from the TV player JS with
  `signatureTimestamp[:=](\d+)` (Android's `signatureTimestamp:(\d+)`, plus `=`), once per player
  URL, persisted; -1 when unknown.
- Every request logs `api client=… status=… ms=… protocol=…`. **On the iPhone (2026-11-25):** `tv`,
  `player-js` and every `/player` request ran over `h2`.

### D38. VISIONOS serves with `signatureTimestamp = -1` — US-008

- **/player, on the iPhone, 5 ordinary videos:** VISIONOS answered `OK` with the same adaptive
  formats, all with plain URLs (no cipher), SABR and HLS markers, whether the body carried the real
  timestamp (20779, player `b485e332`) or -1. So VISIONOS doesn't need the timestamp to *answer*.
  /player took 118–229 ms.
- **Media, on the iPhone over cellular (2026-11-25):** the first KiB of every answer's audio
  (Range header) came back **206 for 10 of 10 answers, 5 of 5 with -1**. VISIONOS needs no real
  timestamp; the engine still sends it when known, as Android does.
- **On the developer's home Wi-Fi the same probe timed out:** the googlevideo cache node YouTube
  assigned there refused TCP connections from the phone and the Mac alike, while
  `redirector.googlevideo.com` and other nodes answered, and the redirector sent the request back to
  the dead node. The official YouTube app played fine on that Wi-Fi at the same time, so its player
  gets around such a node.

### D39. googlevideo host fallback through the URL's `mn` nodes — for US-010

- **Evidence (iPhone, home Wi-Fi, 2026-11-25, 10 answers):** every assigned node timed out, and
  several different ones of the same local cache group did (`rrN---sn-<isp>-…`). Retrying the same
  signed URL on the URL's alternate node (`rrN---<other mn entry>.googlevideo.com`, same replica
  prefix) served **206 for 10 of 10**, with -1 timestamps too. Cellular reached the assigned nodes
  directly. Android has no such fallback (no `mn` or `redirector` handling in MediaServiceCore or
  the app), so it would stall on this network.
- **Plan for US-010:** the MediaFetcher retries a connection failure or timeout on the `mn`
  alternates, then remembers the dead node for the session, so later requests go straight to one that
  answers. It needs a short connect timeout on the first attempt (each fallback above first waited
  10 s, which would break G2's 2.5 s start): measure the value in US-010. This differs from Android
  on purpose; a 403 is still handled by re-resolving, never by changing hosts (PRD §0.4).

### D40. Answers: parsing, kinds and the pair to play — US-009

- `PlayerAnswer` decodes what Android's `VideoInfo` reads for playback (playability with reason,
  subreason and the age marker; video details; adaptive formats with ranges, length, `lastModified`,
  URL or cipher; the HLS, DASH and SABR URLs). Numbers may arrive as strings; both decode.
- `AnswerKind` is the per-answer verdict of LANES §2.2, ported from `VideoInfo`'s predicates and
  `BotCheckDetector` (the explicit bot words; the terminal allowlist in six locales, members-only
  openings, violation removals with their qualifier, "learn more" and region guards; Java's NFD
  normalisation as Foundation's decomposition minus non-base characters). Two additions: `noDelivery`
  for OK without fetchable formats (SABR-only), and `unavailable(status)` for ERROR and the other
  statuses no rule names. The lane-dependent rules (admitting anonymous TV_TIZEN, the age-gate stop,
  consensus) stay with the planner (US-015).
- `FormatSelector`: the best `video/mp4` avc1 at ≤ 60 fps whose **short side** is within the cap
  (a vertical 1080x1920 video is 1080p, as Android's quality fix in HANDOFF §38), preferring size,
  then frame rate, then bitrate; audio is the highest-bitrate `mp4a.40.2` at 44.1 kHz, else any mp4a.
- **Fixtures** were recorded on the iPhone (`--record-answers`) and scrubbed by `AnswerScrubber`: only
  `playabilityStatus`, `videoDetails` and `streamingData` are kept (visitor ids live in the dropped
  `responseContext`); the requester's IP, which googlevideo embeds in every URL (`ip=`, and
  `/ip/…/` in manifest paths), is replaced everywhere; the cache node names (`rrN---sn-…` hosts and
  the `mn=` list, which point at the requester's ISP) become `sn-scrubbed-<n>`, keeping the structure
  US-010's host fallback needs; and the country (`gcr=`) and opaque per-request tokens (`ei`, `bui`,
  `spc`, `xpc`, `svpuc`, signatures, throughput, timing) become `scrubbed`, in query and manifest-path
  form. A test re-checks every committed fixture. `fvip=` is a replica index, not an address. (The
  node names and the country slipped into the first local commit; it was amended before any push.) Videos age: the first made-for-kids and live candidates had become
  "removed by the uploader" and "live recording not available", so the recorder tries candidates
  per kind, and those two answers became extra terminal fixtures (7 in all, 142 KB).
- **On the iPhone:** 10 of 10 ordinary videos resolved with one VISIONOS request each (119–495 ms),
  picking 1080p avc1 where offered (60 fps for the 60 fps video) and itag 140 (AAC-LC 44.1 kHz).

### D41. The media fetcher — US-010

- `MediaFetcher` (MediaPipeline, no YouTube types: a `MediaFile` is itag + lmt + clen + URL) reads
  byte ranges through a `Range` header only, with `assumesHTTP3Capable`, on one cookie-less,
  cache-less media URLSession. Sequential reads (`chunks(from:)`, pull-based) start at 256 KiB after
  every start, seek or repoint and double to 2 MiB.
- **Measured on the iPhone (home Wi-Fi, 2026-11-25):** the first 256 KiB took 67–374 ms once a node
  was proven, against 712–1,980 ms for a 2 MiB first request; later 0.5–2 MiB chunks 74–488 ms; whole
  AAC files at 2.3–8.6 MiB/s. So the 256 KiB → 2 MiB ramp stays. googlevideo nodes spoke HTTP/1.1
  over TCP (curl on the Mac too) and h3 only occasionally; that's the server side.
- A 403 (or 401) is a typed `MediaRefused(itag, byteOffset, url, status)`, never retried on that URL.
  The caller maps the offset to stream time (sidx) for the wall rule (US-017), walks for a new answer,
  `repoint(to:)`s, and resumes from the offset. `repoint` only accepts the same file (itag, lmt, clen).
- Timeouts and 5xx get 3 retries with exponential backoff from 250 ms; a lost link
  (`networkConnectionLost`, `notConnectedToInternet`, …) waits on `NWPathMonitor` for a usable path
  first. A 200 for a partial range is an error (the server ignored `Range`).
- **Host fallback (D39), as built:** a node not yet seen answering on this network gets a 2 s idle
  timeout and, if still silent after 750 ms, its URL's next node (`mn`) starts in parallel; the first
  answer wins and the loser is cancelled and marked dead. Dead nodes, and the rest of their cluster
  (`sn-<cluster>-…`), go after the alternates until the network signature changes (then the book
  starts over: cellular reached the same cluster). Nodes that answered go first. Measured: a dead node
  costs ~0.75 s once per network; later videos go straight to working nodes.
- `NetworkWatcher` waits for `NWPathMonitor`'s first path before reporting a signature (up to 0.5 s):
  answering "unknown" first made the book take the real signature as a network change and forget
  what it had learned (seen on the device: the dead node was asked again).
- **Known limitation:** the race times a request's completion, not its first byte, so a large
  request to an unproven node can start a needless duplicate. The pipeline's first request to a node
  is small (256 KiB, init or index ranges), so it rarely matters; the fix would be a streaming task
  delegate that signals the response headers.

### D42. The fMP4 demuxer, and YouTube's AAC carries no priming signal — US-011

- `FMP4Demuxer` (MediaPipeline) parses the subset YouTube serves: ftyp + moov (`tkhd`, `edts/elst`,
  `mdhd`, `hdlr`, `stsd` with avc1/avc3 + avcC and mp4a + esds, `mvex/trex`), the sidx (byte ranges
  anchored after the box; `seek(to:)` maps a time to a reference), and moof (`tfhd` with every
  default, `tfdt`, `trun` with every flag, v0/v1 composition offsets) + mdat. `FMP4Track` builds the
  CoreMedia format descriptions (SPS/PPS; AAC with the ES_Descriptor as magic cookie) and one
  `CMSampleBuffer` per sample (PTS/DTS/duration in the track timescale; `NotSync` and
  `DependsOnOthers` on non-sync video samples).
- **Fixtures** (368 KB, CC BY 3.0): Big Buck Bunny as YouTube serves it, init + index + two
  segments of itag 140 (AAC-LC 44.1 kHz stereo, 64 references of 9.98 s) and itag 160 (H.264 144p,
  123 references), recorded on the iPhone with `--record-media`; media bytes and ranges only.
- Tests decode for real: the first H.264 sample through VideoToolbox (a 256-px frame) and 200 AAC
  packets through AVAudioConverter (204,800 stereo frames, not silent).
- **PRD §4.2 assumed the AAC priming is signalled by an edit list. YouTube's itag 140 has none:** its
  init holds no `edts`, and its `udta` only names the encoder ("Google"); no iTunSMPB-style gapless
  tag either. The video track does have an `elst`. Core Audio's AAC decoder trims nothing on its own
  (200 packets → exactly 200 × 1024 frames), and Android's media3 sees an encoder delay of 0 for these
  files, so it doesn't trim either. So `FMP4Track.priming` exposes `elst` when a file has one (local
  files, downloads), and is 0 here. Whether YouTube's audio then runs late against its video gets
  measured in US-013 with an A/V sync test video (limit 40 ms); a fixed trim is added only if the
  measurement asks for it.

### D43. The audio-only player — US-012

- **The chain, as built:** `VoicePlayer` (MediaPipeline, an actor on its own serial queue) reads the
  file with `FMP4Reader` and decodes it with `AACDecoder`. It runs the PCM through a `VoiceStage`
  (the Separator), turns the voices into LPCM `CMSampleBuffer`s, and plays them on an
  `AVSampleBufferAudioRenderer` attached to an `AVSampleBufferRenderSynchronizer`.
  - **FMP4Reader:** the first request takes the init range, the index range and the rest of the
    first 256 KiB. The opening 10 s segment (≈ 160 KB) usually comes with them: one round trip
    instead of three. After that it reads whole segments, in requests that double up to 2 MiB.
  - **AACDecoder:** `AVAudioConverter`, streaming with "no data now" so its state carries across
    segments. Its output keeps the track's own rate and channels; the Separator converts what isn't
    44.1 kHz stereo, so nothing is resampled twice.
  - **Sample buffers:** Float32 44.1 kHz stereo, 16,384 frames each (0.37 s).
- **`VoiceStage` is a protocol in MediaPipeline,** so the package needs no ONNX Runtime and its tests
  run the player with a fake stage. The app adapts the Separator to it (`SeparatorStage`). The
  Separator gained:
  - generation-checked `enqueue` and `endOfStream`, so a late call from an old position can't leak
    into the new one (the order of two actors' calls isn't guaranteed);
  - a `flush` that returns the new generation;
  - Android's hold fields: `beginHold()` and `holdStats` (`inputReadyNs`, `queueMs`,
    `waitModelMs`, `inferMs`).
- **Bounded look-ahead:** a voice chunk is taken from the stage only once the previous one is in the
  renderer. Memory holds one chunk (≤ 11.9 s) plus the stage's two windows. Android does the same:
  it drains processor output only after the AudioTrack has taken the previous output.
- **How the renderer behaves** (Mac probe, then the iPhone):
  - It accepts ≈ 1.1 s before `isReadyForMoreMediaData` turns false, and keeps 1.7–2.1 s queued
    while playing.
  - When it runs dry, the synchronizer's clock keeps running, so late voices would be lost. That's
    why a hold must set rate 0.
- **Hold:**
  - From a start or seek, rate 0 until the first voices are queued.
  - Later, a hold when less than 0.25 s is queued and more is coming, debounced 100 ms
    (`HoldDebounce`, ported with Android's test).
  - **Differs from Android:** a slow network holds too (`reason=underrun`; `waitInputMs` shows the
    wait for input), because nothing else stops this clock. On Android, ExoPlayer pauses for network
    buffering on its own.
  - The clock check sleeps until a hold could first be needed (queued time − 0.25 s): 2–4 wake-ups a
    second. It checks every 25 ms while debouncing, and every 250 ms while held or paused.
  - The `hold reason=start|seek|underrun waitInputMs=… queueMs=… waitModelMs=… inferMs=… totalMs=…`
    line keeps Android's format.
- **`delaysRateChangeUntilHasSufficientMediaData = false`:** our hold decides when the clock runs,
  without an unmeasured extra wait. At first audio (1.11 s queued),
  `hasSufficientMediaDataForReliablePlaybackStart` was already true anyway.
- **Seek and the Remove-music switch** do the same restart:
  - flush the renderer and the stage (switching pass-through);
  - fetch from the target's segment;
  - drop decoded frames before the target, so the voices start exactly there.
  - **Known gap:** the restart fetches bytes it already had (≈ 0.5 MB on a switch, 9–49 ms on Wi-Fi).
    A byte cache belongs to US-013, which measures seeks.
- **Automatic renderer flush** (an output change): the buffers not yet played are kept and
  re-enqueued from the flush time. A flush of our own goes first, which keeps them in order. This
  hasn't happened on the device yet.
- **Audio session:**
  - `.playback` / `.moviePlayback`, activated on play.
  - An interruption pauses playback and resumes it when iOS passes `shouldResume`.
  - Losing the output device (headphones unplugged) pauses.
  - Now Playing and remote commands are US-018.
- **Logs** (besides the hold line):
  - `voices chunk startS=… seconds=… inputDb=… voicesDb=…`: input and voices levels over the same
    span, so the drop in level is measured, not guessed;
  - `voices first-audio ms=…` (from `start`), `voices tap-to-first-audio ms=… playerMs=…`;
  - `voices position=…` every 10 s;
  - `appState=fg|bg` on these lines and on `Window pipeline`.
- **Test harness:**
  - the "Voices only" debug screen;
  - `--voices [<id>] [--voices-at <s>]`;
  - four presets: Big Buck Bunny (score, no speech), Sintel (dialogue over score), Kurzgesagt's
    "The Egg" (narration over music), and Rick Astley (a song).
  - US-014's watch screen replaces it.
- **Measured on the iPhone** (home Wi-Fi, Debug build, 2026-11-25):
  - **Tap to first voices:** 920–1,310 ms, against G2's 2.5 s. 362–532 ms of it is `/player`.
  - **The start hold:** 487–638 ms: input 293–389 ms, model load 124–172 ms, first window 53 ms.
  - **Switch holds:** 129–360 ms.
  - **F=512 windows:** 268–347 ms in this unoptimised build; D34 measured 258 ms in Release.
  - **After the start:** no hold while playing.
  - **Output:** the hardware runs at 48 kHz, and the renderer resamples.
- **Ear test** (the developer, on the iPhone): Big Buck Bunny with Remove music switched on and off
  several times. Music was gone with it on and back with it off. Levels over the same spans: voices
  10–34 dB below the input with it on, equal to it with it off. The score-only film keeps some animal
  and bird sounds: the vocals model keeps voice-like sounds, which aren't music.
- **Sintel's levels** (the lock run): its opening 33 s, score without dialogue, came out 40–59 dB below
  the input, which is silence. Its dialogue (34–80 s) came out 9–15 dB below: the speech stays.
- **Screen lock** (side button, 2026-11-25; Auto-Lock is off on this phone):
  - Sintel locked at 22 s and stayed locked for about 45 s. Scene phase went inactive → background,
    and the log carried `appState=bg`.
  - The position kept advancing in real time (31 → 62 s), with 1.7–2.2 s queued. F=512 windows ran in
    the background at 267–276 ms (thread CPU = wall time), with no hold.
  - After unlocking, the same playback was still running.
  - So the CPU and the network keep working while audio plays (PRD §4.5).
- **The player outlives its screen:** RootView owns it and stops it when the screen's route is popped,
  not in `onDisappear`, so a lock or a sheet can't stop it. Every stop logs
  `voices stop reason=stop button|left the screen|new video`. Two early "lock" runs turned out to be
  the developer stopping playback; the reason line now tells those apart.

### D44. Video, sync and seek — US-013

- **`PlayerEngine`** (the US-012 player, renamed) carries an optional `VideoInput`: the H.264 file, its
  fetcher, and a display layer's `sampleBufferRenderer` on the same synchronizer.
  - Samples stay compressed; the renderer decodes them in hardware.
  - They're pulled by `requestMediaDataWhenReady`; the renderer keeps 1–2 s queued (Mac probe and
    iPhone).
  - `VideoInput` is `@unchecked Sendable`: the SDK doesn't mark the renderer Sendable, but it exists
    to be fed off the main thread, and only the engine's queue touches it.
  - A standalone `AVSampleBufferVideoRenderer` never asks for data on the Mac; one taken from a
    layer does, on screen or not, so tests use a layer.
- **Edit lists:** YouTube's H.264 starts at PTS one frame (512/15,360 at 144p, 1001/30,000 at 30 fps)
  with an edit list of the same value, and the engine applies it, so frame 0 shows at 0. The
  cross-check: the same video's VP9 file (WebM, no reordering) has its first block at 0.00 ms.
  Android's media3 applies the same single-edit offset.
- **Hold:** starvation now counts the picture too: less than 0.25 s of displayable frames queued, while
  in the foreground and not catching up. The start and seek holds wait for both tracks.
- **Seek (PRD §4.2):**
  - Both renderers and the stage are flushed.
  - The picture restarts at the target segment's keyframe. Frames before the target get
    `kCMSampleAttachmentKey_DoNotDisplay`: decoded, not shown.
  - The first shown frame in decode order can be up to a few frames past the target (B-frames);
    the target's own frame follows it and is shown.
- **The Remove-music switch restarts only the audio.** The queued picture stays valid at the same
  clock time, so it isn't flushed or refetched.
- **Segment cache and prefetch:**
  - A per-file LRU cache (16 MB audio, 48 MB video) serves seeks back and switches without a request.
    Many segments fit, so the one being played is never the one a new write evicts.
  - Video prefetches one group: a 1080p segment (1–2.5 MB) is requested as soon as the previous one
    is handed out, not when the renderer runs short.
- **Background without PiP:**
  - `didEnterBackground` stops the video feed and fetch; the voices play on.
  - **Measured, not fed:** the renderer still fails in the background with `requiresFlushToResumeDecoding`
    and AVFoundation error -11847 (`AVErrorOperationInterrupted`). This settles the PRD §4.2
    `[verify]` item.
  - `willEnterForeground` flushes the renderer and restarts at the segment holding the playhead.
    Frames earlier than the playhead + 0.1 s are hidden while it catches up, and that catch-up doesn't
    hold the voices.
  - If the renderer fails while feeding, the video stops quietly and the next activation restarts it.
    Not a playback failure.
- **YouTube's AAC runs 38.9 ms late, undeclared, and the engine compensates** (closes D42's
  question):
  - `--sync-check` decodes a sync test ("Five minute sync test", `szoOsG9137U`, a sweep with "Bip!"
    and its waveform drawn on frame 0 of every second, 480p30).
  - On the engine's timeline, the AAC beeps land 84.5 ms after their frames (83.8–85.0, 40 pairs).
    The same audio decoded from YouTube's Opus file lands at 45.5 ms. That file's WebM header states
    its delay: `pre_skip` 312, `CodecDelay` 6.5 ms, subtracted.
  - So the AAC is 39.0 ms later than the Opus. `--delay-check` cross-correlates the two decodes on any
    video: 38.9 ms for 4 of 5 (correlation 0.987–0.997), and 33.9 ms for Sintel, an older upload.
  - None of this is declared: no `elst`, no gapless tag (D42).
  - `PlayerEngine.Configuration.audioDelay` moves the audio earlier by a given amount and drops what
    falls before 0. The app sets 38.9 ms for AAC-LC at 44.1 kHz (`YouTubeAudio`); for Sintel that's
    5 ms early, which nobody can hear.
  - After the trim, the engine's AAC beeps land at 45.6 ms: the Opus/WebM timeline to 0.1 ms.
  - The remaining 45.5 ms is in YouTube's encoding of that upload. Its Opus, VP9 and AAC all agree,
    so any correct player shows it.
  - **Differs from Android:** media3 sees no encoder delay and plays YouTube's AAC about 39 ms late.
  - Apple's Opus decoder returned 120 frames (2.5 ms) fewer than packets × 960. Whether those are held
    back or dropped is unknown, so the reference carries ±2.5 ms.
- **Renderer clocks:** each renderer's timebase stays within 0.02 ms of the synchronizer's clock
  (`audioClockMs`/`videoClockMs` on the position line), so both present on one clock. The
  synchronizer compensates audio output latency itself. A slow-motion recording of the screen and
  speaker, the PRD's last check of the output side, still needs the developer.
- **Measured on the iPhone** (home Wi-Fi, Debug build, 2026-11-25; Sintel at 1080p, 1920×818 avc1):
  - **Seeks:** median **938 ms** over 10 seeks (445–1,420), and **456 ms** (328–647) in a second run
    of the final build, against the 1.5 s target.
  - **Picture after the background:** the first frame is shown **94–163 ms** after the return
    (median 129, 3 rounds, unattended: the app opens the Files app, and `devicectl … launch` brings
    it back). The voices never stopped.
  - **Start with the picture:** tap to first voices and picture took 1.0–2.4 s. The slow case was
    the video's first request to an unproven node (881 ms).
  - Both tracks stay 1.5–2.2 s queued while playing.
- **Test harness:**
  - The debug screen is now "Watch (debug)": picture on top, an "Audio only" switch, and a
    "Preparing voices…" overlay.
  - Launch flags: `--seek-check`, `--background-test`, `--sync-check [<id>] [--sync-seconds <s>]
    [--sync-frames]` and `--delay-check [<id> …]`.

### D45. The debug watch screen — US-014 (ends PR B's code)

- **Links:** `VideoLink` (YouTubeEngine) ports SmartTube's `IntentExtractor`:
  - the id comes from `v`, else the first of `video_ids`, else a `vnd.youtube://` host, else the last
    path segment, and is accepted at 11 characters;
  - `t=` gives the start (`90`, `1m30s`, `1h2m3s`).
  - iOS also takes bare ids and links without a scheme, and checks the id alphabet; Android checks
    only the length.
  - Covered: watch, `m.`, `music.`, youtu.be, shorts, embed (and nocookie), live, `watch_videos`.
  - Refused: channel links, handles and searches.
- **Screen** ("Watch (debug)", `WatchDebug`):
  - a link field with a `PasteButton`, which reads the clipboard without the paste prompt;
  - play/pause and ±10 s;
  - a seek bar that seeks on release;
  - the H.264 quality picker (`VideoOption`: every avc1 ≤ 1080p and ≤ 60 fps, one per label, best
    first);
  - the Remove-music switch: an audio flush, the engine is kept;
  - the overlay while holding: "Preparing voices…", or "Downloading voice models… N%" while
    playback waits for the models.
- **Quality switch** (`PlayerEngine.switchVideo`): reads the new file's header, then restarts the
  picture at the playhead and catches up as after the background. The old picture stays up meanwhile
  (a flush keeps it), and the voices play on.
- **Right to left:** with forced RTL, the screen mirrors, but the seek bar and the playback buttons
  stay left to right: timelines show the tape's direction (Apple HIG, "Right to left"). Debug strings
  stay English. The real Arabic check needs US-025's localisation: iOS lays out an app without an
  Arabic localisation left to right, even with Arabic as the language.
- **Measured:**
  - Simulator: a fresh install played with no models. The overlay showed the download (0 → 100 % in
    ~3 s on the Mac's network); the start hold lasted 4.1 s, of which `waitModelMs` 2,962.
  - iPhone, `--quality-check`, Sintel from 1:40: 6 switches (128p → 818p). The picture caught up in
    102–648 ms after each, with no hold and no gap in the voices.
- **Not done here:** the PR's demo recording from the iPhone (needs the developer). The simulator's
  `simctl io recordVideo` fails without a Simulator window (SimRenderServer error 2). Screenshots
  are in the gitignored `ios/build/demo/`.

### D46. The source walk, signed out — US-015

- **The order:** `SourcePlanner` ports MediaServiceCore's `PhoneSourcePlanner` whole, including the
  recovery, wall and live-card shapes US-017 will feed. Two differences:
  - It leaves out MWEB, WEB and WEB_SAFARI, which need PO tokens (PRD §4.4).
  - The tail keeps Android's order, IOS before ANDROID_REEL. The PRD's US-015 line wrote ANDROID_REEL
    → IOS; Android is the reference, and neither has been measured to serve what the first four
    refuse.
  - Android's `PhoneSourcePlannerTest` is ported with its expected strings verbatim, the three web
    clients dropped by a helper.
- **The walk:** `SourceWalker` ports `VideoInfoService.firstPlayable` for the signed-out lane:
  - TV_TIZEN is admitted after an anonymous non-web content refusal, once, on a 7 s budget;
  - the age-gate stop;
  - terminal consensus;
  - `BotCheckWalkState` (hold, walk on, discard on a serve, a lone challenge amid refusals);
  - a repeated sign-in request is confirmed only by a second video within 10 min, and only when the
    walk's sign-in requests agree;
  - the circuit: 15 min, one probe a minute, earned only by a walk that reached the end, cleared by
    a network change;
  - the anonymous-challenge memory (15 min, web sources last);
  - the live hold (only ANDROID_VR after a live answer without DASH);
  - 45 s per walk, 1.5 s minimum per attempt, transport-down after 2 silent attempts.
- **Identities, iOS has two:** every source rides the youtube.com/tv visitor except WEB_EMBED, which
  rides its embed page's (PRD §4.4, D37). Android's VISIONOS and ANDROID_VR ride a third, the web
  session's. Consensus therefore settles on the same allowlisted terminal key from 3 sources over
  both identities (removed or members only: at request 3, Android at 4).
  - A walk with no WEB_EMBED agreement can't settle: for a removed video WEB_EMBED answered a generic
    ERROR, which is neutral, so all 5 sources were asked. Android's 3-identity rule exhausts there
    too.
- **The classified text:** answers are classified on reason and subreason joined with " • ", the text
  Android's walk reads (`VideoInfo.getPlayabilityStatus`). US-009's `AnswerKind` read the reason only.
- **Replay** (`WalkReplayTests`): Android's device fixture (`device_walks.json`, MediaServiceCore
  `902e4d17`, copied with its provenance) runs through the iOS walk.
  - Covered: 12 signed-out cases (kids, adult embeddable and not, live, removed, private + ordinary +
    members in one process, paid, music only, and the first walks of three recovery cases), 15 walks.
  - Each must ask the device's sources (minus the web three), in order, and settle the same way.
  - Two walks are named as changed by the 2-identity consensus.
  - Disabling the TV_TIZEN admission fails 5 cases, so the replay has teeth.
  - Media failures (US-017) and signed-in cases (US-022) aren't replayed yet.
- **Requests** (`PlayerSources`):
  - each source's QueryBuilder body, a total per-attempt timeout (no answer → no response);
  - ANDROID_REEL to `youtubei.googleapis.com/…/reel/reel_item_watch`, its `playerResponse` unwrapped;
  - WEB_EMBED's identity from `youtube.com/embed/<id>?html5=1` (Safari UA, reddit Referer):
    `encryptedHostFlags` with that page's own visitor, the two bound, cached 6 h, invalidated on a
    152 refusal.
- **iPhone (home Wi-Fi, 2026-11-25):**
  - "Baby Shark Dance" (`XqZsoesa55w`, made for kids) played through anonymous TV_TIZEN at request
    2. VISIONOS answered "This video is not available"; the walk took 350–381 ms.
  - The issue #5 video in the fixture (`_WB5hh7WOb4`) is now "removed by the uploader": every source
    agreed except WEB_EMBED's generic error.
- **Not ported yet:**
  - `BotWallBook` (the network wall's plan) and the recovery state (suspects, recent refusals,
    walls): US-017;
  - `KidsChannelMemory` and the live card: they need the app to name a video's channel or live
    state (Phase 4);
  - live playback: a live answer is reported as "live streams don't play yet".
  - TV_TIZEN answers carry no title in `videoDetails` (the screen shows the id); the watch page gets
    titles from `/next` (US-020).

### D47. The challenge solver: JavaScriptCore, with a warm-up — US-016

- **The bundle:** MediaServiceCore's solver bundle (yt-dlp's EJS `yt.solver.core.js`, meriyah 6.1.4,
  astring 1.9.0, its `polyfill.js`; `8e92399b`, licences in `JS/nsigsolver/README.md`) runs
  unchanged in a `JSContext`.
  - The context lives on one serial queue (`ChallengeSolver`, an actor on a `DispatchSerialQueue`).
  - The input is `jsc({type: "player"|"preprocessed", …})`, as Android's `JsRuntimeChalBaseJCP`
    sends it.
  - The preprocessed player is kept on disk per player id (Caches), the raw player JS too
    (`PlayerScripts`), and solved values in memory.
  - MediaServiceCore's `newtube.memo.js` isn't used.
  - The resource folder is `JS`: a package folder named `Resources` fails the app's code signing
    ("bundle format unrecognized").
- **What gets solved:** every `n` in the answer's URLs and every `s` in its `signatureCipher`, in one
  bulk call, with the TV player whose `signatureTimestamp` the requests sent. The signature goes in
  as `<sp>=` (default `sig`); the other parameters keep their encoding byte for byte. An answer with
  nothing to solve (VISIONOS, ANDROID_VR) isn't touched (Android's `setSkipSolveWithoutChallenges`).
- **Correctness:** JavaScriptCore gives exactly V8's answers. `ios/tools/solver_oracle.sh` downloads
  the current TV player (`b485e332`) and records Node's (V8's) answers to 6 `n` and 4 `sig`
  challenges; `ChallengeSolverTests` gets the same answers on the Mac, and the iPhone's
  `--solver-check` gives the same sample. googlevideo served the deciphered TV_TIZEN URLs (206).
- **Speed on the A15** (`--solver-check`, 3 rounds):
  - a cold solve (fresh context, the raw 2.3 MB player): **1,661–1,790 ms**;
  - from the preprocessed player: **74–84 ms**;
  - from the memo: 0 ms.
  - Mac: 1.2 s cold, 60 ms preprocessed; V8 280 ms cold.
- **Deviation from PRD §4.4** ("above 1.5 s, move it into a hidden WKWebView"):
  - The cold solve is over 1.5 s, but it happens once per player version (YouTube ships one about
    weekly), and its result persists. Every video after that costs 75–86 ms.
  - So the cold cost moves off the critical path instead: `PlaybackServices.warmUp()` preprocesses
    the current player in the background at launch.
  - A WebView would add an out-of-process round trip per solve and is suspended in the background.
  - Measured: first ciphered video cold, 1.76 s of solve and 2.9 s tap to voices. After the
    warm-up, 86 ms and **1.13 s**.

## Settled `[verify]` items

| PRD item | Result | Evidence |
|---|---|---|
| §9: Xcode 26.4 vs iOS 26.6.2 on the device | **Works.** No Xcode update needed | `xcodebuild` built for the pinned phone, `devicectl` installed and launched it, the console showed the app's log (2026-11-25) |
| §0.3 row 9: engine paths "after the submodule init" | Present, with corrections: `QueryBuilder` and `AppClient` are Kotlin, at `youtubeapi/…/common/helpers/QueryBuilder.kt` and `AppClient.kt`; `app/` has `AppService*` (visitor) and `PoTokenGate.kt`; `videoinfo/V2/VideoInfoService.java` and `videoinfo/V2/sources/PhoneSourcePlanner.java` as stated. The search, browse, next and sign-in services are located when their stories start | `ls`/`find` in `MediaServiceCore/youtubeapi/src/main/java/com/liskovsoft/youtubeapi` |
| §4.4: where the EJS solver bundle lives | `MediaServiceCore/youtubeapi/src/main/assets/nsigsolver/`: `yt.solver.core.js`, `meriyah-6.1.4.min.js`, `astring-1.9.0.min.js`, `polyfill.js`, `newtube.memo.js`; run by `app/nsigsolver/impl/V8ChallengeProvider.kt` | `find` |
| §4.6: the background GPU resource on the A15 | **Not available**: `BGTaskScheduler.supportedResources` = 0. The `continued-processing.gpu` entitlement buys nothing on this phone; background separation stays CPU + Neural Engine (§4.5 already plans `.cpuAndNeuralEngine`). Measured without the entitlement and the `processing` mode; recheck once in Phase 5 | `DEVICE-PROBE.md` |
| §0.3 row 10: string counts | Confirmed: `strings_mobile.xml` 373 en / 356 ar (plus 1 plural each). `strings_settings.xml`, which the PRD didn't count: 257 en / 255 ar | `grep -c '<string '` |
| §4.3 / US-005: the ONNX Runtime Swift package URL and version | **False.** The repo and its binary host are gone (D27). Developer chose Microsoft's NuGet package, 1.32.0 | `gh api`, `git ls-remote`, curl TLS failure on `download.onnxruntime.ai`, nuget.org catalog (2026-11-25) |
| US-003: tolerances achievable with Float32 vDSP | Yes, by ~4 orders of magnitude (D23) | `DspGoldenTests` |
| US-005: SNR threshold 35 dB | Met: 124.3 dB (Mac), 123.3 dB (simulator) (D32) | `SeparationEndToEndTests` |
| §4.3: "a few milliseconds with vDSP; the models dominate" | Yes: 12 ms of DSP in a 258 ms F=512 window on the A15 | `BENCHMARKS.md` |
| §4.5: the GPU is unavailable in the background | Confirmed: CoreML `ALL` fails every locked inference (error -6) | `BENCHMARKS.md` |
| §4.5: whether the Neural Engine keeps serving a locked-screen app | **Still open.** The `CPUAndNeuralEngine` sessions run locked at foreground speed, but probably on the CPU (thread CPU = wall time), so this says nothing about the Neural Engine. Irrelevant while ORT CPU is the backend | `BENCHMARKS.md` |
| §4.2: a display layer fed in the background fails "with an interruption error" | **True, even unfed:** the video renderer turns `requiresFlushToResumeDecoding`, status failed, AVFoundation -11847 (`AVErrorOperationInterrupted`); a flush on return resets it (D44) | `--background-test` on the iPhone |
| §4.2: AAC priming is signalled by an edit list, to be trimmed | **False** (D42); YouTube's AAC runs 38.9 ms later than its Opus, undeclared; the engine trims a fixed 38.9 ms (D44) | `--sync-check`, `--delay-check` |
| §4.4: the JS solver's speed in JavaScriptCore on the A15 | Cold 1.66–1.79 s (over 1.5 s), preprocessed 74–84 ms; kept in JavaScriptCore with a launch warm-up instead of a WKWebView (D47) | `--solver-check` |
| US-015: Android's walk replay tests' names | `VideoInfoReplayTest` (fixture `walk_replay/device_walks.json`), `PhoneSourcePlannerTest`, `BotCheckWalkStateTest` in MediaServiceCore's `videoinfo/V2` tests | `find` |
| §4.3: Spleeter's U-Net is Neural-Engine-friendly | Not established, for the same reason; would need a static-shape Core ML model (US-007's route) | — |
