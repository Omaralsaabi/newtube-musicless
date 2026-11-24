# NewTube Musicless: handoff

Everything someone taking over this fork needs: what it is, how music removal works, how the fork
build differs from NewTube, how releases are made, and how to keep up with NewTube.
For the prototype's history (rounds 1–5, measurements, dead ends) see [FEASIBILITY.md](FEASIBILITY.md).

## What the fork is

- **Repo:** [yshalsager/newtube-musicless](https://github.com/yshalsager/newtube-musicless), a GitHub
  fork of [aleixrodriala/newtube](https://github.com/aleixrodriala/newtube). The work lives on the
  branch `musicless` (the default); `main` is NewTube's.
- **What it adds:** on-device music removal ("Musicless"), a separate app identity, defaults for a
  Muslim audience, a full Arabic translation, and its own release/update pipeline.
- **What it doesn't change:** everything else is NewTube (phone UI, player, downloads) on top of
  SmartTube (YouTube engine, sign-in, SponsorBlock/DeArrow/RYD). Bugs there belong upstream.

## How music removal works

Code: `smarttubetv/src/stmobile/java/com/newtube/mobile/player/Musicless*.java`;
tests: `smarttubetv/src/test/java/com/newtube/mobile/player/Musicless*Test.java`.

```
ExoPlayer audio decoder
  -> MusiclessAudioSink  (wraps Media3's DefaultAudioSink)
       -> MusiclessAudioProcessor  (buffers PCM into windows, runs one worker)
            -> MusiclessDsp  (STFT -> spectrogram, mask, inverse STFT)
            -> MusiclessModelHolder  (ONNX Runtime sessions: vocals + accompaniment)
       <- separated voices, timestamped
  -> AudioTrack
```

| Class | Job |
|:--|:--|
| `MusiclessPrefs` | The on/off switch (SharedPreferences `newtube_musicless`). Off in NewTube, on by default in the fork build. |
| `MusiclessModels` | Downloads `vocals.onnx.gz` and `accompaniment.onnx.gz` from the `musicless-models-v1` release, checks SHA-256, keeps them in `noBackupFilesDir/musicless/`. Started at app launch when the switch is on. |
| `MusiclessModelHolder` | Loads both ONNX sessions on one process-wide thread; all inference and disposal run there. |
| `MusiclessAudioProcessor` | Collects 44.1 kHz stereo PCM into windows and hands them to the worker. Windows ramp 64 → 128 → 256 → 512 frames (1.5 s → 12 s, 1024-sample hop, 2048-sample overlap), so the first audio is ready quickly; it resets on seek. At most two windows are queued ahead. |
| `MusiclessDsp` | Spleeter's STFT/ISTFT and the voice mask `v / (v + 2a)`, ported from ieasybooks/musicless. The processor's worker keeps only the full-size (512-frame) one between windows; the small ramp sizes are built per use (~22 MB saved). |
| `MusiclessAudioSink` | Feeds the processor outside Media3's synchronous loop, writes finished voices to the AudioTrack (also from `hasPendingData()`, so they play even when no new input arrives), and reports a **hold** while voices aren't ready. |
| `MusiclessHold` | Tells the player screen about holds; it shows "Preparing voices…" and keeps the clock from running ahead. A 100 ms debounce ignores short AudioTrack gaps. |
| `MusiclessDownloadGate` | Pauses playback while the model downloads, without losing the user's play/pause choice. |

Where it plugs into the app:

- `Media3PlayerInitializer.buildAudioSink` builds `MusiclessAudioSink` when the switch is on. The
  sink is part of the player, so changing the switch **restarts the engine**
  (`MobilePlaybackActivity.restartEngine`): from Settings on resume, or from the player's gear menu
  row "Remove music" (`openPlayerMenu`).
- `MobileMainApplication.onCreate` starts the model download at launch when the switch is on.

Known behaviour and limits:

- All voices are kept, singing included. Percussion (daff) is mostly removed.
- On the x86_64 emulator, timing is too noisy for A/B tests; measure on a real phone. The logcat
  tag `Musicless` prints `Window pipeline ms=… frames=…` per window.
- One short stall (≈0.5 s on the emulator) can happen right after start if input arrives slower
  than ~4× real time; marked with a `shortcut:` comment in `MusiclessAudioProcessor`.
- Live streams are untested.

### The models

- Source: Deezer Spleeter 2-stem, as exported to ONNX by k2-fsa/sherpa-onnx
  (`sherpa-onnx-spleeter-2stems.tar.bz2`).
- `tools/musicless/prepare_models.py ORIGINAL_DIR` makes the frame dimension symbolic and stores
  weights as fp16 (arithmetic stays fp32), writing gzip files + `SHA256SUMS` to
  `tools/musicless/dist`. Output hashes (decompressed) are pinned in `MusiclessModels.HASHES` and in
  `smarttubetv/src/stmobile/assets/musicless/NOTICE.txt`.
- They're hosted as assets of the **pre-release** `musicless-models-v1` (pre-release so it never
  becomes "latest" and hides the app releases). A new model needs a new tag (e.g.
  `musicless-models-v2`), new hashes in `MusiclessModels`, and the new URL in `MODELS_URL` of the
  release workflow.

## The fork build

All fork differences are switched on by Gradle properties, so a plain build is still exactly
NewTube (and its F-Droid twin stays byte-identical):

| Property | Effect |
|:--|:--|
| `-PforkAppId=io.github.yshalsager.newtube.musicless` | App id, name "NewTube Musicless", emerald icon (`smarttubetv/src/musicless/res`, release only), `BuildConfig.MUSICLESS_FORK` in the app and `common` |
| `-PforkBuild=N` | `versionCode = upstream code × 100 + N`, `versionName = <upstream>-musicless.N` |
| `-PforkUpdateUrl=…/releases/latest/download/musicless.json` | The in-app updater's feed; without it the fork build has no updater |
| `-PmusiclessModelBaseUrl=…/releases/download/musicless-models-v1` | Where the models are downloaded from |

What `MUSICLESS_FORK` changes (new installs only; anything the user picks wins):

| Where | Default |
|:--|:--|
| `MusiclessPrefs.isOn` | Remove music on |
| `DeArrowData` | Thumbnails from the video, not the uploader's |
| `PlayerTweaksData` | Up next suggestions hidden |
| `PlayerData` | Pause when a video ends |
| `MobileMainApplication.onCreate` | First run (no language ever chosen): Arabic UI, Home tab off, start on Subscriptions |
| `AppUpdates.manifestUrls` | Read `forkUpdateUrl` instead of NewTube's feed |

## Releasing

Releases are built by **`.github/workflows/musicless-release.yml`** when a tag
`v<upstream version>-musicless.<N>` is pushed:

```
git tag -a v1.17.1-musicless.2 \
  -m "Fixes the start stall" \
  -m "ar: يصلح التوقف عند بدء التشغيل"
git push <fork remote> v1.17.1-musicless.2
```

1. It checks that the tag's base version matches `versionName` in `smarttubetv/build.gradle`.
2. Builds all APKs with the fork properties, signed from the `musicless-release` environment
   secrets (`MUSICLESS_KEYSTORE_BASE64`, `MUSICLESS_KEYSTORE_PASSWORD`, `MUSICLESS_KEY_ALIAS`; the
   environment only accepts `v*-musicless.*` tags).
3. Checks each APK's name, app id, versionCode and that it's signed with certificate
   `1490631944f31de3697ef4df013971d729adfa3c888c4a5360d57e4c5b29f741`.
4. Writes `SHA256SUMS` and `musicless.json` (`tools/musicless_manifest.py`), attests every file,
   and attaches them to a **draft** release. Tag-message lines become the notes: `ar: ` lines are
   Arabic (release notes and the app's `changelog_ar`), the rest English.
5. You check the draft APK on a phone, then **publish it as a normal release** (not a pre-release:
   the updater reads `releases/latest`).

The keystore is the only thing that can't be recreated: back it up. Losing it means users must
uninstall to move to a new key. Upstream NewTube's `release.yml` ignores `*-musicless.*` tags.

In the fork's Actions settings, NewTube's `discord`, `virustotal_scan`, `update-feed`, `stale`,
`pages` and `cleanup` workflows are disabled: release events run workflow files from `main`
(NewTube's), and those would post to NewTube's channels or fail.

## Keeping up with NewTube

1. Fetch NewTube's new release tag and merge (or rebase) it into `musicless`.
   Conflicts are most likely in `MobilePlaybackActivity`, `Media3PlayerInitializer`,
   `MobileMainApplication`, `smarttubetv/build.gradle` and the `values-ar` files.
2. Restart the fork build number at 1: `v1.17.2-musicless.1` → versionCode `1170201`, which is
   above every `1.17.1-musicless.N`, so updates keep working.
3. New phone strings arrive in English only: translate the missing Arabic ones (compare
   `values/` with `values-ar/` in `smarttubetv/src/stmobile/res` and `common/src/main/res`).
4. Run the Musicless tests and a device check before tagging:
   `./gradlew :smarttubetv:testStmobileDebugUnitTest --tests 'com.newtube.mobile.player.Musicless*'`.

## Building locally

See [docs/BUILDING.md](../BUILDING.md); JDK 21, Android SDK, NDK `21.0.6113669` (needed to strip
native libraries; without it the APK is ~10 MB larger). A local fork release:

```
./gradlew :smarttubetv:assembleStmobileRelease \
  -PforkAppId=io.github.yshalsager.newtube.musicless -PforkBuild=1 \
  -PforkUpdateUrl=https://github.com/yshalsager/newtube-musicless/releases/latest/download/musicless.json \
  -PmusiclessModelBaseUrl=https://github.com/yshalsager/newtube-musicless/releases/download/musicless-models-v1
```

Without a `keystore.properties` the release APKs come out unsigned.

## Ideas not done yet

- A smaller ONNX Runtime (a custom build with only this model's operators) to cut the ~35 MB.
- A gentler start ramp (64, 64, 128, …) if the start stall shows on phones.
- Measuring battery and per-window time on a range of real phones.

## Credits

- **[NewTube](https://github.com/aleixrodriala/newtube)** by @aleixrodriala and contributors: the
  phone app this fork is.
- **[SmartTube](https://github.com/yuliskov/SmartTube)** by @yuliskov and contributors: the YouTube
  engine under NewTube.
- **[Musicless](https://github.com/ieasybooks/musicless)** by الكتب المُيسّرة (ieasybooks), MIT: the
  idea and the method; the voice mask and DSP were ported from commit `957acc1b`.
- **[Spleeter](https://github.com/deezer/spleeter)** by Deezer, MIT: the separation model.
- **[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)** by k2-fsa: the ONNX export of Spleeter.
- **[ONNX Runtime](https://github.com/microsoft/onnxruntime)** by Microsoft, MIT: inference on the
  phone.

License texts shipped in the app: `smarttubetv/src/stmobile/assets/musicless/`
(`LICENSE-Musicless`, `LICENSE-Spleeter`, `LICENSE-ONNXRuntime`, `ThirdPartyNotices-ONNXRuntime.txt`,
`NOTICE.txt`).
