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
