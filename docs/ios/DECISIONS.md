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
| §4.3: Spleeter's U-Net is Neural-Engine-friendly | Not established, for the same reason; would need a static-shape Core ML model (US-007's route) | — |
