import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SIDCatalog
import SIDEngine
import WinampSkin

/// The Winamp view: a classic skin's main window with the equaliser and the
/// playlist docked underneath, drawn from the bitmaps of a .wsz file.
///
/// One plain NSView instead of SwiftUI controls, because a skin is not made
/// of controls — it is a picture, and every button is a rectangle of it. The
/// view turns AppState into one plain model per pane thirty times a second
/// and redraws a pane only when its model changed.
final class WinampSkinView: NSView {
    private let state: AppState
    private var timer: Timer?
    private var frameCount = 0

    // What is on screen, and the inputs it was drawn from.
    private var mainImage: CGImage?
    private var listImage: CGImage?
    private var equalizerImage: CGImage?
    private var drawnMain: MainWindowModel?
    private var drawnEqualizer: EqualizerModel?
    private var drawnList: PlaylistModel?
    private var drawnSkin: WinampSkin?
    private var drawnScale = 0

    // Mouse.
    private var heldControl: MainWindowModel.Control?
    private var heldIsInside = false
    private var heldEqualizerControl: EqualizerModel.Control?
    private var heldEqualizerIsInside = false
    private var draggingScrollBar = false

    private var showRemaining = false
    private var marqueeOffset = 0
    private var marqueeTitle = ""
    private var titleRow: TuneRow?
    private var titleRowID: Int64?

    private var firstRow = 0
    private var selectedID: Int64?
    private var followedID: Int64?
    private let listUnits = 6

    private let analyser = WinampAnalyser()

    init(state: AppState) {
        self.state = state
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("WinampSkinView is created in code") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// A click on the skin acts at once, even if the window was in the
    /// background — there is no system title bar to click first.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Layout

    private var zoom: CGFloat { state.winampDoubleSize ? 2 : 1 }
    private var showsList: Bool { state.winampSkin != nil && state.winampShowPlaylist }
    /// Skins older than Winamp's equaliser have no eqmain.bmp to draw it from.
    private var showsEqualizer: Bool {
        state.winampShowEqualizer && state.winampSkin?.sheets["eqmain"] != nil
    }

    private enum Pane { case main, equalizer, list }

    /// The panes from the top down, with each one's top edge and height in
    /// skin pixels.
    private var panes: [(pane: Pane, top: Int, height: Int)] {
        var result: [(Pane, Int, Int)] = []
        var top = 0
        func add(_ pane: Pane, _ height: Int) {
            result.append((pane, top, height))
            top += height
        }
        add(.main, state.winampShade ? MainWindow.shadeHeight : MainWindow.height)
        if showsEqualizer { add(.equalizer, EqualizerWindow.height) }
        if showsList { add(.list, PlaylistWindow.height(units: listUnits)) }
        return result
    }

    var contentSize: NSSize {
        // With no skin the window is a fixed double-size panel asking for one.
        guard state.winampSkin != nil else {
            return NSSize(width: MainWindow.width * 2, height: MainWindow.height * 2)
        }
        let rows = panes.reduce(0) { $0 + $1.height }
        return NSSize(width: CGFloat(MainWindow.width) * zoom, height: CGFloat(rows) * zoom)
    }

    /// Resize the window to the skin, keeping its top-left corner where it is
    /// (the playlist opens downward, as in Winamp).
    func fitWindow() {
        guard let window else { return }
        let size = contentSize
        guard window.frame.size != size else { return }
        var frame = window.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        window.setFrame(frame, display: true)
        needsDisplay = true
    }

    // MARK: Ticking

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common so the display keeps moving while a menu is open or the
        // window is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        guard let window, window.isVisible else { return }
        fitWindow()
        guard let skin = state.winampSkin else {
            if drawnSkin != nil { drawnSkin = nil; needsDisplay = true }
            return
        }
        frameCount += 1
        if state.isPlaying {
            analyser.tick(tap: state.player.vizTap)
        } else {
            analyser.decay()
        }

        let scale = max(1, Int((zoom * window.backingScaleFactor).rounded()))
        let redrawAll = skin !== drawnSkin || scale != drawnScale
        drawnSkin = skin
        drawnScale = scale

        let main = mainModel()
        if redrawAll || main != drawnMain {
            drawnMain = main
            mainImage = MainWindow.render(main, skin: skin, scale: scale)
            needsDisplay = true
        }
        if showsEqualizer {
            let equalizer = equalizerModel()
            if redrawAll || equalizer != drawnEqualizer {
                drawnEqualizer = equalizer
                equalizerImage = EqualizerWindow.render(equalizer, skin: skin, scale: scale)
                needsDisplay = true
            }
        } else {
            drawnEqualizer = nil
            equalizerImage = nil
        }
        if showsList {
            let list = listModel()
            if redrawAll || list != drawnList {
                drawnList = list
                listImage = PlaylistWindow.render(list, skin: skin, scale: scale)
                needsDisplay = true
            }
        } else {
            drawnList = nil
            listImage = nil
        }
    }

    // MARK: Models

    private var currentLengthMs: Int {
        let index = state.currentSubtune - 1
        if index >= 0 && index < state.subtuneLengthsMs.count { return state.subtuneLengthsMs[index] }
        return state.defaultLengthMs
    }

    private static func clock(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// "3. Commando - Rob Hubbard (4:56) [sub 2/19]", Winamp's title format
    /// with the subtune added: a skin has no other place to show it.
    private func titleText() -> String {
        guard let id = state.currentTuneID else { return "SID Player" }
        if titleRowID != id {
            titleRowID = id
            titleRow = try? state.catalog?.tune(id: id)
        }
        var text = ""
        if let position = state.playQueue.firstIndex(of: id) { text += "\(position + 1). " }
        text += titleRow?.title ?? "Unknown"
        if let author = titleRow?.author, !author.isEmpty { text += " - \(author)" }
        if currentLengthMs > 0 { text += " (\(Self.clock(currentLengthMs)))" }
        if state.subtuneCount > 1 { text += " [sub \(state.currentSubtune)/\(state.subtuneCount)]" }
        return text
    }

    private func mainModel() -> MainWindowModel {
        var model = MainWindowModel()
        model.isActive = window?.isKeyWindow ?? false
        if state.currentTuneID == nil || state.isStopped {
            model.status = .stopped
        } else {
            model.status = state.isPlaying ? .playing : .paused
        }

        if model.status != .stopped {
            let elapsed = Int(state.currentTime)
            let length = currentLengthMs / 1000
            if showRemaining && length > 0 {
                model.timeSeconds = max(0, length - elapsed)
                model.timeIsNegative = true
            } else {
                model.timeSeconds = elapsed
            }
            // Paused: the time blinks, one second on and one off.
            if model.status == .paused && Int(Date().timeIntervalSinceReferenceDate) % 2 == 1 {
                model.timeSeconds = nil
            }
            if length > 0 { model.progress = state.currentTime / Double(length) }
        }

        let title = titleText()
        if title != marqueeTitle {
            marqueeTitle = title
            marqueeOffset = 0
        } else if frameCount % 6 == 0 {
            // Five characters a second, wrapped so the counter never grows.
            marqueeOffset = (marqueeOffset + 1) % MainWindow.marqueeLength(title)
        }
        model.title = title
        model.marqueeOffset = marqueeOffset

        // Winamp's bit rate and sample rate fields. A SID tune has neither,
        // so the first shows the tune's frame rate and the second the
        // emulator's output rate.
        switch state.currentTuneClock {
        case .pal:  model.kbps = "50"
        case .ntsc: model.kbps = "60"
        default:    model.kbps = ""
        }
        model.khz = "44"

        model.volume = state.volume
        model.shuffle = state.shuffleEnabled
        model.repeats = state.repeatMode != .off
        model.playlistOpen = state.winampShowPlaylist
        model.equalizerOpen = showsEqualizer
        model.shaded = state.winampShade
        model.pressed = heldIsInside ? heldControl : nil
        model.bars = analyser.bars
        model.peaks = analyser.peaks
        return model
    }

    /// A slider's 0...1 position for a gain in dB, and back. The middle of
    /// the groove is 0 dB.
    private static func sliderValue(_ gainDB: Float) -> Double {
        0.5 + Double(gainDB / AppState.equalizerRangeDB) / 2
    }

    private static func gainDB(_ sliderValue: Double) -> Float {
        let gain = Float(sliderValue - 0.5) * 2 * AppState.equalizerRangeDB
        // The centre is hard to hit by hand at one pixel per half dB.
        return abs(gain) < 0.4 ? 0 : gain
    }

    private func equalizerModel() -> EqualizerModel {
        var model = EqualizerModel()
        model.isActive = window?.isKeyWindow ?? false
        model.enabled = state.equalizerEnabled
        model.preamp = Self.sliderValue(state.equalizerPreampDB)
        model.bands = state.equalizerBandsDB.map(Self.sliderValue)
        model.pressed = heldEqualizerIsInside ? heldEqualizerControl : nil
        return model
    }

    private var visibleRows: Int { PlaylistWindow.visibleRows(units: listUnits) }
    private var lastFirstRow: Int { max(0, state.sortedRows.count - visibleRows) }

    private func listModel() -> PlaylistModel {
        let rows = state.sortedRows
        // When the tune changes, bring it into view once — after that the
        // user is free to scroll away from it.
        if followedID != state.currentTuneID {
            followedID = state.currentTuneID
            if let id = followedID, let index = rows.firstIndex(where: { $0.id == id }),
               !(firstRow..<firstRow + visibleRows).contains(index) {
                firstRow = index - visibleRows / 2
            }
        }
        firstRow = min(max(0, firstRow), lastFirstRow)

        var model = PlaylistModel()
        model.isActive = window?.isKeyWindow ?? false
        model.units = listUnits
        let end = min(rows.count, firstRow + visibleRows)
        model.entries = (firstRow..<end).map { index in
            let item = rows[index]
            var text = "\(index + 1). \(item.row.title ?? "Unknown")"
            if let author = item.row.author, !author.isEmpty { text += " - \(author)" }
            return PlaylistModel.Entry(
                text: text,
                duration: item.row.defaultLengthMs.map(Self.clock) ?? "",
                isCurrent: item.id == state.currentTuneID,
                isSelected: item.id == selectedID
            )
        }
        model.scrollFraction = lastFirstRow > 0 ? Double(firstRow) / Double(lastFirstRow) : 0
        model.scrollPressed = draggingScrollBar
        return model
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard state.winampSkin != nil else {
            drawSkinPrompt()
            return
        }
        // Whole skin pixels only: no smoothing when the bitmap is scaled up.
        context.interpolationQuality = .none
        for (pane, top, height) in panes {
            let image: CGImage?
            switch pane {
            case .main:      image = mainImage
            case .equalizer: image = equalizerImage
            case .list:      image = listImage
            }
            draw(image, in: NSRect(x: 0, y: CGFloat(top) * zoom, width: bounds.width, height: CGFloat(height) * zoom),
                 context: context)
        }
    }

    /// Core Graphics draws images bottom-up; this view counts y downward.
    private func draw(_ image: CGImage?, in rect: NSRect, context: CGContext) {
        guard let image else { return }
        context.saveGState()
        context.translateBy(x: 0, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }

    /// Shown until a skin is loaded. No skin ships with the app: they are
    /// other people's artwork.
    private func drawSkinPrompt() {
        let theme = state.theme
        NSColor(theme.windowBackground).setFill()
        bounds.fill()
        NSColor(theme.separator).setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        func line(_ text: String, size: CGFloat, weight: NSFont.Weight, color: Color, y: CGFloat) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: NSColor(color),
                .paragraphStyle: paragraph,
            ]
            (text as NSString).draw(in: NSRect(x: 16, y: y, width: bounds.width - 32, height: size + 8),
                                    withAttributes: attributes)
        }
        line("Winamp View", size: 20, weight: .semibold, color: theme.textPrimary, y: 62)
        line("Click to choose a classic Winamp skin (.wsz)", size: 13, weight: .regular,
             color: theme.textAccent, y: 104)
        line("or drop one on this window", size: 12, weight: .regular, color: theme.textSecondary, y: 128)
    }

    // MARK: Mouse

    /// The pane under the mouse and the position inside it, in that pane's
    /// own skin pixels. Outside the window (during a drag) the nearest pane.
    private func skinPoint(_ event: NSEvent) -> (pane: Pane, point: CGPoint) {
        let location = convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: location.x / zoom, y: location.y / zoom)
        let layout = panes
        let hit = layout.last { CGFloat($0.top) <= point.y } ?? layout[0]
        return (hit.pane, CGPoint(x: point.x, y: point.y - CGFloat(hit.top)))
    }

    /// Position in one named pane's coordinates, wherever the mouse is.
    private func point(_ event: NSEvent, in pane: Pane) -> CGPoint {
        let location = convert(event.locationInWindow, from: nil)
        let top = panes.first { $0.pane == pane }?.top ?? 0
        return CGPoint(x: location.x / zoom, y: location.y / zoom - CGFloat(top))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard state.winampSkin != nil else {
            // The top strip still moves the window; anywhere else asks for a skin.
            if convert(event.locationInWindow, from: nil).y < 28 {
                window?.performDrag(with: event)
            } else {
                chooseSkin()
            }
            return
        }
        let (pane, point) = skinPoint(event)
        if pane == .equalizer {
            equalizerMouseDown(at: point, event: event)
            return
        }
        if pane == .list {
            if PlaylistWindow.isScrollBar(point, units: listUnits) {
                draggingScrollBar = true
                scrollList(toY: point.y)
            } else if let row = PlaylistWindow.row(at: point, units: listUnits) {
                let index = firstRow + row
                guard index < state.sortedRows.count else { return }
                selectedID = state.sortedRows[index].id
                // Double-click plays. Setting selectedID is the app's single
                // trigger for playback and makes this list the play queue.
                if event.clickCount == 2 { state.selectedID = selectedID }
            } else if PlaylistWindow.isDragStrip(point) {
                window?.performDrag(with: event)
            }
            return
        }
        switch MainWindow.control(at: point, shaded: state.winampShade) {
        case .options:
            showMenu(with: event)
        case .time:
            showRemaining.toggle()
        case .volume:
            heldControl = .volume
            heldIsInside = true
            state.volume = MainWindow.volume(atX: point.x)
        case let control?:
            heldControl = control
            heldIsInside = true
        case nil:
            if MainWindow.isDragStrip(point, shaded: state.winampShade) { window?.performDrag(with: event) }
        }
    }

    private func equalizerMouseDown(at point: CGPoint, event: NSEvent) {
        switch EqualizerWindow.control(at: point) {
        case .presets:
            showPresets(with: event)
        case let .slider(index):
            heldEqualizerControl = .slider(index)
            heldEqualizerIsInside = true
            state.setEqualizerGain(slider: index, to: Self.gainDB(EqualizerWindow.sliderValue(atY: point.y)))
        case let control?:
            heldEqualizerControl = control
            heldEqualizerIsInside = true
        case nil:
            if EqualizerWindow.isDragStrip(point) { window?.performDrag(with: event) }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let (pane, point) = skinPoint(event)
        if draggingScrollBar {
            // The handle keeps following even if the mouse leaves the pane.
            scrollList(toY: self.point(event, in: .list).y)
        } else if case let .slider(index)? = heldEqualizerControl {
            let y = self.point(event, in: .equalizer).y
            state.setEqualizerGain(slider: index, to: Self.gainDB(EqualizerWindow.sliderValue(atY: y)))
        } else if let heldEqualizerControl {
            heldEqualizerIsInside = pane == .equalizer && EqualizerWindow.control(at: point) == heldEqualizerControl
        } else if heldControl == .volume {
            state.volume = MainWindow.volume(atX: point.x)
        } else if let heldControl {
            // Sliding off a held button lets it pop back up, and releasing
            // there cancels the press.
            heldIsInside = pane == .main
                && MainWindow.control(at: point, shaded: state.winampShade) == heldControl
        }
    }

    override func mouseUp(with event: NSEvent) {
        draggingScrollBar = false
        let control = heldIsInside ? heldControl : nil
        heldControl = nil
        heldIsInside = false
        if let control { perform(control) }

        let equalizerControl = heldEqualizerIsInside ? heldEqualizerControl : nil
        heldEqualizerControl = nil
        heldEqualizerIsInside = false
        switch equalizerControl {
        case .on:    state.toggleEqualizer()
        case .close: state.toggleWinampEqualizer()
        // AUTO loaded a preset per song in Winamp; there is nothing for it
        // to do here. Sliders and PRESETS act on mouse down.
        case .auto, .presets, .slider, nil: break
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard showsList, event.scrollingDeltaY != 0 else { return }
        // One row per wheel notch; trackpads report pixels, 13 to a row.
        let rows = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / 13
            : event.scrollingDeltaY
        let step = rows > 0 ? Int(rows.rounded(.up)) : Int(rows.rounded(.down))
        firstRow = min(max(0, firstRow - step), lastFirstRow)
    }

    private func scrollList(toY y: CGFloat) {
        let fraction = PlaylistWindow.scrollFraction(atY: y, units: listUnits)
        firstRow = Int((fraction * Double(lastFirstRow)).rounded())
    }

    override func rightMouseDown(with event: NSEvent) {
        showMenu(with: event)
    }

    private func perform(_ control: MainWindowModel.Control) {
        switch control {
        case .previous:   state.skipBackward()
        case .play:       if !state.isPlaying { state.togglePlayPause() }
        case .pause:      if state.currentTuneID != nil && !state.isStopped { state.togglePlayPause() }
        case .stop:       state.stop()
        case .next:       state.skipForward()
        case .shuffle:    state.toggleShuffle()
        case .repeatMode: state.cycleRepeat()
        case .playlist:   state.toggleWinampPlaylist()
        case .minimize:   window?.miniaturize(nil)
        case .close:      window?.close()
        // Eject opened a file in Winamp; here the library lives in the main window.
        case .eject:      showMainWindow()
        case .equalizer:  state.toggleWinampEqualizer()
        case .shade:      state.toggleWinampShade()
        case .options, .volume, .time:
            break
        }
    }

    private func showMainWindow() {
        let main = NSApp.windows.first {
            $0 !== window && !($0 is NSPanel) && $0.canBecomeMain
                && $0.identifier?.rawValue != "mini-player"
        }
        main?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49:  state.togglePlayPause()     // space
        case 123: state.previousSubtune()     // left arrow
        case 124: state.nextSubtune()         // right arrow
        default:  super.keyDown(with: event)
        }
    }

    // MARK: Menu

    private func showMenu(with event: NSEvent) {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, checked: Bool = false, represented: Any? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = checked ? .on : .off
            item.representedObject = represented
            menu.addItem(item)
        }
        add("Load Skin…", #selector(chooseSkin))
        if !state.winampSkinNames.isEmpty {
            menu.addItem(.separator())
            for name in state.winampSkinNames {
                add((name as NSString).deletingPathExtension, #selector(pickSkin(_:)),
                    checked: name == state.winampSkinName, represented: name)
            }
        }
        menu.addItem(.separator())
        add("Double Size", #selector(toggleDoubleSize), checked: state.winampDoubleSize)
        add("Window Shade", #selector(toggleShade), checked: state.winampShade)
        add("Equalizer", #selector(toggleEqualizerPane), checked: state.winampShowEqualizer)
        add("Playlist", #selector(togglePlaylist), checked: state.winampShowPlaylist)
        menu.addItem(.separator())
        add("Show Main Window", #selector(menuShowMainWindow))
        add("Close Winamp View", #selector(menuClose))
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func chooseSkin() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Winamp Skin"
        panel.allowedContentTypes = [UTType(filenameExtension: "wsz"), UTType.zip].compactMap { $0 }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        install(url)
    }

    @objc private func pickSkin(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        do {
            try state.selectWinampSkin(name)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func toggleDoubleSize() { state.toggleWinampDoubleSize() }
    @objc private func togglePlaylist() { state.toggleWinampPlaylist() }
    @objc private func toggleShade() { state.toggleWinampShade() }
    @objc private func toggleEqualizerPane() { state.toggleWinampEqualizer() }

    private func showPresets(with event: NSEvent) {
        let menu = NSMenu()
        for (index, preset) in AppState.equalizerPresets.enumerated() {
            let item = NSMenuItem(title: preset.name, action: #selector(pickPreset(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func pickPreset(_ sender: NSMenuItem) {
        guard AppState.equalizerPresets.indices.contains(sender.tag) else { return }
        state.applyEqualizerPreset(AppState.equalizerPresets[sender.tag].bandsDB)
    }
    @objc private func menuShowMainWindow() { showMainWindow() }
    @objc private func menuClose() { window?.close() }

    private func install(_ url: URL) {
        do {
            try state.installWinampSkin(from: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: Dropping a skin on the window

    private func droppedSkin(_ sender: NSDraggingInfo) -> URL? {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        return urls?.first { ["wsz", "zip"].contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedSkin(sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = droppedSkin(sender) else { return false }
        install(url)
        return true
    }
}
