import AVFoundation
import CoreMedia
import Foundation
import os

/// The audio file to play: a googlevideo file plus its init and index ranges from the /player answer.
public struct VoiceSource: Sendable {
    public var file: MediaFile
    public var initRange: ClosedRange<Int64>
    public var indexRange: ClosedRange<Int64>

    public init(file: MediaFile, initRange: ClosedRange<Int64>, indexRange: ClosedRange<Int64>) {
        self.file = file
        self.initRange = initRange
        self.indexRange = indexRange
    }
}

/// Plays a YouTube audio file with only the voices (US-012, PRD §4.2): fetch → demux → AAC decode →
/// voice stage (the Separator) → LPCM sample buffers → `AVSampleBufferAudioRenderer` on an
/// `AVSampleBufferRenderSynchronizer`. The synchronizer owns the clock; a hold is rate 0, so the
/// clock can't run ahead of the voices (Android's `MusiclessAudioSink`).
///
/// - Hold: rate 0 from a start or seek until the first voices are enqueued; later, when less than
///   0.25 s is enqueued ahead and more is still coming, debounced 100 ms (`HoldDebounce`). Unlike
///   Android, where ExoPlayer pauses the clock for network buffering on its own, this player is the
///   only one who can stop the clock, so a slow network holds too (`reason=underrun`, with
///   `waitInputMs` showing it).
/// - Bounded look-ahead: a voice chunk is taken from the stage only once the previous one is in the
///   renderer, so memory holds one chunk plus the stage's two windows, never the whole video.
/// - Seek and the Remove-music switch flush the renderer and the stage and restart the feed at the
///   target's segment; old work is dropped by the stage's generation and the player's epoch.
///
/// The player owns the stage and closes it.
public actor VoicePlayer {
    public enum HoldReason: String, Sendable { case start, seek, underrun }

    public enum Status: Sendable, Equatable {
        case idle
        case loading
        case holding(HoldReason)
        case playing
        case paused
        case ended
        case failed(String)
    }

    public struct Snapshot: Sendable, Equatable {
        public var status: Status
        public var position: Double
        public var duration: Double?
        /// Voices enqueued in the renderer past the playhead.
        public var aheadSeconds: Double
        public var removeMusic: Bool
        public var wantsToPlay: Bool
    }

    public struct Configuration: Sendable {
        /// A hold starts when less than this is enqueued ahead and more is coming (US-012).
        public var holdBelow: Double = 0.25
        /// Mutes the renderer (tests); the clock runs the same.
        public var muted = false
        /// Period of the `voices position=…` line; nil turns it off.
        public var reportEvery: Duration? = .seconds(10)

        public init() {}
    }

    private static let rate = Int64(PCMSampleBuffers.sampleRate)

    private let queue = DispatchSerialQueue(label: "Musicless-Player", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let source: VoiceSource
    private let fetcher: MediaFetcher
    private let stage: VoiceStage
    private let configuration: Configuration
    private let log: @Sendable (String) -> Void
    private let holdLog: @Sendable (String) -> Void
    private let onChange: @Sendable (Snapshot) -> Void
    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()

    private var header: FMP4Header?
    private var track: FMP4Track?
    private var format: CMAudioFormatDescription?
    private var duration: Double?

    // Position. `epoch` changes on every start, seek, switch and close; work from an older epoch stops.
    private var epoch = 0
    private var expectedGeneration: Int?
    /// Presentation time of the stage's frame 0 (set by the feed before its first samples).
    private var baseTime: CMTime = .zero
    private var enqueuedEnd: CMTime = .zero
    /// The stage delivered its end-of-stream chunk: nothing more is coming.
    private var streamEnded = false
    private var ended = false
    /// Buffers in the renderer not yet played, re-enqueued after an automatic flush.
    private var retained: [CMSampleBuffer] = []
    private var feedTask: Task<Void, Never>?
    private var outputTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var readinessWaiter: CheckedContinuation<Void, Never>?
    /// Input energy per `levelBlock` frames of the stage's timeline (44.1 kHz from the last flush), so
    /// each chunk's line compares the input and voices levels over the same span.
    private var inputLevels = LevelBlocks()
    private var flushObserver: (any NSObjectProtocol)?

    // Intent and hold.
    private var wantsToPlay = true
    private var removeMusic = true
    private var debounce = HoldDebounce()
    private var holdReason: HoldReason = .start
    private var holdStart: ContinuousClock.Instant?
    private var failure: String?
    private var opened = false
    private var closed = false
    private var startedAt: ContinuousClock.Instant?
    private var firstAudioLogged = false
    private var lastReport: ContinuousClock.Instant?
    /// What `onChange` last reported (status and the two switches).
    private var published: (Status, Bool, Bool)?

    /// - Parameters:
    ///   - log: player lines (`voices …`); the app sends them to its `Player` category.
    ///   - holdLog: `hold reason=…` lines, in Android's format (its `Musicless` tag).
    ///   - onChange: status changes (start, holds, pause, end, failure), from the player's queue.
    public init(source: VoiceSource, fetcher: MediaFetcher, stage: VoiceStage, configuration: Configuration = .init(),
                log: @escaping @Sendable (String) -> Void = { _ in },
                holdLog: @escaping @Sendable (String) -> Void = { _ in },
                onChange: @escaping @Sendable (Snapshot) -> Void = { _ in }) {
        self.source = source
        self.fetcher = fetcher
        self.stage = stage
        self.configuration = configuration
        self.log = log
        self.holdLog = holdLog
        self.onChange = onChange
    }

    // MARK: Control

    /// Opens the file and starts at `seconds`, holding until the first voices are ready.
    public func start(at seconds: Double = 0, removeMusic: Bool = true, playing: Bool = true) async {
        guard !opened, !closed else { return }
        opened = true
        startedAt = .now
        self.removeMusic = removeMusic
        wantsToPlay = playing
        renderer.isMuted = configuration.muted
        synchronizer.addRenderer(renderer)
        // Our hold logic decides when the clock runs; the synchronizer's own wait for "sufficient
        // media data" would add an unmeasured delay after the first window (DECISIONS).
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        flushObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: renderer, queue: nil
        ) { [weak self] note in
            let time = (note.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue
            Task { await self?.rendererFlushedAutomatically(at: time) }
        }
        hold(.start)
        publish()
        do {
            let header = try await FMP4Reader.open(fetcher, initRange: source.initRange, indexRange: source.indexRange)
            guard let track = header.track(.audio) else { throw AACDecoderError("no audio track") }
            let decoder = try AACDecoder(track: track)
            try await stage.configure(sampleRate: decoder.sampleRate, channels: decoder.channels)
            self.header = header
            self.track = track
            format = try PCMSampleBuffers.format()
            if let last = header.index.references.last {
                duration = header.index.seconds(last.startTime + UInt64(last.duration))
            }
            log("voices open itag=\(source.file.itag) codec=\(track.codec) rate=\(Int(decoder.sampleRate)) "
                + "channels=\(decoder.channels) segments=\(header.index.references.count) "
                + "duration=\(Self.format(duration ?? 0)) priming=\(track.editMediaTime) "
                + "openMs=\(Self.milliseconds(since: startedAt!))")
        } catch {
            fail(error)
            return
        }
        guard !closed else { return }
        outputTask = Task { await self.outputLoop() }
        tickTask = Task { await self.tickLoop() }
        await restart(at: seconds, reason: .start, passThrough: !removeMusic)
    }

    public func play() {
        wantsToPlay = true
        if ended { return }
        applyRate()
        publish()
    }

    public func pause() {
        wantsToPlay = false
        applyRate()
        publish()
    }

    /// Restarts at `seconds` (flush, refetch from that segment, hold until voices are ready).
    public func seek(to seconds: Double) async {
        guard header != nil, !closed else { return }
        await restart(at: seconds, reason: .seek, passThrough: nil)
    }

    /// The Remove-music switch: pass-through on or off, with a flush at the current position.
    public func setRemoveMusic(_ on: Bool) async {
        guard on != removeMusic else { return }
        removeMusic = on
        guard header != nil, !closed else { return }
        log("voices removeMusic=\(on) at=\(Self.format(synchronizer.currentTime().seconds))")
        await restart(at: synchronizer.currentTime().seconds, reason: .seek, passThrough: !on)
    }

    public func snapshot() -> Snapshot {
        Snapshot(status: status, position: synchronizer.currentTime().seconds, duration: duration,
                 aheadSeconds: aheadSeconds, removeMusic: removeMusic, wantsToPlay: wantsToPlay)
    }

    /// Stops playback, releases the renderer and closes the stage.
    public func close() async {
        guard !closed else { return }
        if debounce.holding { logHold(end: .now) }
        closed = true
        epoch += 1
        feedTask?.cancel()
        tickTask?.cancel()
        synchronizer.rate = 0
        renderer.stopRequestingMediaData()
        readinessWaiter?.resume()
        readinessWaiter = nil
        renderer.flush()
        retained.removeAll()
        if let flushObserver { NotificationCenter.default.removeObserver(flushObserver) }
        flushObserver = nil
        if opened { _ = await synchronizer.removeRenderer(renderer, at: .zero) }
        await stage.close()  // ends the output loop's wait
        log("voices close")
        publish()
    }

    // MARK: Restart (start, seek, switch)

    private func restart(at seconds: Double, reason: HoldReason, passThrough: Bool?) async {
        epoch += 1
        let token = epoch
        feedTask?.cancel()
        feedTask = nil
        expectedGeneration = nil
        if debounce.holding && holdStart != nil && reason != .start { logHold(end: .now) }
        let target = max(0, min(seconds, (duration ?? .infinity) - 0.1))
        let time = CMTime(value: Int64((target * Double(Self.rate)).rounded()), timescale: CMTimeScale(Self.rate))
        synchronizer.setRate(0, time: time)
        renderer.flush()
        retained.removeAll()
        baseTime = time
        enqueuedEnd = time
        streamEnded = false
        ended = false
        inputLevels = LevelBlocks()
        if reason == .start && debounce.holding && holdStart != nil {
            applyRate()  // the start hold began when start() was called: keep its clock
        } else {
            hold(reason)
        }
        publish()
        let generation = await stage.flush(passThrough: passThrough)
        guard token == epoch, !closed else { return }
        await stage.beginHold()
        guard token == epoch, !closed else { return }
        expectedGeneration = generation
        feedTask = Task { await self.feed(from: target, generation: generation, epoch: token) }
    }

    // MARK: Feed: segments -> AAC -> stage

    private func feed(from target: Double, generation: Int, epoch token: Int) async {
        guard let header, let track else { return }
        do {
            let decoder = try AACDecoder(track: track)
            let rate = decoder.sampleRate
            let timescale = Double(track.timescale)
            let edit = Double(max(0, track.editMediaTime)) / timescale
            let first = header.index.seek(to: target + edit)?.index ?? 0
            var segments = FMP4Reader.segments(fetcher, header: header, from: first).makeAsyncIterator()
            var toDrop: Int?
            var sent = false
            while let segment = try await segments.next() {
                guard token == epoch, !closed else { return }
                let samples = try FMP4Demuxer.parseSegment(segment.data, track: track)
                var pcm = try decoder.decode(samples)
                if toDrop == nil, let firstSample = samples.first {
                    // Frame 0 of this feed is the segment's first sample; drop what precedes the target.
                    let presentation = Double(firstSample.decodeTime) / timescale - edit
                    let drop = max(0, Int(((target - presentation) * rate).rounded(.up)))
                    toDrop = drop
                    let startSample = Int64((presentation * rate).rounded()) + Int64(drop)
                    baseTime = CMTime(value: startSample, timescale: CMTimeScale(rate))
                    synchronizer.setRate(0, time: baseTime)
                    enqueuedEnd = baseTime
                }
                if let drop = toDrop, drop > 0 {
                    let frames = min(drop, pcm.count / decoder.channels)
                    pcm.removeFirst(frames * decoder.channels)
                    toDrop = drop - frames
                }
                guard !pcm.isEmpty else { continue }
                inputLevels.add(pcm, channels: decoder.channels, scale: Double(Self.rate) / rate)
                sent = true
                await stage.enqueue(pcm, generation: generation)
            }
            guard token == epoch, !closed else { return }
            let tail = try decoder.finish()
            if !tail.isEmpty, sent { await stage.enqueue(tail, generation: generation) }
            await stage.endOfStream(generation: generation)
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            if token == epoch, !closed { fail(error) }
        }
    }

    // MARK: Output: stage -> renderer

    private func outputLoop() async {
        while !closed {
            guard let chunk = await stage.nextChunk() else { return }
            guard let expected = expectedGeneration, chunk.generation == expected, let format else { continue }
            let token = epoch
            if chunk.isEndOfStream {
                streamEnded = true
                log("voices end-of-stream at=\(Self.format(enqueuedEnd.seconds))")
                updateHold()
                continue
            }
            if chunk.isSilence { log("voices silence frames=\(chunk.frameCount) (separation failed)") }
            let start = baseTime + CMTime(value: chunk.startFrame, timescale: CMTimeScale(Self.rate))
            let span = chunk.startFrame..<(chunk.startFrame + Int64(chunk.frameCount))
            log("voices chunk startS=\(Self.format(start.seconds)) seconds=\(Self.format(Double(chunk.frameCount) / Double(Self.rate))) "
                + "inputDb=\(inputLevels.decibels(span)) voicesDb=\(Self.decibels(chunk.samples)) removeMusic=\(removeMusic)")
            var offset = 0
            while offset < chunk.frameCount {
                while !renderer.isReadyForMoreMediaData && token == epoch && !closed {
                    updateHold()  // about to wait: what is queued may already be enough to play
                    await waitForRenderer()
                }
                guard token == epoch, !closed else { break }
                let count = min(PCMSampleBuffers.framesPerBuffer, chunk.frameCount - offset)
                let time = start + CMTime(value: Int64(offset), timescale: CMTimeScale(Self.rate))
                do {
                    let buffer = try PCMSampleBuffers.make(chunk.samples, offset: offset, frames: count, at: time, format: format)
                    renderer.enqueue(buffer)
                    retained.append(buffer)
                } catch {
                    fail(error)
                    return
                }
                enqueuedEnd = time + CMTime(value: Int64(count), timescale: CMTimeScale(Self.rate))
                offset += count
                if renderer.status == .failed {
                    fail(renderer.error ?? AACDecoderError("the audio renderer failed"))
                    return
                }
            }
            if token == epoch { updateHold() }
        }
    }

    private func waitForRenderer() async {
        await withCheckedContinuation { continuation in
            readinessWaiter?.resume()
            readinessWaiter = continuation
            renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
                Task { await self?.rendererReady() }
            }
        }
    }

    private func rendererReady() {
        renderer.stopRequestingMediaData()
        readinessWaiter?.resume()
        readinessWaiter = nil
    }

    /// The renderer flushed itself (an output change): put back what it held, in order. A flush of
    /// our own first drops anything the output loop enqueued after the automatic one.
    private func rendererFlushedAutomatically(at time: CMTime?) {
        guard !closed, let time, time.isValid else { return }
        renderer.flush()
        let keep = retained.filter { CMTimeAdd($0.presentationTimeStamp, $0.duration) > time }
        keep.forEach { renderer.enqueue($0) }
        retained = keep
        log("voices renderer flushed automatically at=\(Self.format(time.seconds)) reEnqueued=\(keep.count)")
    }

    // MARK: Hold

    private var aheadSeconds: Double { (enqueuedEnd - synchronizer.currentTime()).seconds }

    private func hold(_ reason: HoldReason) {
        let now = ContinuousClock.now
        holdReason = reason
        holdStart = now
        debounce.set(true, now: now)
        applyRate()
    }

    /// Android's `updateHold`: starved = more voices are coming and less than `holdBelow` is queued.
    private func updateHold() {
        guard !closed, failure == nil, header != nil, expectedGeneration != nil else { return }
        let now = ContinuousClock.now
        let starved = !streamEnded && aheadSeconds < configuration.holdBelow
        if starved && debounce.since == nil && !debounce.holding {
            Task { await stage.beginHold() }
        }
        guard debounce.update(starved: starved, now: now) else { return }
        if debounce.holding {
            holdStart = debounce.since
            holdReason = .underrun
        } else {
            logHold(end: now)
            if !firstAudioLogged, let startedAt {
                firstAudioLogged = true
                log("voices first-audio ms=\(Self.milliseconds(since: startedAt)) at=\(Self.format(baseTime.seconds)) "
                    + "ahead=\(Self.format(aheadSeconds)) sufficient=\(renderer.hasSufficientMediaDataForReliablePlaybackStart)")
            }
        }
        applyRate()
        publish()
    }

    private func logHold(end: ContinuousClock.Instant) {
        guard let start = holdStart else { return }
        holdStart = nil
        let reason = holdReason
        let stage = stage, holdLog = holdLog
        Task {
            let stats = await stage.holdStats()
            let inputEnd = stats.inputReadyAt.map { min($0, end) } ?? end
            holdLog("hold reason=\(reason.rawValue) waitInputMs=\(max(0, Self.milliseconds(start, inputEnd))) "
                    + "queueMs=\(stats.queueMs) waitModelMs=\(stats.waitModelMs) inferMs=\(stats.inferMs) "
                    + "totalMs=\(Self.milliseconds(start, end))")
        }
    }

    private func applyRate() {
        let target: Float = wantsToPlay && !debounce.holding && failure == nil && !ended && !closed ? 1 : 0
        if synchronizer.rate != target { synchronizer.rate = target }
    }

    // MARK: Clock tick

    /// Wakes when starvation could first happen (the playhead can't eat what is queued faster than
    /// real time), every 25 ms while debouncing, and every 250 ms while holding or paused.
    private func tickLoop() async {
        while !closed {
            let delay = tick()
            try? await Task.sleep(for: delay)
        }
    }

    private func tick() -> Duration {
        let now = synchronizer.currentTime()
        if retained.count > 1 {
            retained.removeAll { CMTimeAdd($0.presentationTimeStamp, $0.duration) < now - CMTime(value: 1, timescale: 2) }
        }
        updateHold()
        if streamEnded, !ended, now >= enqueuedEnd {
            ended = true
            applyRate()
            log("voices ended at=\(Self.format(now.seconds))")
            publish()
        }
        if let every = configuration.reportEvery, !debounce.holding, synchronizer.rate > 0,
           lastReport.map({ ContinuousClock.now - $0 >= every }) ?? true {
            lastReport = .now
            log("voices position=\(Self.format(now.seconds)) ahead=\(Self.format(aheadSeconds)) status=\(status.logValue)")
        }
        if debounce.since != nil && !debounce.holding { return .milliseconds(25) }
        guard synchronizer.rate > 0 else { return .milliseconds(250) }
        let slack = aheadSeconds - configuration.holdBelow
        return .milliseconds(Int(max(0.025, min(slack, 0.5)) * 1000))
    }

    // MARK: State

    private var status: Status {
        if let failure { return .failed(failure) }
        if closed || !opened { return .idle }
        if ended { return .ended }
        if header == nil { return .loading }
        if !wantsToPlay { return .paused }
        if debounce.holding { return .holding(holdReason) }
        return .playing
    }

    private func publish() {
        let snapshot = snapshot()
        if let published, published == (snapshot.status, snapshot.removeMusic, snapshot.wantsToPlay) { return }
        published = (snapshot.status, snapshot.removeMusic, snapshot.wantsToPlay)
        onChange(snapshot)
    }

    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error is MediaRefused ? "media refused (\(error)); recovery is US-017" : "\(error)"
        log("voices failed error=\(failure!)")
        applyRate()
        publish()
    }

    // MARK: Helpers

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int { milliseconds(start, .now) }

    private static func milliseconds(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Int {
        Int((end - start) / .milliseconds(1))
    }

    static func format(_ seconds: Double) -> String { String(format: "%.2f", seconds) }

    /// RMS level in dBFS of interleaved samples ("-inf" for silence).
    static func decibels(_ samples: [Float]) -> String {
        var sum: Double = 0
        for sample in samples { sum += Double(sample) * Double(sample) }
        return LevelBlocks.decibels(sum: sum, count: samples.count)
    }
}

/// Sum of squares per block of 4,096 frames on the 44.1 kHz timeline, for level comparisons.
struct LevelBlocks {
    static let block = 4_096
    private var sums: [Double] = []
    private var counts: [Int] = []
    private var frames: Double = 0

    /// Interleaved input at its own rate; `scale` maps its frames to 44.1 kHz frames.
    mutating func add(_ samples: [Float], channels: Int, scale: Double) {
        let count = samples.count / channels
        for frame in 0..<count {
            let index = Int((frames + Double(frame)) * scale) / Self.block
            while sums.count <= index {
                sums.append(0)
                counts.append(0)
            }
            for channel in 0..<channels {
                let sample = Double(samples[frame * channels + channel])
                sums[index] += sample * sample
            }
            counts[index] += channels
        }
        frames += Double(count)
    }

    func decibels(_ span: Range<Int64>) -> String {
        guard !span.isEmpty else { return "-inf" }
        let first = Int(span.lowerBound) / Self.block, last = min(Int(span.upperBound - 1) / Self.block, sums.count - 1)
        guard first <= last else { return "?" }
        return Self.decibels(sum: sums[first...last].reduce(0, +), count: counts[first...last].reduce(0, +))
    }

    static func decibels(sum: Double, count: Int) -> String {
        guard count > 0, sum > 0 else { return "-inf" }
        return String(format: "%.1f", 10 * log10(sum / Double(count)))
    }
}

extension VoicePlayer.Status {
    public var logValue: String {
        switch self {
        case .idle: "idle"
        case .loading: "loading"
        case .holding(let reason): "holding-\(reason.rawValue)"
        case .playing: "playing"
        case .paused: "paused"
        case .ended: "ended"
        case .failed: "failed"
        }
    }
}
