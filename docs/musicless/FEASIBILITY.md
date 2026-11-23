# Musicless / NewTube feasibility prototype

Status: **opt-in delayed-audio prototype, not ready to ship**. Desktop CPU headroom
looks promising; Android playback timing, memory and energy have not been measured.
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
| Browser timing | Browser holds the **video** while audio is missing, waits for >=3 s ready, and schedules vocals against the video clock; this prototype deliberately does not implement that independent clock/hold layer |

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

## Minimal NewTube integration

- `Media3PlayerInitializer.PrerollRenderersFactory.buildAudioSink` checks
  **debug build only** `debug.arc.remove_music=1`; unset is the original sink.
- Uses `DefaultAudioSink` + `MusiclessAudioProcessor`, disables float output,
  refuses encoded sink formats to prevent passthrough/bypass, reports offload
  unsupported and forces its mode disabled. Existing Opus pre-roll renderer stays.
- Buffers decoded mono/stereo PCM16, converts to stereo 44.1 kHz, analyzes on one
  dedicated worker with ORT Android 1.32.0 CPU / one intra-op thread, reconstructs
  masked PCM and stitches windows. At most two inference jobs and two completed
  windows are queued; overload/model/load/inference/native failures log
  `Musicless` and output silence, never the original mixture.
- Flush increments a generation and discards queued/playing vocals so stale work
  cannot cross seeks; reset queues session close on its owner thread and shuts
  down that executor. EOF zero-pads the last window and drains delayed vocals.
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
count, no original-audio leakage during startup, flush/reset, and the opt-in sink's
passthrough/offload rejection.
These checks **do not** execute ORT Android JNI or prove device playback.

- **A/V sync is knowingly wrong.** Silence advances AudioTrack/media time until
  separated windows arrive, so vocals lag the picture by approximately a window
  plus processing/sink look-ahead; EOF drains that delayed tail. This proves the
  PCM/ORT seam, not a synchronized feature. A video hold plus correctly mapped
  media/audio clocks (or a separate predecoded/cache path) is required next.
- **Seek repeatability differs.** Flush drops old-generation output, but the
  processor cannot see absolute media timestamps; its window grid restarts at
  the seek position, unlike Musicless's grid from media zero. Resume/track/speed
  changes and EOS/format-transition draining require real-player verification.
- **Resampling differs.** Java uses streaming linear interpolation, not the
  extension's windowed-sinc resampler. DSP/model processing at 44.1 kHz matches;
  48 kHz Opus input quality near Nyquist is not an exact browser match.
- **Latency** is at least 11.89 s of decoded audio plus inference; short videos
  can have their vocals entirely in the delayed EOF tail. No UI recovery dialog,
  progress indicator, or clock compensation was added.
- **Battery/thermal** unmeasured. One CPU thread, no NNAPI/GPU, still allocates
  spectra/windows and loads both U-Nets. Do not infer energy from desktop RTF.
- **Phone RTF estimate only:** if a phone core is 3-10x slower than this desktop
  pipeline, stock model RTF would be ~0.15-0.49 (15-49% of one core); a weak/little
  core, Java FFT overhead, throttling or contention could exceed 1.0. This is a
  sensitivity estimate, **not** a measured device forecast.
- **RAM and APK size** are material; Android ORT arenas, fp32-expanded weights,
  model-byte loading and simultaneous playback can cause OOM/LMK on low-RAM
  devices. Only native ABI builds carrying ORT can work.
- Model processing/fail-closed paths are experimental; unsupported decoded
  formats (>2 channels/non-PCM16) are rejected rather than played unprocessed.

Emulator skipped: `/dev/kvm` and `~/Android/Sdk/emulator` exist, but
`emulator -list-avds` returns no AVD and there are no installed system images or
SDK cmdline-tools. Provisioning/running a new Android harness was not necessary
for the required desktop pipeline measurement and was kept out of this prototype.

## Build and APK-size evidence

**PASS**, final clean debug build and **4/4 focused tests**, zero failures/errors:

```sh
ANDROID_HOME=$HOME/Android/Sdk \
JAVA_HOME=$HOME/.local/share/mise/installs/java/openjdk-21.0.2 \
./gradlew :smarttubetv:clean :smarttubetv:assembleStmobileDebug \
  :smarttubetv:testStmobileDebugUnitTest \
  --tests 'com.newtube.mobile.player.Musicless*' --console=plain
# BUILD SUCCESSFUL in 19s
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

Raw logs: `/tmp/musicless-candidate-build.log`,
`/tmp/musicless-clean-baseline-build.log`, `/tmp/musicless-final-build.log`.
Test XML: `smarttubetv/build/test-results/testStmobileDebugUnitTest/TEST-com.newtube.mobile.player.Musicless{AudioProcessor,Dsp}Test.xml`.
`git diff --check` also passed.

Initial cold dependency build began before the prototype was configured and then
saw the newly added source files; that transient compile failed with missing
`ai.onnxruntime` imports. Re-running with the declared ORT dependency compiled
and built the debug APK successfully; it is not an unresolved blocker.
