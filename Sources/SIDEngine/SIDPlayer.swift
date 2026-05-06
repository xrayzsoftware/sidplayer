import Foundation
import AVFoundation

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
    /// When false, the producer thread skips rendering the voice engines —
    /// saves ~3% CPU when the per-voice waveform is hidden.
    public var vizEnabled: Bool = true

    private let av = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let ring: RingBuffer
    private var producer: Thread?
    private var producerStop = false
    private var paused = true

    public init(sampleRate: Double = 44_100, ringCapacity: Int = 4096) {
        self.engine        = SIDPlayerEngine()
        self.sampleRate    = sampleRate
        self.ring          = RingBuffer(capacity: ringCapacity)
        self.vizTap        = VizTap(capacity: 8192)
        self.voiceEngines  = (0..<3).map { _ in SIDPlayerEngine() }
        self.voiceTaps     = (0..<3).map { _ in VizTap(capacity: 8192) }
        loadBundledROMs()
    }

    /// Looks for `kernal.rom`, `basic.rom`, `chargen.rom` in the main bundle
    /// (under ROMs/ subdir) and feeds them to every engine. Optional —
    /// missing ROMs just mean some RSID tunes won't play correctly.
    private func loadBundledROMs() {
        let bundle = Bundle.main
        func load(_ name: String) -> Data? {
            // Try ROMs/<name>.rom first; fall back to <name>.rom at bundle root.
            if let url = bundle.url(forResource: name, withExtension: "rom", subdirectory: "ROMs") {
                return try? Data(contentsOf: url)
            }
            if let url = bundle.url(forResource: name, withExtension: "rom") {
                return try? Data(contentsOf: url)
            }
            return nil
        }
        let kernal  = load("kernal")
        let basic   = load("basic")
        let chargen = load("chargen")
        engine.setROMs(kernal: kernal, basic: basic, chargen: chargen)
        for ve in voiceEngines {
            ve.setROMs(kernal: kernal, basic: basic, chargen: chargen)
        }
    }

    deinit { stop() }

    public var info: TuneInfo? { engine.info }
    public var currentTime: TimeInterval { engine.currentTime }
    public var currentSong: Int { engine.currentSong }
    public var isPlaying: Bool { !paused }

    public func load(path: String) throws {
        try stopProducer()
        ring.clear()
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
        paused = false
        startProducer()
    }

    public func pause() {
        paused = true
        try? stopProducer()
    }

    public func stop() {
        paused = true
        try? stopProducer()
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
        try stopProducer()
        ring.clear()
        try engine.nextSong()
        syncVoiceEngines(toSong: engine.currentSong)
        if !paused { startProducer() }
    }

    public func previousSong() throws {
        try stopProducer()
        ring.clear()
        try engine.previousSong()
        syncVoiceEngines(toSong: engine.currentSong)
        if !paused { startProducer() }
    }

    public func select(song: Int) throws {
        try stopProducer()
        ring.clear()
        try engine.select(song: song)
        syncVoiceEngines(toSong: song)
        if !paused { startProducer() }
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

        let ringRef = ring
        let tapRef  = vizTap
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
            let bufList = UnsafeMutableAudioBufferListPointer(abl)
            guard let dest = bufList[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }

            let n = Int(frameCount)
            let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: n)
            defer { scratch.deallocate() }

            let read = ringRef.read(scratch, count: n)
            for i in 0..<read { dest[i] = Float(scratch[i]) / 32768.0 }
            if read < n { dest.advanced(by: read).update(repeating: 0, count: n - read) }
            if read > 0 { tapRef.append(scratch, count: read) }
            return noErr
        }
        av.attach(node)
        av.connect(node, to: av.mainMixerNode, format: format)
        sourceNode = node
    }

    // MARK: - Producer thread

    private func startProducer() {
        guard producer == nil else { return }
        producerStop = false
        let t = Thread { [weak self] in
            guard let self else { return }
            self.producerLoop()
        }
        t.name = "sid-producer"
        t.qualityOfService = .userInitiated
        producer = t
        t.start()
    }

    private func stopProducer() throws {
        producerStop = true
        producer?.cancel()
        var spins = 0
        while let t = producer, !t.isFinished, spins < 50 {
            Thread.sleep(forTimeInterval: 0.005)
            spins += 1
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

        while !producerStop {
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
            if vizEnabled {
                for (i, ve) in voiceEngines.enumerated() {
                    let m = ve.render(into: voiceScratch[i], count: n)
                    if m > 0 { voiceTaps[i].append(voiceScratch[i], count: m) }
                }
            }

            // Push main mix to the audio ring. This is the only thing the
            // audio path depends on.
            var written = 0
            while written < n && !producerStop {
                let w = ring.write(scratch.advanced(by: written), count: n - written)
                written += w
                if w == 0 { Thread.sleep(forTimeInterval: 0.001) }
            }
        }
    }
}
