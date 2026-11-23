# Musicless / NewTube feasibility prototype

**Opt-in prototype; not ready to ship.** Round 5 restores sink look-ahead and adds
per-window profiling; distribution/shared sessions/64-frame startup remain as in
round 4. The user reported good-sounding separation on a real phone; round 5 has
host-only verification, not fresh Android timing/sync/energy evidence.

## Round 5: look-ahead repair and decisive device diagnostics

**Confirmed starvation:** `MusiclessAudioSink.handleBuffer` returned immediately
when an earlier separated output could not fit in AudioTrack. Thus the processor's
bounded two-window queue was unreachable while that output played. Drain is now
best-effort before accepting input; the processor still enforces the two-window
bound (plus the sink's single pending output), so a full next window can be inferred
while the current output plays. Format/discontinuity changes still drain first.
This gate also existed in round 3; round 4 added visible underrun notifications,
so its presence alone does not establish when the measured regression began.
Hold accounting now includes output already handed from processor to sink but not
yet written; it previously could clear a hold before the first AudioTrack write.

**Regression checks:** reinstating the old early return makes both new look-ahead
tests fail: accepted-ahead bytes **0 instead of 4,177,920**, and **3 instead of 1**
hold entries over 50 simulated seconds. Fixed-latency 500 ms fake inference,
100 ms AudioTrack capacity and 10 ms playback steps now yield only the initial
hold. Another test checks pending-output hold accounting; cache cleanup preserves
unrelated files/directories and is idempotent. **37/37 Musicless tests and debug
assembly pass**, with the JDK 21 command below (without `clean`); logs:
`/tmp/musicless-r5-build.log`, negative control `/tmp/musicless-r5-regression.log`.

**The ~4x pipeline slowdown is NOT yet attributed or claimed fixed.** Existing
`inferMs` excludes executor queueing, download and session load. DSP is byte-identical
to round 3 and ORT options match. The holder serializes all session work; preload
is idempotent, idle release is delayed, and restart destroys/releases the old player
before creating its replacement. No new per-buffer main-thread posts were found:
hold publication posts only transitions. One 64-frame window occurs per flush,
then 512-frame windows; log frame ranges expose duplicates/extra flushes. No blind
thread/ORT/model tuning was applied without emulator evidence.

Exact per-window log (`Musicless` tag; milliseconds are integer wall time):

```text
Window pipeline ms=P processor=I generation=G window=N frames=64|512 outputStartFrame=S outputFrames=F queueMs=Q waitModelMs=L analyzeMs=A vocalsMs=V accompanimentMs=C maskMs=M synthesizeMs=Y otherMs=O cpuMs=T users=U thread=Musicless-ORT priority=R main=false
```

`P` excludes `Q` and `L`; the five stages plus `O` (scratch setup/tensor copies/
result disposal) account for P, up to integer rounding. `T` is owner-thread CPU,
not summed ORT helper-thread CPU. Each window has worker-owned timing fields,
unaffected by UI hold resets. `Q` reveals preload/trim/release/another processor
blocking the holder; `users` plus `Processor acquire|release processor=I users=U`
reveals overlapping players. Large analyze/synthesize with CPU near wall time
suggests Java execution/ART compilation; large ORT stages isolate native inference;
large wall/CPU gaps suggest scheduling contention (ORT helpers need separate care).
Thread priority is logged because the shared worker can be created from main during
preload, unlike the former playback-created worker. Check an equally compiled,
quiet-host A/B before blaming model format. Hold logs now separate `queueMs` from
`waitModelMs`; hold aggregates remain approximate, per-window logs are authoritative.

At application start, once per process, the downloader thread deletes only regular
`cacheDir/musicless-*.onnx` files (old bundled copies/temporary copies, ~78 MB);
current no-backup downloaded models are untouched. No device was modified; emulator
confirmation of restored look-ahead and stage timings remains with the coordinator.

## Round 4: distribution and implementation background

### Distribution and download

`prepare_models.py ORIGINAL_SHERPA_DIR` writes deterministic gzip assets, raw models
and `SHA256SUMS` (hashes the **decompressed** models) to gitignored
`tools/musicless/dist/`. Both independent U-Nets have symbolic frame dimensions,
fp16-stored weights and Cast-to-fp32 nodes; arithmetic/input/output remain fp32.
Licenses/notices remain packaged; no `.onnx`/`.ort` weights remain in the APK.
Nothing was uploaded. Upload **both `.onnx.gz` files**, retaining these names, to a
GitHub release, then build with `-PmusiclessModelBaseUrl=https://github.com/OWNER/REPO/releases/download/TAG`.
The stmobile BuildConfig default is empty: the UI explicitly says the download is
unconfigured, rather than pretending separation is ready.

| File | Raw bytes | Gzip bytes | SHA-256 of decompressed model |
| --- | ---: | ---: | --- |
| vocals.onnx | 19,674,133 | 18,178,677 | `f6fce89a06c9a98846e1b38e45dcd79ade2c256c3ce11119b33474da726be552` |
| accompaniment.onnx | 19,674,140 | 18,184,389 | `5e3f3048bf2936658a9ab3a9742b2e24765a06cc6c6c7de638aa93ea86330a45` |

Transport SHA-256: `vocals.onnx.gz` =
`176026ff131754db3595782b775dcec087ee8d851648c03f515b80e89c4b9a52`;
`accompaniment.onnx.gz` = `4db10757d59b6c4ca2794143b53b30affca4b326e25fd4ae61d5331ec7f072c8`.
`SHA256SUMS`: 163 bytes, SHA-256 `f91fdee54dbbd362fba4c3f06505ff4ca47327bb03303bf3a531b64bb3da12b7`.
Combined transport: **36,363,066 bytes / 34.68 MiB** (settings: “35 MB”). Singleton
`MusiclessModels` uses a background HttpURLConnection downloader, Range resumes of
`noBackupFilesDir/musicless/<name>.part`, gzip extraction, SHA verification and
atomic rename to hash-versioned final names. Interrupted network transfers retain
`.part`; corrupt gzip/SHA failures delete partial/extraction files. HTTP 200 after a
Range request restarts safely; 416 attempts verification of the saved complete gzip.
Listeners/progress/errors run on main, with a settings retry action. Switching off
keeps downloads/files. **Skipped Delete voice model:** safely coordinating deletion
with an active shared session/download is not a trivial settings-only action.

### Load, memory and first-window measurements

Same host/fixture as round 3, three fresh processes per format, BASIC/intra=2/inter=1,
arena/pattern/spinning off. RSS is whole-process peak across the 60 s DSP run, not
Android memory or session-only memory; values vary with host allocator/load.

| Format | Session load ms (three runs) | Median ms | Peak RSS MiB (three runs) | Output SDR vs fp32 |
| --- | --- | ---: | --- | ---: |
| fp32 ONNX | 122.77 / 124.63 / 123.64 | 123.64 | 485.26 / 483.30 / 483.27 | reference |
| **fp16-stored ONNX** | 129.09 / 132.45 / 136.06 | **132.45** | **493.04 / 484.96 / 485.76** | **73.20 dB** |
| fp16-source ORT, Fixed conversion | 172.09 / 173.19 / 171.27 | 172.09 | 487.38 / 495.06 / 511.74 | 73.20 dB |

**Coordinator-approved choice: fp16-stored ONNX**, despite fp32 loading ~9 ms faster:
that difference is tiny beside halving the download. Median RSS 485.76 MiB is +7.95%
versus the 450 MiB round-3 reference, within the +10% gate; SDR clears 40 dB. ORT is
slower and its median/one run misses the memory gate. Desktop loading is ~130 ms;
phone delays are more plausibly input collection, first inference, or repeated
per-player session loading than serialization format. Raw trials are in
`/tmp/musicless-bench/r4/{fp32,half,ort}-*.json`; conversion used
`python -m onnxruntime.tools.convert_onnx_models_to_ort tools/musicless/dist --optimization_style Fixed --output_dir /tmp/musicless-bench/r4/ort`.
`benchmark.py --extension ort` selects the converted files; other flags match round 3.

`short_window.py` now also measures 64 frames. Selected half ONNX: first-window
DSP+inference **43.17 / 43.54 / 41.99 ms**, median **43.17 ms**; SDR vs the same span
of 512 frames **18.82 dB** (>=15 dB). 128: 84.73 ms / 24.07 dB; full 512: 387.16 ms.
**64 accepted:** 65,536 input samples = **1.486 s** after each flush; subsequent
windows stay 512 frames. This remains synthetic-fixture, not general perceptual,
evidence. Reproduce with `short_window.py MODEL CLIP COPY --separate-models tools/musicless/dist`.

### Shared sessions, hold UI and download pause

One process-wide `MusiclessModelHolder` owns both sessions. All preload/inference/
close work uses one serial executor, so two processors cannot infer concurrently.
Player creation preloads immediately when files are ready, parallel to network
startup; acquisition completion also requests preload. Processor reset retains the
sessions; the last active processor release schedules disposal after 2 min, invalidated
by reuse. Memory pressure closes sessions on their owner thread; UI_HIDDEN retains
active playback and releases idle sessions. Next inference reloads if necessary.

The sink posts transition-only hold notifications (owner-token protected), including
clearing on seek/reset/release. The activity ORs a >300 ms hold with stock BUFFERING
and reuses the existing spinner/setup text: “Preparing voices…” or download progress/
error, with English/Spanish strings. It never hides stock BUFFERING on a Musicless
resume. The `Musicless` tag logs one line per finished/cancelled hold:
`hold reason=start|seek|underrun waitInputMs=.. waitModelMs=.. inferMs=.. totalMs=..`.
Model wait includes executor queueing/download/session load; input wait begins with
accepted PCM, not the upstream network request. Fields are diagnostic approximations
for an underrun overlapping already-submitted work, not a profiler trace.

**Downloads do not hold a running playback clock:** while the preference is on and
models are not READY (including failure/unconfigured), the activity sets real
playWhenReady=false. A small gate remembers user play intent and restores it on READY
only if the user has not paused. Play during acquisition records intent but stays
paused; touch/notification/headset/session pause routes preserve a later user pause.
This avoids applying the preexisting READY/no-progress watchdog to a long download.
Ordinary short inference holds are unchanged; no watchdog is disabled. Sink failures
still emit only silence, never original audio; failed acquisition can recover after
retry/READY without leaking music.

### Verification and remaining device checks

**PASS 33/33 Musicless tests**, zero skipped/failures/errors: 15 processor/sink/clock,
3 DSP, 5 downloader (resume, ignored Range, SHA cleanup, unconfigured, main listener),
4 holder singleton/idle/reuse/trim lifecycle, 1 main-thread hold publication, 5 pause-gate
intent decisions. Holder tests exercise lifecycle/scheduling without Android ORT JNI;
format/SDR/load measurements above exercise real host ORT. A clean build also passes:

```sh
ANDROID_HOME=$HOME/Android/Sdk \
JAVA_HOME=$HOME/.local/share/mise/installs/java/openjdk-21.0.2 \
nice -n 10 ./gradlew -Dorg.gradle.workers.max=2 \
  :smarttubetv:clean :smarttubetv:assembleStmobileDebug \
  :smarttubetv:testStmobileDebugUnitTest \
  --tests 'com.newtube.mobile.player.Musicless*' --console=plain
```

Final clean verification: 22 s; `/tmp/musicless-bench/r4/build.log`; `git diff --check` passes.
Arm64 **clean HEAD d2788ae baseline: 181,314,570 bytes -> 108,084,251 bytes**,
**73,230,319 bytes / 40.39% smaller**. The initially present incremental APK was
185,571,913 bytes; use the clean baseline for comparison. Final ZIP inspected: no
`.onnx`/`.ort` files; ORT/JNI and licenses remain packaged.

No device/emulator run, upload, push or PR. Still verify on a real phone: fresh/slow/
interrupted GitHub downloads and redirects, >10 s download without watchdog, SHA error
retry, pause/play/headset intent while downloading, restart/seek/off-toggle cleanup,
stock BUFFERING versus inference spinner transitions, warm engine restart/session
reuse, 2 min idle and memory trim, first-64-frame speech quality, A/V sync, long/EOF/
live/track transitions, RTF/RSS/thermal/battery. Ordinary inference holds >10 s retain
the existing watchdog risk. Linear resampling and flush-relative seek-grid limitations
from round 3 remain. The release URL must be configured and assets uploaded by the user.

## Round 3 historical record (superseded where round 4 differs)

## Pipeline and provenance

Musicless source: https://github.com/ieasybooks/musicless at
`957acc1bd251a80f8d31639d8da6fd512cc4d2ab` (`extension/{grid,dsp,model}.js`,
`tools/build_model.py`, `tests/reference.py`). `tools/musicless/reference.py` is its
unmodified MIT reference. Original downloads/fixtures live in `/tmp/musicless-bench`.

- Sherpa archive: https://github.com/k2-fsa/sherpa-onnx/releases/download/source-separation-models/sherpa-onnx-spleeter-2stems.tar.bz2
  SHA-256 `e26401d9c1801f43c0229731d78d32c2e80085e3aceedeb25f29d2de5fa68ca2`.
- **Packaged now:** two original fp32 U-Nets, run **sequentially**, not the merged
  fp16-stored graph. Only input/output frame-shape metadata is changed to symbolic;
  weights/nodes are unmodified. `prepare_models.py` reproduces the assets; exact
  sizes/hashes and licenses are in `assets/musicless/NOTICE.txt`.
- Input/output magnitude shapes: `[2, num_splits=1, frames, 1024]` float32.
  Java combines estimates as `(v+5e-11)/(v+2*a+1e-10)` and applies that mask to
  the original complex mixture spectrum. No squared Wiener mask.
- Stereo 44,100 Hz; FFT 4096, hop 1024, periodic Hann, centered reflect padding;
  analyze `frames+1` frames, infer the first `frames`, repeat the last mask once.
  Keep bins 0..1023 (up to 11,014 Hz), zero higher bins; inverse FFT /4096,
  Hann overlap-add normalized by Hann-squared sum.
- Per-window magnitude gain: `clip(10^(-24/20)/(RMS+1e-9),10^(-30/20),10^(30/20))`;
  reconstruction retains original level/phase. Subsequent heads fade in and all
  tails fade out over 2048 samples with complementary `(i+0.5)/2048` weights.
- **First window after each flush: 128 frames = 131,072 samples = 2.972 s**;
  thereafter 512 frames = 524,288 samples = 11.889 s. Stride is window minus 2048.
  No startup padding; EOF zero-pads inference only and emits exactly accepted duration.
  This changes the window grid relative to both the browser and the previous prototype.

## Sink correctness and clock hold

`MusiclessAudioSink` runs async separation **in front of** `DefaultAudioSink`, not
inside its synchronous `processBuffers` loop (which can busy-spin on a full async
queue). Two outstanding windows maximum, counting running/queued/completed work;
backpressure returns promptly. Partial stock-sink writes retain the same buffer.
Timestamps are first input time plus emitted **media-rate** frame count.

**EOF fixed:** `hasPendingData()` includes accepted input not yet emitted and
separated output not yet written; `isEnded()` also waits for processor and stock
sink completion. This keeps `MediaCodecAudioRenderer.isReady()` true while vocals
are pending, so `DefaultMediaClock` does not switch to standalone at read-stream EOF.
The new real-library clock test holds position at zero through 24 s of wall time,
including read-stream EOF **before sink EOS**, inference, and a blocked output write;
only after writing the final samples can the sink end. The older test remains as a
negative control proving stock unready-at-EOF clocks can advance.

**Midstream choice: also report pending data.** Renderer read-stream EOF can precede
`playToEndOfStream()` (codec read-ahead); an EOS-only flag leaves that interval
unprotected. Consequently pending inference can leave the player READY with its
clock held, **without the stock buffering spinner**. Reporting false midstream would
normally BUFFER with the spinner, and the internal stuck-buffering watchdog only
trips when not loading and <500 ms buffered, but cannot safely distinguish that
pre-EOS interval from ordinary starvation here. **Known limit:** READY holds over
10 s can trigger Media3's playing-no-progress watchdog (30 s emulator); no watchdog
was disabled. Device latency and a deliberate player-level hold/UI remain follow-up.
This is a sink/real-library unit result, not an end-to-end device sync guarantee
for every track duration or period transition.

**Speed:** renderer `setPlaybackParameters()` reaches our forwarding sink, then the
stock sink. DefaultAudioSink drains/rebuilds only its own pipeline (Sonic etc.);
it does **not** call back into the wrapper's processor flush. Keep the partial
Musicless window intact; separated vocals always reach Sonic at 44.1 kHz media
rate. A 1.0→1.5 mid-window test checks every pre-Sonic sample/count and executes
real Media3 Sonic to confirm the resulting 1.5x duration.

**Discontinuities:** neither the stock sink's >200 ms check nor its internal flush
can see upstream timestamps we previously synthesized as continuous. The wrapper
now detects input jumps >200 ms and defers explicit `handleDiscontinuity()` until
that input boundary: drain old vocals once, flush separation, rebase timestamps,
and notify the stock sink before new vocals. Retries neither accept new PCM early
nor discard/duplicate the old tail. A real seek's wrapper `flush()` instead drops
old-generation work immediately and starts a new held first window at the next
buffer's `timeUs`. Tests cover implicit/explicit boundaries and a new-time seek.

Source audit: pinned Media3 **1.10.1**, Maven sources under
`/tmp/musicless-bench/media3-src/`: `MediaCodecAudioRenderer:783-800`,
`DefaultMediaClock:162-207`, `DefaultAudioSink:902-1030,1301-1330,1630-1648`,
`RendererHolder:415-420`, `ExoPlayerImplInternal:1467-1495`, and
`common/util/StuckPlayerDetector:228-275`.

## ORT memory/time trials and selected configuration

Linux x86_64, Ryzen 5 3600, 62 GiB; Python 3.11.10, NumPy 2.4.6, ORT CPU 1.32.0.
Deterministic 60 s synthetic formant voice+piano/bass/drums, stereo PCM16, music
-12 dB relative to voice; WAV SHA-256
`cbed2d91cd619515709e3f040e20ab0b38e9a7887bd5976d260fb7e02fb621bc`.
**Not subjective real-speech evidence or an Android heap prediction.**

Each row: **three fresh processes**, sequential, no Gradle running. Time includes
six full 512-frame STFT/inference/iSTFT/crossfade windows, first inference included,
model load excluded. RSS is whole-process Linux `ru_maxrss`, including NumPy DSP.
All new rows disable arena, memory pattern and intra-op spinning; inter-op=1.
`merged` = Musicless fp16-stored/fp32-arithmetic graph; `split` = original fp32
U-Nets; `half` = separately converted fp16-stored U-Nets (same Cast recipe).

| Graph / optimization / threads | Pipeline s, three runs | Peak RSS MiB, three runs | Median s | Median MiB |
| --- | --- | --- | ---: | ---: |
| merged / ALL / 1 | 3.7022 / 3.5732 / 3.6468 | 561.64 / 562.90 / 559.87 | 3.6468 | 561.64 |
| merged / ALL / 2 | 2.5853 / 2.5169 / 2.5335 | 560.57 / 560.72 / 559.90 | 2.5335 | 560.57 |
| merged / BASIC / 1 | 3.7988 / 3.6735 / 3.6736 | 544.41 / 545.23 / 546.43 | 3.6736 | 545.23 |
| merged / BASIC / 2 | 2.6104 / 2.6110 / 2.6376 | 544.63 / 543.66 / 544.37 | 2.6110 | 544.37 |
| split / ALL / 1 | 3.1703 / 3.3913 / 3.1786 | 491.43 / 491.18 / 514.84 | 3.1786 | 491.43 |
| split / ALL / 2 | 2.2370 / 2.2462 / 2.4097 | 530.89 / 514.59 / 490.80 | 2.2462 | 514.59 |
| split / BASIC / 1 | 3.3368 / 3.3493 / 3.3873 | 505.92 / 505.92 / 473.88 | 3.3493 | 505.92 |
| **split / BASIC / 2** | **2.5584 / 2.5535 / 2.5118** | **450.48 / 450.18 / 450.32** | **2.5535** | **450.32** |
| half / ALL / 1 | 3.0759 / 3.1682 / 3.2922 | 503.77 / 495.43 / 495.68 | 3.1682 | 495.68 |
| half / ALL / 2 | 2.3144 / 2.2919 / 2.3213 | 519.76 / 523.70 / 519.91 | 2.3144 | 519.91 |
| half / BASIC / 1 | 3.5705 / 3.5962 / 3.5580 | 489.01 / 471.21 / 489.31 | 3.5705 | 489.01 |
| half / BASIC / 2 | 2.5244 / 2.5005 / 2.6055 | 489.01 / 489.12 / 478.04 | 2.5244 | 489.01 |

Previous round's default arena+pattern, merged/ALL/1: **3.0078 s / 834.41 MiB**
median (three processes); arena+pattern off without the spinning setting:
3.5907 s / 560.93 MiB. The selected **split/BASIC/2** is lowest measured median
RSS, within 1.5x of either prior time (indeed faster), RTF **0.04256**. RSS savings
versus default: **384.09 MiB / 46.0%**. Split ALL is faster but not the memory winner;
separate half-storage did not beat original fp32 RSS. Allocator variance is visible,
so do not extrapolate small differences to Android. Full-window selected output
versus the full-fp32 merged reference: **135.88 dB SDR**.

Java now applies BASIC, intra-op=2, inter-op=1, CPU arena off, memory pattern off,
`session.intra_op.allow_spinning=0` to **both sequential sessions**. Java computes
the mask in a reusable array, closing vocal output before accompaniment inference.
Model files are atomically copied once to hash-versioned cache paths, then loaded
by path; no model byte-array copies, telemetry disabled. Failure logs and emits
silence of exactly accepted duration, never original music. Generation checks
reject stale work; reset closes sessions on their owner executor.

Reproduce rows with `tools/musicless/benchmark.py MODEL clip60.wav --threads 1|2
--arena-off --spinning-off --optimization basic|all --output /tmp/vocals.npy`, adding
`--separate-models DIR` for split graphs. Repeat each in three fresh processes;
`OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1`. Raw JSON/arrays: `/tmp/musicless-bench/r3/`.

## Short-window experiment: accepted

`short_window.py` changes **a copy** of the merged model's input/output time
metadata to symbolic and runs ORT. Both **128 and 256 work**, no internal reshape
failure. Times below are median of three complete first-window DSP+inference runs;
SDR compares the entire shortened output against the same prefix of a 512-frame
output (including the short window's end boundary, before streaming crossfade).

| Frames | Merged/ALL/1 ms | SDR vs 512 dB | Selected split/BASIC/2 ms | SDR vs 512 dB |
| ---: | ---: | ---: | ---: | ---: |
| 512 | 508.89 | reference | 404.90 | reference |
| 256 | 207.44 | 33.79 | 174.34 | 33.80 |
| **128** | **106.24** | **24.09** | **82.23** | **24.09** |

128 clears both gates: SDR >=15 dB and >2x faster (**4.79x merged / 4.92x split**).
Implemented 128-frame first windows after every flush, including seek/discontinuity;
steady-state remains 512. This is one synthetic fixture, not a general perceptual
quality guarantee. Symbolic split assets were also actually exercised for all three
shapes. Raw: `shape{,-split}.jsonl`; reproduce with `short_window.py MODEL CLIP COPY`
and optionally `--separate-models smarttubetv/src/stmobile/assets/musicless`.

## Java DSP / allocations

Replace strict/slow `Math.hypot` with `sqrt(re*re+im*im)` (PCM/FFT magnitudes cannot
approach double overflow). Reuse spectrum (~8 MiB), magnitude (4 MiB), accumulation
(8 MiB), reconstruction (4 MiB); precompute overlap weights (4 MiB) once per DSP
size. Short/full scratch instances are worker-owned; returned arrays are borrowed
until the next call. The worker copies queued PCM results for ownership, so bounded
in-flight output/input allocations remain; no claim of zero allocations.

Host JDK 21 microbenchmark, 3 warmup + 9 timed full windows, median:
**211.824 ms before → 179.021 ms after (15.5% faster)**. Earlier independent runs:
214.662→177.672 ms. `tools/musicless/DspBenchmark.java` is a host-only main, not
shipped. Compile it with `MusiclessDsp.java` and run its package-qualified main;
compare against the parent commit's DSP. Existing unity/zero-mask and alignment
checks pass, plus a short-window scratch-reuse/zero-history check. A real-input FFT
was considered but not added: not a simple drop-in for the current in-place complex
FFT and would require a second numerical/performance audit.

## Build, tests and APK composition

**PASS: 16/16 Musicless tests** (13 processor/sink/clock + 3 DSP), zero failures or
errors. Includes real Media3 clock selection and Sonic, not ORT Android JNI/device.
Final clean verification, same command as round 2 (**26 s**, 242 tasks, 48 executed):

```sh
ANDROID_HOME=$HOME/Android/Sdk \
JAVA_HOME=$HOME/.local/share/mise/installs/java/openjdk-21.0.2 \
nice -n 10 ./gradlew -Dorg.gradle.workers.max=2 \
  :smarttubetv:clean :smarttubetv:assembleStmobileDebug \
  :smarttubetv:testStmobileDebugUnitTest \
  --tests 'com.newtube.mobile.player.Musicless*' --console=plain
```

Log: `/tmp/musicless-bench/r3/build.log`; test XML under
`smarttubetv/build/test-results/testStmobileDebugUnitTest/`. `git diff --check` passes.
An initial Sonic test used the legacy no-argument flush overload; pinned Sonic
implements metadata flush only. Corrected the test before the passing clean run.

`unzip -lv smarttubetv/build/outputs/renamed_apks/stmobileDebug/NewTube_1.17.1_arm64-v8a.apk`:

| Entry | Uncompressed bytes | ZIP bytes | Method |
| --- | ---: | ---: | --- |
| lib/arm64-v8a/libonnxruntime.so | 36,307,784 | 36,307,784 | Stored |
| lib/arm64-v8a/libonnxruntime4j_jni.so | 122,192 | 122,192 | Stored |
| assets/musicless/vocals.onnx | 39,318,331 | 36,622,620 | Deflated (7% saving) |
| assets/musicless/accompaniment.onnx | 39,318,338 | 36,625,870 | Deflated (7% saving) |

The **models dominate** incremental payload: **73,248,490 ZIP bytes** versus
36,429,976 bytes ORT+JNI. The round-2 merged asset was 36,491,806 ZIP bytes: choosing
lower runtime RSS costs **36,756,684 additional asset bytes**. ARM64 APK:
**181,313,330 bytes** (round 2: 144,556,430;
pre-prototype clean baseline: 71,496,795). No minimal ORT build was attempted.
Assets/ORT remain packaged unconditionally in stmobile, even in release where the
opt-in execution flag is disabled; production packaging needs a separate decision.

## Enable and remaining limits

Settings > Player > Remove music (MusiclessPrefs, off by default) wraps the stock sink; the playback screen restarts its engine on resume when the setting changed.
Use `adb -s <serial>` always; on this machine package is
`io.github.aleixrodriala.arc.debug` (no release keystore), otherwise the release
package. Clear the property afterwards; `grep -a Musicless` for NUL-containing logs.
Float/passthrough/offload and >2-channel/non-PCM16 formats are rejected, not bypassed.

Still not checked: on-device sync/RTF/RSS/thermal/battery, real-speech listening,
live/Cast and period/track-transition acceptance. No AVD/system image is installed
on this host; no device was modified. Linear 48→44.1 kHz resampling is not the
browser's 32-tap windowed-sinc resampler. Seek windows are flush-relative and cannot
reproduce the browser's media-zero grid without pre-seek decode/cache context.
Short startup and lower RSS do not establish viability on a low-RAM phone alongside
video decoding. The 10 s READY-hold watchdog limit and no-spinner behavior above
are explicit remaining product risks, not disabled safeguards.
