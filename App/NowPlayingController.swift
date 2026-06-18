import Foundation
import MediaPlayer

/// Bridges playback to macOS Now Playing (Control Center, menu-bar widget) and
/// the hardware media keys (F7/F8/F9) via `MPRemoteCommandCenter`. AppState owns
/// one instance, wires the command closures to its transport methods, and calls
/// `update`/`setPlaying`/`clear` as the now-playing metadata or state changes.
///
/// Remote-command events can arrive off the main thread, so each handler hops to
/// the main actor before touching the (main-actor) callbacks.
@MainActor
final class NowPlayingController {
    var onPlay: () -> Void = {}
    var onPause: () -> Void = {}
    var onTogglePlayPause: () -> Void = {}
    var onNext: () -> Void = {}
    var onPrevious: () -> Void = {}

    init() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPlay() }; return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPause() }; return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onTogglePlayPause() }; return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onNext() }; return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPrevious() }; return .success
        }
    }

    /// Publish full track metadata. Call on track / subtune change. The system
    /// extrapolates elapsed time from the playback rate, so per-tick updates
    /// aren't needed — only on state changes.
    func update(title: String, artist: String, durationSec: Double,
                elapsedSec: Double, isPlaying: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, elapsedSec),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if durationSec > 0 { info[MPMediaItemPropertyPlaybackDuration] = durationSec }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    /// Lightweight play/pause update that keeps the existing metadata.
    func setPlaying(_ isPlaying: Bool, elapsedSec: Double) {
        let center = MPNowPlayingInfoCenter.default()
        center.playbackState = isPlaying ? .playing : .paused
        if var info = center.nowPlayingInfo {
            info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, elapsedSec)
            center.nowPlayingInfo = info
        }
    }

    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}
