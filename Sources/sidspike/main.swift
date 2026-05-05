import Foundation
import SIDEngine

// Phase 2 spike: load a .sid through the high-level SIDPlayer (producer
// thread + ring buffer + AVAudioEngine) and optionally cycle subtunes.
//
// Usage:
//   sidspike <path.sid>                    # play default subtune for 30s
//   sidspike <path.sid> <seconds>          # play default subtune for <seconds>
//   sidspike <path.sid> <seconds> <subs>   # cycle through <subs> subtunes (~seconds/subs each)

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: sidspike <path.sid> [seconds] [subtunes]\n".utf8))
    exit(2)
}

let path = args[1]
let totalSeconds = TimeInterval(args.count >= 3 ? Double(args[2]) ?? 30 : 30)
let subtunesToCycle = args.count >= 4 ? Int(args[3]) ?? 1 : 1

let player = SIDPlayer(sampleRate: 44_100)

do {
    try player.load(path: path)
} catch {
    FileHandle.standardError.write(Data("load failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}

guard let info = player.info else {
    FileHandle.standardError.write(Data("no tune info\n".utf8))
    exit(1)
}

print("Title:    \(info.title ?? "?")")
print("Author:   \(info.author ?? "?")")
print("Released: \(info.released ?? "?")")
print("Format:   \(info.format ?? "?")  songs: \(info.songCount)  default: \(info.startSong)")
print("Clock:    \(info.clock.displayName)  Model: \(info.model.displayName)  SIDs: \(info.sidChips)")

do {
    try player.play()
} catch {
    FileHandle.standardError.write(Data("play failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}

let perSubtune = totalSeconds / Double(max(subtunesToCycle, 1))
print("Playing for \(Int(totalSeconds))s across \(subtunesToCycle) subtune(s)…")

for i in 0..<subtunesToCycle {
    print("  [sub \(player.currentSong)] \(player.info?.title ?? "?")")
    RunLoop.main.run(until: Date(timeIntervalSinceNow: perSubtune))
    if i < subtunesToCycle - 1 {
        do { try player.nextSong() } catch {
            FileHandle.standardError.write(Data("nextSong failed: \(error.localizedDescription)\n".utf8))
            break
        }
    }
}

player.stop()
print("Done. Final position on last subtune: \(String(format: "%.1f", player.currentTime))s")
