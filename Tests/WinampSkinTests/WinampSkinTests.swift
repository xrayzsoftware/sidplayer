import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import WinampSkin

/// Sheets here are synthetic: every pixel's colour says where it came from
/// (red = x, green = y, blue = which sheet), so a test can read one pixel of
/// a rendered window and know exactly which sprite was drawn there.
final class WinampSkinTests: XCTestCase {
    private static let sheetIDs: [String: UInt8] = [
        "main": 10, "titlebar": 20, "cbuttons": 30, "numbers": 40, "playpaus": 50,
        "monoster": 60, "volume": 70, "posbar": 80, "shufrep": 90, "text": 100, "pledit": 110, "eqmain": 120,
    ]
    private static let sheetSizes: [String: (Int, Int)] = [
        "main": (275, 116), "titlebar": (344, 87), "cbuttons": (136, 36), "numbers": (99, 13),
        "playpaus": (42, 9), "monoster": (56, 24), "volume": (68, 433), "posbar": (307, 10),
        "shufrep": (92, 85), "text": (155, 18), "pledit": (280, 186), "eqmain": (275, 315),
    ]

    private func sheet(_ name: String) -> Data {
        let (w, h) = Self.sheetSizes[name]!
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                pixels[(y * w + x) * 4 + 0] = UInt8(x % 256)
                pixels[(y * w + x) * 4 + 1] = UInt8(y % 256)
                pixels[(y * w + x) * 4 + 2] = Self.sheetIDs[name]!
            }
        }
        let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.bmp.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func files(without missing: Set<String> = []) -> [String: Data] {
        var files: [String: Data] = [:]
        for name in Self.sheetIDs.keys where !missing.contains(name) {
            files["\(name).bmp"] = sheet(name)
        }
        return files
    }

    /// Colour of one skin pixel of a window rendered at scale 1.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        let data = image.dataProvider!.data! as Data
        let offset = y * image.bytesPerRow + x * 4
        return [data[offset], data[offset + 1], data[offset + 2]]
    }

    private func source(_ sheet: String, _ x: Int, _ y: Int) -> [UInt8] {
        [UInt8(x % 256), UInt8(y % 256), Self.sheetIDs[sheet]!]
    }

    // MARK: Loading

    /// Real skins are zipped with any letter case and often inside a folder;
    /// a loader that only accepted "main.bmp" at the top level would reject
    /// a large share of them.
    func testLoadsArchiveWithMixedCaseNamesInsideAFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inner = dir.appendingPathComponent("My Skin")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try sheet("main").write(to: inner.appendingPathComponent("MAIN.BMP"))
        try sheet("cbuttons").write(to: inner.appendingPathComponent("CButtons.bmp"))
        try "[Text]\nNormal=#102030\nFont=Courier".write(
            to: inner.appendingPathComponent("PLEDIT.TXT"), atomically: true, encoding: .ascii)

        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = dir
        zip.arguments = ["-q", "-r", "skin.wsz", "My Skin"]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)

        let skin = try WinampSkin(wszData: Data(contentsOf: dir.appendingPathComponent("skin.wsz")))
        XCTAssertEqual(Set(skin.sheets.keys), ["main", "cbuttons"])
        XCTAssertEqual(skin.playlistStyle.normal, WinampSkin.RGB(0x10, 0x20, 0x30))
        XCTAssertEqual(skin.playlistStyle.fontName, "Courier")
    }

    func testRejectsFilesThatAreNotSkins() {
        XCTAssertThrowsError(try WinampSkin(wszData: Data("not a zip".utf8))) {
            XCTAssertEqual($0 as? WinampSkinError, .notAnArchive)
        }
        XCTAssertThrowsError(try WinampSkin(files: files(without: ["main"]))) {
            XCTAssertEqual($0 as? WinampSkinError, .missingMainBitmap)
        }
    }

    /// A sheet shorter than the sprite asked for must give nothing, not a
    /// clipped sprite: old volume.bmp files stop before the thumb row.
    func testSpriteOutsideItsSheetIsMissing() throws {
        let skin = try WinampSkin(files: files())
        XCTAssertNotNil(skin.sprite("cbuttons", CGRect(x: 114, y: 16, width: 22, height: 16)))
        XCTAssertNil(skin.sprite("cbuttons", CGRect(x: 114, y: 30, width: 22, height: 16)))
        XCTAssertNil(skin.sprite("genex", CGRect(x: 0, y: 0, width: 1, height: 1)))
    }

    func testVisColorsKeepDefaultsForLinesTheFileLeavesOut() {
        let colors = WinampSkin.parseVisColors("1,2,3, // background\n\n 40 , 50 , 60\n")
        XCTAssertEqual(colors.count, 24)
        XCTAssertEqual(colors[0], WinampSkin.RGB(1, 2, 3))
        XCTAssertEqual(colors[1], WinampSkin.RGB(40, 50, 60))
        XCTAssertEqual(colors[2], WinampSkin.defaultVisColors[2])
    }

    // MARK: Main window

    func testBackgroundAndTitleBarFollowWindowFocus() throws {
        let skin = try WinampSkin(files: files())
        var model = MainWindowModel()
        model.isActive = true
        var image = try XCTUnwrap(MainWindow.render(model, skin: skin, scale: 1))
        XCTAssertEqual(pixel(image, 100, 5), source("titlebar", 127, 5))
        XCTAssertEqual(pixel(image, 2, 110), source("main", 2, 110))
        model.isActive = false
        image = try XCTUnwrap(MainWindow.render(model, skin: skin, scale: 1))
        XCTAssertEqual(pixel(image, 100, 5), source("titlebar", 127, 20))
    }

    /// The pushed-in picture of a button is the same column, 18 rows down.
    func testHeldButtonIsDrawnPushedIn() throws {
        let skin = try WinampSkin(files: files())
        var model = MainWindowModel()
        var image = try XCTUnwrap(MainWindow.render(model, skin: skin, scale: 1))
        XCTAssertEqual(pixel(image, 40, 90), source("cbuttons", 24, 2))
        model.pressed = .play
        image = try XCTUnwrap(MainWindow.render(model, skin: skin, scale: 1))
        XCTAssertEqual(pixel(image, 40, 90), source("cbuttons", 24, 20))
        XCTAssertEqual(pixel(image, 63, 90), source("cbuttons", 47, 2), "only the held button moves")
    }

    func testTimeDigitsComeFromTheDigitStrip() throws {
        let skin = try WinampSkin(files: files())
        var model = MainWindowModel()
        model.status = .playing
        model.timeSeconds = 12 * 60 + 34
        let image = try XCTUnwrap(MainWindow.render(model, skin: skin, scale: 1))
        for (digit, x) in zip([1, 2, 3, 4], [48, 60, 78, 90]) {
            XCTAssertEqual(pixel(image, x, 26), source("numbers", digit * 9, 0))
        }
        model.timeSeconds = nil
        let hidden = try XCTUnwrap(MainWindow.render(model, skin: skin, scale: 1))
        XCTAssertEqual(pixel(hidden, 48, 26), source("main", 48, 26), "no time: the background shows")
    }

    /// The thumb must sit where volume(atX:) says a click lands, or dragging
    /// would make the thumb jump away from the mouse.
    func testVolumeThumbTracksTheMouse() throws {
        let skin = try WinampSkin(files: files())
        XCTAssertEqual(MainWindow.volume(atX: 107), 0)
        XCTAssertEqual(MainWindow.volume(atX: 175), 1)
        for volume in [0.0, 0.5, 1.0] {
            var model = MainWindowModel()
            model.volume = volume
            let image = try XCTUnwrap(MainWindow.render(model, skin: skin, scale: 1))
            let thumbLeft = 107 + Int((volume * 51).rounded())
            XCTAssertEqual(pixel(image, thumbLeft, 58), source("volume", 15, 422))
            XCTAssertEqual(MainWindow.volume(atX: CGFloat(thumbLeft + 7)), volume, accuracy: 0.011)
        }
    }

    func testEveryControlIsHitAtItsCentreAndTheTitleStripDrags() {
        XCTAssertEqual(MainWindow.control(at: CGPoint(x: 50, y: 97)), .play)
        XCTAssertEqual(MainWindow.control(at: CGPoint(x: 268, y: 7)), .close)
        XCTAssertEqual(MainWindow.control(at: CGPoint(x: 253, y: 64)), .playlist)
        XCTAssertNil(MainWindow.control(at: CGPoint(x: 150, y: 50)))
        XCTAssertTrue(MainWindow.isDragStrip(CGPoint(x: 120, y: 6)))
        XCTAssertFalse(MainWindow.isDragStrip(CGPoint(x: 268, y: 7)), "the close button is not a drag handle")
        XCTAssertFalse(MainWindow.isDragStrip(CGPoint(x: 120, y: 20)))
    }

    /// A long title scrolls as an endless loop with a separator; a short one
    /// stays put however far the scroll counter has run.
    func testTitleScrollsOnlyWhenItDoesNotFit() {
        XCTAssertEqual(String(MainWindow.titleWindow("Commando", offset: 5)), "commando")
        XCTAssertEqual(MainWindow.marqueeLength("Commando"), 1)

        let long = "The Last Ninja - Wastelands (Ben Daglish & Anthony Lees)"
        let length = MainWindow.marqueeLength(long)
        XCTAssertEqual(length, long.count + 7)
        let first = MainWindow.titleWindow(long, offset: 0)
        XCTAssertEqual(first.count, MainWindow.titleColumns)
        XCTAssertEqual(String(first), "the last ninja - wastelands (be")
        XCTAssertEqual(MainWindow.titleWindow(long, offset: length), first, "one full lap returns to the start")
        XCTAssertEqual(String(MainWindow.titleWindow(long, offset: long.count).prefix(10)), "  ***  the")
    }

    func testAccentsFallBackToPlainLettersAndUnknownsToSpace() {
        XCTAssertEqual(String(SkinText.normalized("Café ☃ Ö")), "cafe   ö")
    }

    func testRenderScaleMultipliesPixelSize() throws {
        let skin = try WinampSkin(files: files())
        let image = try XCTUnwrap(MainWindow.render(MainWindowModel(), skin: skin, scale: 3))
        XCTAssertEqual(image.width, 275 * 3)
        XCTAssertEqual(image.height, 116 * 3)
    }

    // MARK: Shade mode

    /// Rolled up, the window is 14 pixels tall and its controls move into
    /// the title bar — the full-size hit map must not be used there, or a
    /// click on the tiny play button would hit nothing (or the wrong thing).
    func testShadeModeIsOneTitleBarWithItsOwnControls() throws {
        let skin = try WinampSkin(files: files())
        var model = MainWindowModel()
        model.shaded = true
        model.status = .playing
        model.timeSeconds = 65
        let image = try XCTUnwrap(MainWindow.render(model, skin: skin, scale: 1))
        XCTAssertEqual(image.height, 14)
        XCTAssertEqual(pixel(image, 100, 5), source("titlebar", 127, 34), "the lit shade bar, not the normal one")
        XCTAssertEqual(pixel(image, 134, 4), source("text", 0, 6), "minutes tens: glyph 0 of the digit row")
        XCTAssertEqual(pixel(image, 139, 4), source("text", 5, 6))

        XCTAssertEqual(MainWindow.control(at: CGPoint(x: 180, y: 6), shaded: true), .play)
        XCTAssertNil(MainWindow.control(at: CGPoint(x: 180, y: 6)), "no play button there at full size")
        XCTAssertTrue(MainWindow.isDragStrip(CGPoint(x: 60, y: 6), shaded: true))
        XCTAssertFalse(MainWindow.isDragStrip(CGPoint(x: 180, y: 6), shaded: true))
    }

    // MARK: Equaliser

    /// The thumb must be drawn where sliderValue(atY:) says a press lands,
    /// and the centre of the groove must be "no change".
    func testEqualizerSlidersMapBothWays() throws {
        let skin = try WinampSkin(files: files())
        XCTAssertEqual(EqualizerWindow.sliderValue(atY: 38), 1)
        XCTAssertEqual(EqualizerWindow.sliderValue(atY: 101), 0)
        XCTAssertEqual(EqualizerWindow.sliderValue(atY: 69), 0.5, accuracy: 0.01)

        var model = EqualizerModel()
        model.bands[0] = 1
        model.bands[9] = 0
        let image = try XCTUnwrap(EqualizerWindow.render(model, skin: skin, scale: 1))
        XCTAssertEqual(pixel(image, 79, 38), source("eqmain", 0, 164), "band 1 thumb at the top")
        XCTAssertEqual(pixel(image, 78 + 9 * 18 + 1, 38 + 51), source("eqmain", 0, 164), "band 10 thumb at the bottom")
        // Groove picture 27 is the last of the second row; picture 0 the first of the first.
        XCTAssertEqual(pixel(image, 78, 38 + 30), source("eqmain", 13 + 13 * 15, 164 + 65 + 30))
        XCTAssertEqual(pixel(image, 78 + 9 * 18, 38), source("eqmain", 13, 164))
    }

    func testEqualizerControlsAndOnButtonState() throws {
        let skin = try WinampSkin(files: files())
        XCTAssertEqual(EqualizerWindow.control(at: CGPoint(x: 25, y: 60)), .slider(0))
        XCTAssertEqual(EqualizerWindow.control(at: CGPoint(x: 80, y: 60)), .slider(1))
        XCTAssertEqual(EqualizerWindow.control(at: CGPoint(x: 78 + 9 * 18 + 5, y: 60)), .slider(10))
        XCTAssertNil(EqualizerWindow.control(at: CGPoint(x: 93, y: 60)), "the gap between two sliders")
        XCTAssertEqual(EqualizerWindow.control(at: CGPoint(x: 20, y: 22)), .on)
        XCTAssertEqual(EqualizerWindow.control(at: CGPoint(x: 230, y: 22)), .presets)

        var model = EqualizerModel()
        var image = try XCTUnwrap(EqualizerWindow.render(model, skin: skin, scale: 1))
        XCTAssertEqual(pixel(image, 14, 18), source("eqmain", 10, 119))
        model.enabled = true
        image = try XCTUnwrap(EqualizerWindow.render(model, skin: skin, scale: 1))
        XCTAssertEqual(pixel(image, 14, 18), source("eqmain", 69, 119))
    }

    /// The curve must pass through each band's own value, or the picture
    /// would disagree with the sliders beneath it.
    func testEqualizerCurvePassesThroughTheBands() {
        let points: [Double] = [0, 18, 9, 3, 12, 6, 0, 18, 9, 9]
        for (index, value) in points.enumerated() {
            XCTAssertEqual(EqualizerWindow.curve(points, at: Double(index)), value, accuracy: 1e-9)
        }
    }

    // MARK: Playlist

    func testPlaylistGeometry() {
        XCTAssertEqual(PlaylistWindow.height(units: 6), 232)
        XCTAssertEqual(PlaylistWindow.visibleRows(units: 6), 13)
        XCTAssertEqual(PlaylistWindow.row(at: CGPoint(x: 100, y: 20), units: 6), 0)
        XCTAssertEqual(PlaylistWindow.row(at: CGPoint(x: 100, y: 46), units: 6), 2)
        XCTAssertNil(PlaylistWindow.row(at: CGPoint(x: 100, y: 10), units: 6), "the title bar is not a row")
        XCTAssertNil(PlaylistWindow.row(at: CGPoint(x: 265, y: 46), units: 6), "the scroll bar is not a row")
        XCTAssertTrue(PlaylistWindow.isScrollBar(CGPoint(x: 263, y: 46), units: 6))
        XCTAssertEqual(PlaylistWindow.scrollFraction(atY: 20, units: 6), 0)
        XCTAssertEqual(PlaylistWindow.scrollFraction(atY: 194, units: 6), 1)
    }

    func testPlaylistFrameAndSelectionColours() throws {
        var texts = files()
        texts["pledit.txt"] = Data("[Text]\nNormalBG=#010203\nSelectedBG=#0A0B0C\n".utf8)
        let skin = try WinampSkin(files: texts)
        var model = PlaylistModel()
        model.entries = [
            .init(text: "", duration: "", isCurrent: false, isSelected: false),
            .init(text: "", duration: "", isCurrent: false, isSelected: true),
        ]
        let image = try XCTUnwrap(PlaylistWindow.render(model, skin: skin, scale: 1))
        XCTAssertEqual(image.height, 232)
        XCTAssertEqual(pixel(image, 3, 3), source("pledit", 3, 3))
        XCTAssertEqual(pixel(image, 3, 200), source("pledit", 3, 78))
        XCTAssertEqual(pixel(image, 100, 25), [1, 2, 3])
        XCTAssertEqual(pixel(image, 100, 38), [10, 11, 12])
    }

    // MARK: Real skins (manual)

    /// Renders every .wsz in $WINAMP_SKIN_DIR to PNGs in $WINAMP_OUT_DIR, to
    /// check real skins by eye. Skipped unless both are set: skins are other
    /// people's artwork and are not kept in this repository.
    func testRenderRealSkinsForInspection() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let skinDir = environment["WINAMP_SKIN_DIR"], let outDir = environment["WINAMP_OUT_DIR"] else {
            throw XCTSkip("set WINAMP_SKIN_DIR and WINAMP_OUT_DIR to render real skins")
        }
        var main = MainWindowModel()
        main.status = .playing
        main.timeSeconds = 83
        main.title = "1. Commando - Rob Hubbard (4:56)  6581 PAL"
        main.kbps = "1"
        main.khz = "44"
        main.progress = 0.3
        main.shuffle = true
        main.playlistOpen = true
        main.equalizerOpen = true
        var shade = main
        shade.shaded = true
        var equalizer = EqualizerModel()
        equalizer.enabled = true
        equalizer.preamp = 0.6
        equalizer.bands = [0.9, 0.8, 0.65, 0.5, 0.4, 0.35, 0.45, 0.6, 0.75, 0.85]
        main.bars = (0..<19).map { Float(19 - $0) / 19 }
        main.peaks = (0..<19).map { min(1, Float(21 - $0) / 19) }
        var list = PlaylistModel()
        list.entries = (1...13).map {
            .init(text: "\($0). Tune number \($0) - A Composer With A Long Name And Then Some More",
                  duration: "3:0\($0 % 10)", isCurrent: $0 == 2, isSelected: $0 == 4)
        }
        list.scrollFraction = 0.25
        let skins = try FileManager.default.contentsOfDirectory(atPath: skinDir).filter { $0.hasSuffix(".wsz") }
        XCTAssertFalse(skins.isEmpty)
        for name in skins.sorted() {
            let skin = try WinampSkin(wszData: Data(contentsOf: URL(fileURLWithPath: skinDir).appendingPathComponent(name)))
            for (suffix, image) in [("main", MainWindow.render(main, skin: skin, scale: 2)),
                                    ("shade", MainWindow.render(shade, skin: skin, scale: 2)),
                                    ("eq", EqualizerWindow.render(equalizer, skin: skin, scale: 2)),
                                    ("list", PlaylistWindow.render(list, skin: skin, scale: 2))] {
                let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(name)-\(suffix).png")
                let destination = try XCTUnwrap(
                    CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, try XCTUnwrap(image), nil)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
        }
    }
}
