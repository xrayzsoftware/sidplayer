import Foundation
import AVFoundation

/// High-level playback controller. Wraps `SIDPlayerEngine` with:
///  - a producer thread that calls the SID emulator off the audio render thread
///  - an `AVAudioEngine` graph that drains a `RingBuffer`
///  - play/pause + subtune navigation
public final class SIDPlayer: @unchecked Sendable {
    public let engine: SIDPlayerEngine
    public let sampleRate: Double

    private let av = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var ring: RingBuffer
    private var producer: Thread?
    private var producerStop = false
    private var paused = true

    public init(sampleRate: Double = 44_100, ringCapacity: Int = 1 << 15 /* 32k samples ≈ 0.74s */) {
        self.engine = SIDPlayerEngine()
        self.sampleRate = sampleRate
        self.ring = RingBuffer(capacity: ringCapacity)
    }

    deinit {
        stop()
    }

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
        engine.stop()
        ring.clear()
    }

    public func nextSong() throws {
        try stopProducer()
        ring.clear()
        try engine.nextSong()
        if !paused { startProducer() }
    }

    public func previousSong() throws {
        try stopProducer()
        ring.clear()
        try engine.previousSong()
        if !paused { startProducer() }
    }

    public func select(song: Int) throws {
        try stopProducer()
        ring.clear()
        try engine.select(song: song)
        if !paused { startProducer() }
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

        let ringRef = ring  // captured by reference (class)
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
            let bufList = UnsafeMutableAudioBufferListPointer(abl)
            guard let dest = bufList[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }

            let n = Int(frameCount)
            let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: n)
            defer { scratch.deallocate() }

            let read = ringRef.read(scratch, count: n)
            for i in 0..<read {
                dest[i] = Float(scratch[i]) / 32768.0
            }
            if read < n {
                dest.advanced(by: read).update(repeating: 0, count: n - read)
            }
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
        // Spin briefly waiting for thread to exit. Thread joins via running flag.
        var spins = 0
        while let t = producer, !t.isFinished, spins < 50 {
            Thread.sleep(forTimeInterval: 0.005)
            spins += 1
        }
        producer = nil
    }

    private func producerLoop() {
        let chunk = 2048
        let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: chunk)
        defer { scratch.deallocate() }

        while !producerStop {
            // Stay ahead by ~half the ring; sleep otherwise.
            if ring.freeSpace < chunk {
                Thread.sleep(forTimeInterval: 0.002)
                continue
            }
            let n = engine.render(into: scratch, count: chunk)
            if n == 0 {
                // Engine drained or errored — back off briefly so we don't busy-loop.
                Thread.sleep(forTimeInterval: 0.010)
                continue
            }
            var written = 0
            while written < n && !producerStop {
                let w = ring.write(scratch.advanced(by: written), count: n - written)
                written += w
                if w == 0 { Thread.sleep(forTimeInterval: 0.001) }
            }
        }
    }
}
