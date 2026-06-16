import Foundation
import AVFoundation
import os

/// Tiny lock-wrapped Bool. Matches `RingBuffer`'s `OSAllocatedUnfairLock` style
/// so the producer hot path stays branch-light (one unfair-lock acquire per
/// chunk, microseconds).
private final class AtomicBool: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var value: Bool
    init(_ initial: Bool) { self.value = initial }
    var get: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set(_ newValue: Bool) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }
}

/// High-level playback controller. Wraps `SIDPlayerEngine` with:
///  - a producer thread that calls the SID emulator off the audio render thread
///  - an `AVAudioEngine` graph that drains a `RingBuffer` and feeds a `VizTap`
///  - play/pause + subtune navigation
public final class SIDPlayer: @unchecked Sendable {
    public let engine: SIDPlayerEngine
    public let sampleRate: Double

    /// PCM tap for visualizers, filled from the audio render callback so the
    /// data is in sync with what the speakers play.
    public let vizTap: VizTap

    /// Per-voice taps (length 3). Filled from a producer-side render of three
    /// extra libsidplayfp engines that mirror the main one with two voices
    /// muted each. They run AHEAD of audio output by the ring buffer's
    /// fullness (~93 ms with a 4k-sample ring). Audio path is independent —
    /// voice engine failures cannot break the audible mix.
    public let voiceTaps: [VizTap]
    private let voiceEngines: [SIDPlayerEngine]
    /// When false, the producer thread skips rendering the three voice engines.
    /// Each is a full C64+SID emulation — the per-voice scopes can't be derived
    /// from the main engine's already-mixed output, and the C64 runs at ~1 MHz
    /// regardless of output sample rate, so they roughly triple the emulator's
    /// CPU cost. Hiding the visualizers is what reclaims it.
    public var vizEnabled: Bool {
        get { _vizEnabled.get }
        set { _vizEnabled.set(newValue) }
    }
    private let _vizEnabled = AtomicBool(true)

    private let av = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    /// Pre-allocated scratch buffer for the audio render callback. Sized to
    /// `ringCapacity` so any plausible `frameCount` fits without realloc on
    /// the real-time thread.
    private var renderScratch: UnsafeMutablePointer<Int16>?
    private var renderScratchCapacity: Int = 0
    private let ring: RingBuffer
    private let ringCapacity: Int
    private var producer: Thread?
    private let producerStop = AtomicBool(false)
    private let paused = AtomicBool(true)
    private(set) var loadedPath: String?

    /// Emulation settings. Applied to all engines on the next load() or
    /// reloadCurrentTune() call — never while the producer thread is running.
    public var emulationConfig: EmulationConfig = EmulationConfig()

    public init(sampleRate: Double = 44_100, ringCapacity: Int = 4096) {
        self.engine        = SIDPlayerEngine()
        self.sampleRate    = sampleRate
        self.ring          = RingBuffer(capacity: ringCapacity)
        self.ringCapacity  = ringCapacity
        self.vizTap        = VizTap(capacity: 8192)
        self.voiceEngines  = (0..<3).map { _ in SIDPlayerEngine() }
        self.voiceTaps     = (0..<3).map { _ in VizTap(capacity: 8192) }
        loadBundledROMs()
    }

    /// Loads ROMs from the main bundle and feeds them to all engines.
    /// Missing ROMs just mean some RSID tunes won't play correctly.
    private func loadBundledROMs() {
        let (kernal, basic, chargen) = Self.bundleROMData()
        engine.setROMs(kernal: kernal, basic: basic, chargen: chargen)
        for ve in voiceEngines {
            ve.setROMs(kernal: kernal, basic: basic, chargen: chargen)
        }
    }

    deinit {
        stop()
        if let s = renderScratch {
            s.deallocate()
            renderScratch = nil
        }
    }

    public var info: TuneInfo? { engine.info }
    public var currentTime: TimeInterval { engine.currentTime }
    public var currentSong: Int { engine.currentSong }
    public var isPlaying: Bool { !paused.get }

    public func load(path: String) throws {
        stopProducer()
        ring.clear()
        loadedPath = path
        applyConfigToAllEngines()
        try engine.load(path: path)
        let start = engine.info?.startSong ?? 1
        try engine.start(song: start, sampleRate: Int(sampleRate))

        // Best-effort viz engine setup. Failures here are non-fatal — the
        // main audio path keeps working with empty voice taps.
        for (i, ve) in voiceEngines.enumerated() {
            do {
                try ve.load(path: path)
                try ve.start(song: start, sampleRate: Int(sampleRate))
                for v in 0..<3 { ve.setVoiceMuted(v, muted: v != i) }
            } catch {
                // ignore — viz only
            }
        }
    }

    public func play() throws {
        if av.isRunning == false {
            try installSourceNodeIfNeeded()
            try av.start()
        }
        paused.set(false)
        startProducer()
    }

    public func pause() {
        paused.set(true)
        stopProducer()
    }

    public func stop() {
        paused.set(true)
        stopProducer()
        if av.isRunning { av.stop() }
        // Rewind to the start of the current song without unloading the tune,
        // so the next play() resumes from zero. Calling engine.stop() here
        // would unload the tune entirely and the next play() would be silent.
        let song = engine.currentSong
        if song > 0 {
            try? engine.select(song: song)
            syncVoiceEngines(toSong: song)
        }
        ring.clear()
    }

    public func setVolume(_ v: Float) {
        av.mainMixerNode.outputVolume = max(0, min(1, v))
    }
    public var volume: Float { av.mainMixerNode.outputVolume }

    public func nextSong() throws {
        stopProducer()
        ring.clear()
        try engine.nextSong()
        syncVoiceEngines(toSong: engine.currentSong)
        if !paused.get { startProducer() }
    }

    public func previousSong() throws {
        stopProducer()
        ring.clear()
        try engine.previousSong()
        syncVoiceEngines(toSong: engine.currentSong)
        if !paused.get { startProducer() }
    }

    public func select(song: Int) throws {
        stopProducer()
        ring.clear()
        try engine.select(song: song)
        syncVoiceEngines(toSong: song)
        if !paused.get { startProducer() }
    }

    /// Reloads the current tune with the active emulation config.
    /// Preserves subtune selection. Resumes playback if it was active.
    public func reloadCurrentTune() throws {
        guard let path = loadedPath else { return }
        let song = max(engine.currentSong, 1)
        let wasPlaying = !paused.get
        stopProducer()
        ring.clear()
        applyConfigToAllEngines()
        try engine.load(path: path)
        try engine.start(song: song, sampleRate: Int(sampleRate))
        for (i, ve) in voiceEngines.enumerated() {
            try? ve.load(path: path)
            try? ve.start(song: song, sampleRate: Int(sampleRate))
            for v in 0..<3 { ve.setVoiceMuted(v, muted: v != i) }
        }
        if wasPlaying { try play() }
    }

    private func applyConfigToAllEngines() {
        engine.applyConfig(emulationConfig)
        for ve in voiceEngines { ve.applyConfig(emulationConfig) }
    }

    private func syncVoiceEngines(toSong song: Int) {
        for (i, ve) in voiceEngines.enumerated() {
            try? ve.select(song: song)
            for v in 0..<3 { ve.setVoiceMuted(v, muted: v != i) }
        }
    }

    // MARK: - Audio graph

    private func installSourceNodeIfNeeded() throws {
        guard sourceNode == nil else { return }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "SIDPlayer", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "audio format init failed"])
        }

        // Pre-allocate render scratch once. AVAudioEngine calls the source
        // node from a single real-time thread, so reuse is safe without a
        // lock; sizing to ringCapacity covers any plausible frameCount.
        let scratchCap = ringCapacity
        let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: scratchCap)
        renderScratch = scratch
        renderScratchCapacity = scratchCap

        let ringRef = ring
        let tapRef  = vizTap
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
            let bufList = UnsafeMutableAudioBufferListPointer(abl)
            guard let dest = bufList[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }

            // Non-blocking ring/tap access: a real-time render callback must
            // never wait on the producer's lock. Contention shows up as one
            // silent cycle / dropped viz chunk, which is inaudible and rare.
            let n = min(Int(frameCount), scratchCap)
            let read = ringRef.tryRead(scratch, count: n)
            for i in 0..<read { dest[i] = Float(scratch[i]) / 32768.0 }
            let total = Int(frameCount)
            if read < total { dest.advanced(by: read).update(repeating: 0, count: total - read) }
            if read > 0 { tapRef.tryAppend(scratch, count: read) }
            return noErr
        }
        av.attach(node)
        av.connect(node, to: av.mainMixerNode, format: format)
        sourceNode = node
    }

    // MARK: - Producer thread

    private func startProducer() {
        guard producer == nil else { return }
        producerStop.set(false)
        let t = Thread { [weak self] in
            guard let self else { return }
            self.producerLoop()
        }
        t.name = "sid-producer"
        t.qualityOfService = .userInitiated
        producer = t
        t.start()
    }

    /// Joins the producer thread unconditionally. The loop polls
    /// `producerStop` each iteration and exits in well under a frame, so an
    /// unbounded wait can't actually hang — but it does guarantee we never
    /// orphan a thread and race a freshly started one on the same engine.
    private func stopProducer() {
        producerStop.set(true)
        producer?.cancel()
        while let t = producer, !t.isFinished {
            Thread.sleep(forTimeInterval: 0.005)
        }
        producer = nil
    }

    private func producerLoop() {
        let chunk = 1024
        let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: chunk)
        let v0 = UnsafeMutablePointer<Int16>.allocate(capacity: chunk)
        let v1 = UnsafeMutablePointer<Int16>.allocate(capacity: chunk)
        let v2 = UnsafeMutablePointer<Int16>.allocate(capacity: chunk)
        defer { [scratch, v0, v1, v2].forEach { $0.deallocate() } }
        let voiceScratch = [v0, v1, v2]

        while !producerStop.get {
            if ring.freeSpace < chunk {
                Thread.sleep(forTimeInterval: 0.002)
                continue
            }
            let n = engine.render(into: scratch, count: chunk)
            if n == 0 {
                Thread.sleep(forTimeInterval: 0.010)
                continue
            }

            // Drive voice engines for the same N samples, then fill voice taps
            // directly. Failures here are silently ignored — they're viz only,
            // they cannot stall the audio ring write below. Skipped entirely
            // when visualizers are off, saving the per-engine CPU cost.
            if _vizEnabled.get {
                for (i, ve) in voiceEngines.enumerated() {
                    let m = ve.render(into: voiceScratch[i], count: n)
                    // Non-blocking: these writes precede the audio ring fill
                    // below, so blocking on a UI reader's snapshot lock could
                    // stall the ring and underrun the output. A dropped viz
                    // chunk is invisible; a stalled ring is audible.
                    if m > 0 { voiceTaps[i].tryAppend(voiceScratch[i], count: m) }
                }
            }

            // Push main mix to the audio ring. This is the only thing the
            // audio path depends on.
            var written = 0
            while written < n && !producerStop.get {
                let w = ring.write(scratch.advanced(by: written), count: n - written)
                written += w
                if w == 0 { Thread.sleep(forTimeInterval: 0.001) }
            }
        }
    }
}
