import Foundation
import AVFoundation
import SIDEngine

// Phase 1 spike: load a .sid, print metadata, play it through AVAudioEngine.
//
// Caveat: the SID is rendered inside the audio render callback. libsidplayfp
// is not real-time-safe (allocates, takes locks), so dropouts are possible.
// Phase 2 will move rendering to a producer thread + lock-free ring buffer.

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: sidspike <path/to/file.sid> [seconds]\n".utf8))
    exit(2)
}

let path = args[1]
let seconds = TimeInterval(args.count >= 3 ? Double(args[2]) ?? 30 : 30)

let engine = SIDPlayerEngine()

do {
    try engine.load(path: path)
} catch {
    FileHandle.standardError.write(Data("load failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}

guard let info = engine.info else {
    FileHandle.standardError.write(Data("no tune info\n".utf8))
    exit(1)
}

print("Title:    \(info.title ?? "?")")
print("Author:   \(info.author ?? "?")")
print("Released: \(info.released ?? "?")")
print("Format:   \(info.format ?? "?")  songs: \(info.songCount)  default: \(info.startSong)")
print("Clock:    \(info.clock.displayName)  Model: \(info.model.displayName)  SIDs: \(info.sidChips)")
print("MD5:      \(info.md5 ?? "?")")

let sampleRate: Double = 44100
do {
    try engine.start(song: info.startSong, sampleRate: Int(sampleRate))
} catch {
    FileHandle.standardError.write(Data("start failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}

guard let format = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: sampleRate,
    channels: 1,
    interleaved: false
) else {
    FileHandle.standardError.write(Data("audio format init failed\n".utf8))
    exit(1)
}

let av = AVAudioEngine()
let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
    let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
    guard let dest = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }

    let n = Int(frameCount)
    let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: n)
    defer { scratch.deallocate() }

    let written = engine.render(into: scratch, count: n)

    for i in 0..<written {
        dest[i] = Float(scratch[i]) / 32768.0
    }
    if written < n {
        dest.advanced(by: written).update(repeating: 0, count: n - written)
    }
    return noErr
}

av.attach(source)
av.connect(source, to: av.mainMixerNode, format: format)

do {
    try av.start()
} catch {
    FileHandle.standardError.write(Data("audio engine start failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}

print("Playing for \(Int(seconds))s. Ctrl+C to stop.")
RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))

av.stop()
engine.stop()
print("Done. Final position: \(String(format: "%.1f", engine.currentTime))s")
