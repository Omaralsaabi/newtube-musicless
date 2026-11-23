# Musicless / NewTube feasibility prototype

Status: **opt-in withheld-audio prototype, not ready to ship**. Output is now
sample-aligned, with no startup padding or duplicated EOF overlap. Ordinary VOD
holds work by source inspection, but **EOF can bypass the hold**, so withholding
alone is not a complete A/V sync solution. Android sync, memory and energy remain
unmeasured.
No account, API, network, live-stream or Cast behavior was changed.

## Source and exact pipeline

Inspected https://github.com/ieasybooks/musicless at
`957acc1bd251a80f8d31639d8da6fd512cc4d2ab`, cloned outside this worktree at
`/tmp/newtube-musicless-source`. Authoritative files: `extension/{grid,dsp,model}.js`,
`tools/build_model.py`, `tests/reference.py`, and `docs/how-it-works.md`.

| Item | Exact value / behavior |
| --- | --- |
| Download | `sherpa-onnx-spleeter-2stems.tar.bz2` from k2-fsa/sherpa-onnx source-separation-models release; archive SHA-256 `e26401d9c1801f43c0229731d78d32c2e80085e3aceedeb25f29d2de5fa68ca2` |
| Original files | `vocals.onnx` 39,318,336 bytes; `accompaniment.onnx` 39,318,343 bytes; both networks merged, not just the vocal network |
| Packaged file | `spleeter-2stems.onnx`, 39,364,042 bytes (37.540 MiB); SHA-256 `3dc5eaf764fc3c12daa4b69a295be426eb0870dbd400afe09c18d0f66e3a50de`, identical to Musicless's pin |
| Weight / compute precision | fp16 stored weights, Cast to fp32; **fp32 arithmetic**, not a native half-precision execution graph |
| Full-weight comparison graph | Same merge without fp16 conversion, 78,639,452 bytes (74.996 MiB) |
| Input | `x`: float32 `[2, num_splits, 512, 1024]`; extension supplies `[2,1,512,1024]`, channel / split / frame / bin |
| Output | `mask`: float32, same shape as input; mask, **not** PCM |
| Sample rate / channels | 44,100 Hz stereo; extension windowed-sinc resampler uses 32 taps, 512 phases and cutoff `min(1,44100/fromRate)*0.97` |
| Window | 524,288 samples = 11.888617 s; zero-pad unavailable audio at final window |
| Grid / overlap | Starts at `k*522240` samples from media time zero; stride 11.842177 s, overlap 2,048 samples = 46.43991 ms |
| STFT | n_fft=4096, hop=1024, periodic Hann; centered, reflect padding of 2048 each side; unnormalized forward FFT |
| Spectrum | Analyze 513 frames; network sees first 512 frames and bins 0..1023 (last bin 11,014.453125 Hz); discard bins 1024..2048 |
| Level | Stereo-window RMS; magnitude gain `clip(10^(-24/20)/(RMS+1e-9), 10^(-30/20), 10^(30/20))`; original complex spectrum retains its original level |
| Mask | `(v + 1e-10/2)/(v + 2*a + 1e-10)` from the two networks' magnitude estimates; no squared Wiener mask |
| Reconstruction | Multiply original complex spectrum by mask, retain mixture phase; frame 513 repeats frame 512's mask; all higher bins zero; inverse FFT /4096, Hann overlap-add divided by sum(Hann^2) where >1e-11 |
| Stitching | First window has no fade-in; subsequent heads multiply by `(i+0.5)/2048`; every window tail multiplies by `1-(i+0.5)/2048`; add overlapping tails/heads, truncate to original duration |
| Browser timing | Browser holds the **video** while audio is missing, waits for >=3 s ready, and schedules vocals against the video clock; this prototype instead withholds PCM and relies on Media3 readiness/buffering (limitations below) |

## Offline benchmark

Host: Linux x86_64, AMD Ryzen 5 3600 (6 cores / 12 hardware threads), 62 GiB RAM.
Python 3.11.10, NumPy 2.4.6, ONNX Runtime CPU 1.32.0, sequential graph execution,
inter-op threads=1, `num_splits` fixed to 1 as in the extension. Each row is one new process and one 60 s run, including STFT,
model inference, iSTFT, and crossfade over six windows. RTF = processing seconds /
60 s (smaller is better); loading is measured separately and excluded from RTF.
These are not Android, Java, battery, or sustained thermal measurements.

Input: Musicless's deterministic `tests/synth.py` generated 60 s of formant voice
plus piano/bass/drums, 44.1 kHz stereo PCM16, music level -12 dB relative to voice.
WAV SHA-256 `cbed2d91cd619515709e3f040e20ab0b38e9a7887bd5976d260fb7e02fb621bc`.
**Synthetic speech/music, not evidence of subjective quality on real speech.**

| Graph | Intra-op threads | Model load s | Complete pipeline s | RTF | Peak process RSS MiB | SDR vs full-fp32 vocals |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Full fp32 weights | 1 | 0.1945 | 2.9076 | 0.04846 | 839.24 | reference |
| Full fp32 weights | 4 | 0.2140 | 1.6984 | 0.02831 | 838.89 | not compared |
| Musicless fp16-stored weights | 1 | 0.1887 | 2.8844 | 0.04807 | 830.45 | 77.371 dB |
| Musicless fp16-stored weights | 4 | 0.1936 | 1.7198 | 0.02866 | 834.61 | 77.371 dB |

RSS is Linux `ru_maxrss`, **whole process peak**, including NumPy's large
reference STFT allocations, model loading and ORT arenas; it is not model-only
memory or an Android heap prediction. First-use inference is included, no
warm-up exclusion. No Gradle build was running during these final measurements;
these are single trials, not a statistically repeated benchmark. The browser uses
ORT Web 1.30.0 WASM parallel graph planning with one thread; desktop and Android
use native ORT 1.32.0 sequential graph planning, with the same numerical pipeline. The stored-half variant halves
the file size with negligible waveform deviation in this fixture, but does not
save runtime arithmetic or substantially reduce RSS. No extra int8 or native
fp16 compute graph was attempted; Conv-heavy int8 support and speech fidelity
would need a separate evaluation, not an unverified speed claim.

### Reproduction commands

All downloaded/generated benchmark inputs are outside the repository:

```sh
git clone https://github.com/ieasybooks/musicless /tmp/newtube-musicless-source
git -C /tmp/newtube-musicless-source checkout 957acc1bd251a80f8d31639d8da6fd512cc4d2ab
uv venv /tmp/musicless-bench/venv
uv pip install --python /tmp/musicless-bench/venv/bin/python \
  numpy==2.4.6 onnx==1.23.2 onnxruntime==1.32.0 soundfile==0.14.0
curl -fL https://github.com/k2-fsa/sherpa-onnx/releases/download/source-separation-models/sherpa-onnx-spleeter-2stems.tar.bz2 \
  -o /tmp/musicless-bench/spleeter.tar.bz2
mkdir -p /tmp/musicless-bench/spleeter
tar -xjf /tmp/musicless-bench/spleeter.tar.bz2 -C /tmp/musicless-bench/spleeter --strip-components=1
/tmp/musicless-bench/venv/bin/python /tmp/newtube-musicless-source/tools/build_model.py \
  /tmp/musicless-bench/spleeter /tmp/musicless-bench/spleeter-2stems.onnx
/tmp/musicless-bench/venv/bin/python /tmp/newtube-musicless-source/tests/synth.py \
  /tmp/musicless-bench/clip60.wav 60
# Build the same merged graph without converting original fp32 weights to fp16:
/tmp/musicless-bench/venv/bin/python - <<'PY'
s = open('/tmp/newtube-musicless-source/tools/build_model.py').read()
s = s.replace('if init.data_type == onnx.TensorProto.FLOAT and len(init.dims) > 1:', 'if False:')
open('/tmp/musicless-bench/build_fp32.py', 'w').write(s)
PY
/tmp/musicless-bench/venv/bin/python /tmp/musicless-bench/build_fp32.py \
  /tmp/musicless-bench/spleeter /tmp/musicless-bench/fp32.onnx
for threads in 1 4; do
  OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 /tmp/musicless-bench/venv/bin/python \
    tools/musicless/benchmark.py /tmp/musicless-bench/fp32.onnx \
    /tmp/musicless-bench/clip60.wav --threads "$threads" \
    --output /tmp/musicless-bench/fp32-$threads.npy
 done
for threads in 1 4; do
  OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 /tmp/musicless-bench/venv/bin/python \
    tools/musicless/benchmark.py /tmp/musicless-bench/spleeter-2stems.onnx \
    /tmp/musicless-bench/clip60.wav --threads "$threads" \
    --output /tmp/musicless-bench/fp16-$threads.npy \
    --compare /tmp/musicless-bench/fp32-1.npy
 done
```

The vendored `tools/musicless/reference.py` is Musicless's unmodified reference,
under its included MIT license. `benchmark.py` adds explicit thread settings,
load/elapsed/RSS measurements, shape/finite checks and the SDR comparison.
Raw JSON measurements remain at `/tmp/musicless-bench/{fp32,fp16}-{1,4}.json`.

## Hold/backpressure follow-up: Media3 1.10.1 source audit

Sources: Maven `media3-exoplayer-1.10.1-sources.jar` and
`media3-common-1.10.1-sources.jar`, extracted at
`/tmp/musicless-bench/media3-src/`. Paths below are relative to that root;
upstream tag: https://github.com/androidx/media/tree/1.10.1/libraries.

**Verdict: ordinary VOD holds are supported; the unconditional audio-master
hypothesis is refuted.** In particular, a short clip decoded to EOF before its
first inference completes can let video run on the standalone clock while waiting
for vocals. No claim is made that this follow-up alone fixes that case; a renderer/
player-level hold or a predecoded source is still needed. This is source evidence
plus a real-library clock-selection unit check, not an on-device sync result.

- `androidx/media3/exoplayer/audio/DefaultAudioSink.java:726-733`: before output
  initialization it returns `CURRENT_POSITION_NOT_SET`; after initialization its
  position is clamped to **written** frames. Submitting decoded PCM to our worker
  does not advance that count. `MediaCodecAudioRenderer.java:789-800,1140-1152`
  defines readiness as `audioSink.hasPendingData()` and retains its prior media
  position when the sink has no position. `DefaultAudioSink.java:1301-1306,1878-1882`
  counts only frames still pending in the actual audio output, not inference work.
- `androidx/media3/exoplayer/ExoPlayerImplInternal.java:1407-1423,1446-1467`:
  unready renderers normally prevent READY; READY -> BUFFERING stops the renderers;
  `:1258-1259` explicitly stops the media clock. **Exception:**
  `RendererHolder.java:415-420` allows playback when `hasReadStreamToEnd()` even
  if the renderer is not ready/ended; `ExoPlayerImplInternal.java:2440-2452` can
  therefore enter READY when fully loaded. Thus EOF does not reliably buffer.
  `DefaultMediaClock.java:162-192,198-207` normally uses the audio renderer clock,
  but can switch to the standalone clock if the renderer ended, is reading ahead,
  or is unready and has read its stream to the end. Do **not** claim an invariant
  that video always follows AudioTrack at EOF, uneven track durations, or period
  transitions. The real-library unit test holds audio position at zero, advances
  wall time by 12 s and observes no media advance before EOF, then flips
  `hasReadStreamToEnd()` and observes the standalone position advance. Combined
  with `RendererHolder` above, this refutes the hold guarantee at EOF.
- `androidx/media3/exoplayer/audio/AudioTrackPositionTracker.java:226-280` can
  extrapolate/smooth timestamps; the sink's written-frame clamp is the decisive
  underrun bound. Its 200 ms stalled-track reset (`:120,297-301,508-523`) requires
  API <=29, a raw playback head that **reset to zero after being positive**, and
  written frames; ordinary starvation with an unchanged head is not that case.
  `DefaultAudioSink.java:1055-1059` resets such a genuinely stalled output.
  `AudioTrackAudioOutput.java:447-473` reports underruns, not an inference timeout.
  Startup now creates no AudioTrack until real output is available.
- The internal 4 s stuck-buffering watchdog
  (`ExoPlayerImplInternal.java:191-202,1469-1495`) requires NOT loading, <500 ms
  buffered, and more media possible. A completed 11.89 s window held for inference
  is still buffered media; a fully loaded short stream has no more loading possible.
  The generic buffering watchdog defaults to **600 s**, not 12 s
  (`ExoPlayer.java:231-250`); the 10 s playing watchdog (30 s emulator) is gated
  on `isPlaying()` (`common/util/StuckPlayerDetector.java:228-235`), so entering
  BUFFERING disarms it. No timeout needed disabling for a multi-second hold;
  genuine >10-minute hangs keep their error path. The app's separate 20 s
  `BufferingDetector` can lower video quality on very slow inference/network
  waits (`common/.../ErrorFixerController.java:157-187`); it is not a PCM padding
  or clock-reset path and is unchanged by this experiment.
- **Integration trap handled:** `DefaultAudioSink.java:1147-1162` loops while its
  pipeline has not ended, repeatedly queuing input without checking progress.
  `common/audio/AudioProcessingPipeline.java:332-367` itself handles zero progress,
  but the sink's outer loop does not. Installing an async, non-consuming processor
  *inside* the stock sink therefore busy-spins on a full queue (and can prevent
  seek/release). `MusiclessAudioSink` now runs this processor **before** the stock
  sink, returns `false` promptly on backpressure, polls asynchronous output on
  each renderer retry/EOS, and sends only real output with timestamps derived from
  its first input timestamp plus emitted frame count. No Media3 fork/reflection
  or blocking worker wait was added. Partial writes keep the same output buffer.

### Seek metadata and grid

`common/audio/AudioProcessor.java:136-161` exposes
`flush(StreamMetadata)` / `positionOffsetUs`: a window-aligned stream position,
current at flush time, not a timestamp on each `queueInput`. `BaseAudioProcessor.java:89-102`
forwards metadata to `onFlush(StreamMetadata)`; `AudioProcessingPipeline.java:175-190`
propagates position offsets between processors. However **DefaultAudioSink 1.10.1
calls `audioProcessingPipeline.flush()` without metadata** (`:830-832`), so the
legacy overload supplies `StreamMetadata.DEFAULT` (zero), not the seek position.
Our external processor also deliberately uses the default, flush-relative grid.
The sink wrapper sees buffer timestamps and `AudioSink.setOutputStreamOffsetUs`
(`audio/AudioSink.java:621-628`) can map renderer offsets, so a media-zero grid is
achievable with explicit plumbing. Exact browser-equivalent output after an
arbitrary seek also needs decoding/caching the preceding samples from that grid's
window start; changing an offset or zero-padding the missing prefix is not enough.
That separate pre-seek decode/cache path is intentionally not implemented.

### ORT arena/memory-pattern A/B

Same host, 60 s fixture, stored-fp16 graph and one CPU thread as above; **three
fresh processes per setting**, sequential, no concurrent Gradle build. Added
`benchmark.py --arena-off`, which sets both `enable_cpu_mem_arena=False` and
`enable_mem_pattern=False`. Complete pipeline includes six STFT/inference/iSTFT
windows and first-use inference; RSS still includes the whole Python process.

| Setting | Pipeline s (3 runs) | Peak RSS MiB (3 runs) | Median pipeline s | Median peak RSS MiB |
| --- | --- | --- | ---: | ---: |
| Default | 3.0251 / 3.0057 / 3.0078 | 834.41 / 830.35 / 834.45 | 3.0078 | 834.41 |
| Arena off + memory pattern off | 3.6199 / 3.5907 / 3.5616 | 559.36 / 560.93 / 561.16 | 3.5907 | 560.93 |

Arena-off saves **273.47 MiB (32.8%)** median peak RSS but is **19.4% slower**,
exceeding the requested <10% speed penalty. Therefore Java retains defaults;
`SessionOptions.setCPUArenaAllocator(false)` and
`setMemoryPatternOptimization(false)` exist in ORT Java 1.32.0, but are deliberately
not applied. Android speed/RSS might differ; re-evaluate there before shipping.
Model path loading is applied independently and avoids both Java model-byte copies.

```sh
for mode in default off; do
  for run in 1 2 3; do
    flag=; [ "$mode" = off ] && flag=--arena-off
    OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 /tmp/musicless-bench/venv/bin/python \
      tools/musicless/benchmark.py /tmp/musicless-bench/spleeter-2stems.onnx \
      /tmp/musicless-bench/clip60.wav --threads 1 $flag \
      --output /tmp/musicless-bench/memory-$mode-$run.npy \
      > /tmp/musicless-bench/memory-$mode-$run.json
  done
done
```

## Minimal NewTube integration

- `Media3PlayerInitializer.PrerollRenderersFactory.buildAudioSink` checks
  **debug build only** `debug.arc.remove_music=1`; unset is the original sink.
- Uses `MusiclessAudioSink` around `DefaultAudioSink`, with the asynchronous
  `MusiclessAudioProcessor` **outside** the stock sink's synchronous processor loop
  (otherwise full-queue backpressure spins the playback thread; see source audit).
  Disables float output, refuses encoded/non-PCM16/>2-channel sink formats to prevent
  passthrough/bypass, reports offload unsupported and forces its mode disabled.
  Existing Opus pre-roll renderer stays.
- Buffers decoded mono/stereo PCM16, converts to stereo 44.1 kHz, analyzes on one
  dedicated worker with ORT Android 1.32.0 CPU / one intra-op thread, reconstructs
  masked PCM and stitches windows. At most **two outstanding windows total**
  (running/queued/completed) are retained. Full capacity leaves input bytes
  unconsumed, without failure or silence. Startup and inference waits return empty
  output; model/load/inference/native failures log `Musicless` and output exactly
  the remaining accepted duration as silence, never the original mixture.
- Flush increments a generation and discards queued/playing vocals so stale work
  cannot cross seeks; reset queues session close on its owner thread and shuts
  down that executor. EOF zero-pads the last window and drains only the original
  duration, including the retained overlap once (not a duplicate overlap).
- ORT Java accepts a filesystem path: copy the bundled model atomically to a
  versioned cache file once, then load by path, avoiding `ByteArrayOutputStream`
  plus `toByteArray()` copies. Cache eviction causes a new copy; copy/load errors
  remain fail-closed. Cache filename pins the bundled model hash prefix.
- The model is bundled in stmobile assets (with provenance/licenses), so the
  experimental path makes no model-download request; ORT telemetry is disabled.
  Prototype model/dependency packaging is unconditional for stmobile, including
  release APKs even though only debug builds can enable processing.

Enable/disable on a **selected test device**, then recreate the player (force-stop
is the simplest way; existing players retain their original sink):

```sh
adb -s <serial> shell setprop debug.arc.remove_music 1
adb -s <serial> shell am force-stop io.github.aleixrodriala.arc.debug
# launch the debug app and a VOD
adb -s <serial> logcat -d > /tmp/musicless-logcat.bin
grep -a Musicless /tmp/musicless-logcat.bin
# restore normal playback:
adb -s <serial> shell setprop debug.arc.remove_music ''
adb -s <serial> shell am force-stop io.github.aleixrodriala.arc.debug
```

Package suffix is `.debug` on this machine because there is no release keystore;
with the release keystore configured, use `io.github.aleixrodriala.arc` instead.
Do not use this switch to claim live or Cast support.

### Checks and deliberate limitations

The Java DSP was cross-checked on a stereo 440/880 Hz deterministic window
against the Python reference: maximum magnitude absolute error `7.6293945e-6`,
maximum reconstructed-sample absolute error `8.3320619e-10` with a frequency-ramp
mask. Pure-Java unit checks cover unity-mask reconstruction, zero-mask silence,
and complementary overlap weights; Robolectric checks cover 48->44.1 kHz sample
count, no output before window/worker completion, bounded input backpressure,
flush/reset with stale work (including repeated seeks without accumulating jobs),
logged-error silence with exact duration, the opt-in
sink's passthrough/offload rejection, and non-spinning sink backpressure with
sample-count-based presentation timestamps. Identity-worker output matches every
input sample within one PCM16 quantization count across multiple windows and EOF;
a unity-mask DSP stub matches the same sample indices within 250 PCM16 counts
(low-pass/reflect-boundary tolerance, smooth EOF fixture), with identical total length.
These checks **do not** execute ORT Android JNI or prove device playback.

- **A/V sync remains device-unverified, not knowingly offset by a window.** No
  PCM is written until separated sample zero is ready. For ordinary VOD the audio
  renderer is not ready and the player buffers, stopping its renderers/clock;
  mid-stream starvation similarly buffers after the written PCM drains **unless
  the renderer has read EOF**. EOF/read-ahead can allow playback and select the
  standalone clock, letting video advance without vocals (including short clips).
  No independent video-hold layer was added or claimed verified; this source-proven
  remaining sync gap needs a separate renderer/player-level solution.
- **Seek repeatability differs.** Flush drops old-generation output and restarts
  the grid at the seek position, unlike Musicless's media-zero grid. Media3 does
  expose `StreamMetadata.positionOffsetUs`, but its stock sink supplies zero;
  timestamps alone cannot provide the pre-seek samples for the enclosing window
  (see audit). Resume/track/speed/format transitions require real-player verification.
- **Resampling differs.** Java uses streaming linear interpolation, not the
  extension's windowed-sinc resampler. DSP/model processing at 44.1 kHz matches;
  48 kHz Opus input quality near Nyquist is not an exact browser match.
- **Look-ahead** is 11.89 s of *decoded media*, plus inference, not necessarily
  11.89 s of wall time: decoding/network may run faster than playback. Short videos
  wait for EOF before separation. No custom progress UI was added; buffering is
  the existing player surface.
- **Battery/thermal** unmeasured. One CPU thread, no NNAPI/GPU, still allocates
  spectra/windows and loads both U-Nets. Do not infer energy from desktop RTF.
- **Phone RTF estimate only:** if a phone core is 3-10x slower than this desktop
  pipeline, stock model RTF would be ~0.15-0.49 (15-49% of one core); a weak/little
  core, Java FFT overhead, throttling or contention could exceed 1.0. This is a
  sensitivity estimate, **not** a measured device forecast.
- **RAM and APK size** are material; Android ORT arenas, fp32-expanded weights,
  model-byte loading and simultaneous playback can cause OOM/LMK on low-RAM
  devices. Path loading removes Java model copies, not ORT's working set. The
  arena-off measurement below saves RSS but misses the requested speed budget,
  so Java retains default arena/memory-pattern settings. Only native ABI builds
  carrying ORT can work.
- Model processing/fail-closed paths are experimental; unsupported decoded
  formats (>2 channels/non-PCM16) are rejected rather than played unprocessed.

Emulator skipped: `/dev/kvm` and `~/Android/Sdk/emulator` exist, but
`emulator -list-avds` returns no AVD and there are no installed system images or
SDK cmdline-tools. Provisioning/running a new Android harness was not necessary
for the required desktop pipeline measurement and was kept out of this prototype.

## Build and APK-size evidence

**PASS**, follow-up clean debug build and **12/12 focused tests**, zero failures/errors
(10 processor/sink/clock + 2 DSP; no ORT Android JNI/device execution):

```sh
ANDROID_HOME=$HOME/Android/Sdk \
JAVA_HOME=$HOME/.local/share/mise/installs/java/openjdk-21.0.2 \
nice -n 10 ./gradlew -Dorg.gradle.workers.max=2 \
  :smarttubetv:clean :smarttubetv:assembleStmobileDebug \
  :smarttubetv:testStmobileDebugUnitTest \
  --tests 'com.newtube.mobile.player.Musicless*' --console=plain
# BUILD SUCCESSFUL in 28s
# 242 actionable tasks: 48 executed, 194 up-to-date
```

Baseline: same worktree/base commit, prototype temporarily stashed, same JDK/SDK,
`:smarttubetv:clean :smarttubetv:assembleStmobileDebug` (**PASS**, 17 s).
Both baseline and final candidate were clean builds: incremental APK packaging
can leave ZIP holes after removing large entries and yields a bogus size delta.
No push, PR, release, install, account reset or submodule-pointer change was made.
There are no unresolved build blockers; existing Gradle-10 deprecation,
annotation/manifest warnings and unavailable native-symbol stripping are nonfatal.

| ABI | Clean baseline bytes | Prototype bytes | Delta bytes | Delta MiB |
| --- | ---: | ---: | ---: | ---: |
| arm64-v8a | 71,496,795 | 144,556,430 | +73,059,635 | +69.675 |
| armeabi-v7a | 60,194,063 | 122,716,734 | +62,522,671 | +59.626 |
| x86 | 70,114,191 | 150,172,982 | +80,058,791 | +76.350 |
| universal | 102,219,333 | 201,196,564 | +98,977,231 | +94.392 |

Final distributable paths (the project's rename task uses `renamed_apks`, not
`outputs/apk`; raw AGP APKs also exist under `outputs/apk/stmobile/debug`):

- `smarttubetv/build/outputs/renamed_apks/stmobileDebug/NewTube_1.17.1_arm64-v8a.apk` — **144,556,430 bytes / 137.860 MiB**.
- `smarttubetv/build/outputs/renamed_apks/stmobileDebug/NewTube_1.17.1_universal.apk` — **201,196,564 bytes / 191.876 MiB**.

In the arm64 APK, the model contributes 36,491,806 compressed bytes;
`libonnxruntime.so` 36,307,784 uncompressed bytes and
`libonnxruntime4j_jni.so` 122,192 uncompressed bytes, plus Java/dex, licenses,
alignment/signature changes. Universal adds ORT native libraries for multiple ABIs.
Copies of the clean baseline APKs are at `/tmp/musicless-bench/baseline-apks`.

Follow-up build log: `/tmp/musicless-hold-final-build.log` (clean build + all
12 tests pass); interim test compilation used an unsupported covariant
`ByteBuffer.flip()` return, corrected before final verification. The unity-mask
fixture originally had an abrupt EOF discontinuity; smoothing its last 4096
samples avoids comparing low-pass ringing against a discontinuous original.
Additional tests cover repeated-flush queue bounds and sink timestamp/backpressure.
Original packaging logs: `/tmp/musicless-candidate-build.log`,
`/tmp/musicless-clean-baseline-build.log`, `/tmp/musicless-final-build.log`.
The APK-size table above is the original commit's baseline/prototype comparison,
not a second baseline size benchmark for this follow-up.
Test XML: `smarttubetv/build/test-results/testStmobileDebugUnitTest/TEST-com.newtube.mobile.player.Musicless{AudioProcessor,Dsp}Test.xml`.
`git diff --check` also passed.

Initial cold dependency build began before the prototype was configured and then
saw the newly added source files; that transient compile failed with missing
`ai.onnxruntime` imports. Re-running with the declared ORT dependency compiled
and built the debug APK successfully; it is not an unresolved blocker.
