import Foundation
import SIDEngine
import WinampSkin

/// Winamp view: which skin is loaded and how the window is laid out.
/// The stored properties live in AppState itself (an @Observable class cannot
/// declare them in an extension).
extension AppState {
    private static let winampSkinKey     = "winamp.skin"
    private static let winampDoubleKey   = "winamp.doubleSize"
    private static let winampPlaylistKey = "winamp.showPlaylist"
    private static let winampEqualizerKey = "winamp.showEqualizer"
    private static let winampShadeKey    = "winamp.shade"
    private static let equalizerOnKey     = "equalizer.enabled"
    private static let equalizerPreampKey = "equalizer.preampDB"
    private static let equalizerBandsKey  = "equalizer.bandsDB"

    /// The sliders' range, as printed on the classic skin: +12 dB to -12 dB.
    public static let equalizerRangeDB: Float = 12

    public static let equalizerPresets: [(name: String, bandsDB: [Float])] = [
        ("Flat",         [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("Bass Boost",   [8, 7, 5, 2, 0, 0, 0, 0, 0, 0]),
        ("Treble Boost", [0, 0, 0, 0, 0, 2, 5, 7, 8, 8]),
        ("Loudness",     [6, 4, 1, 0, -1, 0, 1, 4, 6, 6]),
    ]

    /// Skins are copied here on load. The sandbox only lends access to a file
    /// the user picked for as long as the picker's grant lasts; a copy inside
    /// the container can be reopened on every launch.
    var winampSkinsDir: URL {
        let dir = supportDir().appendingPathComponent("skins", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Restores the saved skin and layout. Called when the Winamp window
    /// first opens rather than at launch, so users who never open it pay
    /// nothing for it.
    public func loadWinampSettings() {
        guard !didLoadWinampSettings else { return }
        didLoadWinampSettings = true
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.winampDoubleKey) != nil {
            winampDoubleSize = defaults.bool(forKey: Self.winampDoubleKey)
        }
        if defaults.object(forKey: Self.winampPlaylistKey) != nil {
            winampShowPlaylist = defaults.bool(forKey: Self.winampPlaylistKey)
        }
        winampShowEqualizer = defaults.bool(forKey: Self.winampEqualizerKey)
        winampShade = defaults.bool(forKey: Self.winampShadeKey)
        refreshWinampSkinNames()
        if let name = defaults.string(forKey: Self.winampSkinKey), winampSkinNames.contains(name) {
            // A skin that loaded before and fails now was damaged on disk;
            // fall back to "no skin" and let the window ask for one.
            try? selectWinampSkin(name)
        }
    }

    private func refreshWinampSkinNames() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: winampSkinsDir.path)) ?? []
        winampSkinNames = names
            .filter { ["wsz", "zip"].contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Checks that `url` is a usable skin, copies it into the skins folder
    /// and switches to it. Throws (and changes nothing) if it is not a skin.
    public func installWinampSkin(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let skin = try WinampSkin(wszData: data)
        let name = url.lastPathComponent
        try data.write(to: winampSkinsDir.appendingPathComponent(name), options: .atomic)
        refreshWinampSkinNames()
        useWinampSkin(skin, named: name)
    }

    public func selectWinampSkin(_ name: String) throws {
        let data = try Data(contentsOf: winampSkinsDir.appendingPathComponent(name))
        useWinampSkin(try WinampSkin(wszData: data), named: name)
    }

    private func useWinampSkin(_ skin: WinampSkin, named name: String) {
        winampSkin = skin
        winampSkinName = name
        UserDefaults.standard.set(name, forKey: Self.winampSkinKey)
    }

    public func toggleWinampDoubleSize() {
        winampDoubleSize.toggle()
        UserDefaults.standard.set(winampDoubleSize, forKey: Self.winampDoubleKey)
    }

    public func toggleWinampPlaylist() {
        winampShowPlaylist.toggle()
        UserDefaults.standard.set(winampShowPlaylist, forKey: Self.winampPlaylistKey)
    }

    public func toggleWinampEqualizer() {
        winampShowEqualizer.toggle()
        UserDefaults.standard.set(winampShowEqualizer, forKey: Self.winampEqualizerKey)
    }

    public func toggleWinampShade() {
        winampShade.toggle()
        UserDefaults.standard.set(winampShade, forKey: Self.winampShadeKey)
    }

    // MARK: Equaliser

    /// Called from init, not when the Winamp window opens: a saved equaliser
    /// setting must shape the sound whichever window is in use.
    func loadEqualizer() {
        let defaults = UserDefaults.standard
        equalizerEnabled = defaults.bool(forKey: Self.equalizerOnKey)
        equalizerPreampDB = defaults.float(forKey: Self.equalizerPreampKey)
        if let saved = defaults.array(forKey: Self.equalizerBandsKey) as? [Double],
           saved.count == equalizerBandsDB.count {
            equalizerBandsDB = saved.map(Float.init)
        }
        player.setEqualizer(enabled: equalizerEnabled, preampDB: equalizerPreampDB, bandsDB: equalizerBandsDB)
    }

    private func applyEqualizer() {
        let defaults = UserDefaults.standard
        defaults.set(equalizerEnabled, forKey: Self.equalizerOnKey)
        defaults.set(equalizerPreampDB, forKey: Self.equalizerPreampKey)
        defaults.set(equalizerBandsDB.map(Double.init), forKey: Self.equalizerBandsKey)
        player.setEqualizer(enabled: equalizerEnabled, preampDB: equalizerPreampDB, bandsDB: equalizerBandsDB)
    }

    public func toggleEqualizer() {
        equalizerEnabled.toggle()
        applyEqualizer()
    }

    /// `slider` 0 is the preamp, 1...10 the bands.
    public func setEqualizerGain(slider: Int, to gainDB: Float) {
        let gain = max(-Self.equalizerRangeDB, min(Self.equalizerRangeDB, gainDB))
        if slider == 0 {
            equalizerPreampDB = gain
        } else if equalizerBandsDB.indices.contains(slider - 1) {
            equalizerBandsDB[slider - 1] = gain
        } else {
            return
        }
        applyEqualizer()
    }

    public func applyEqualizerPreset(_ bandsDB: [Float]) {
        guard bandsDB.count == equalizerBandsDB.count else { return }
        equalizerBandsDB = bandsDB
        equalizerPreampDB = 0
        applyEqualizer()
    }
}
