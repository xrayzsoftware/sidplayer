import SwiftUI

/// VSCode-inspired theme tokens. Every color used by chrome / visualizers
/// pulls from one of these slots so flipping a theme retones the whole app.
public struct AppTheme: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String

    // Surfaces
    public let windowBackground: Color
    public let panelBackground: Color
    public let visualizerBackground: Color

    // Text
    public let textPrimary: Color
    public let textSecondary: Color
    public let textAccent: Color

    // Chrome
    public let separator: Color
    public let selection: Color

    // Visualizers
    public let waveform: Color
    public let voice1: Color
    public let voice2: Color
    public let voice3: Color
    /// Bottom-to-top gradient stops for the peak meter bars.
    public let peakGradient: [Color]
    public let peakCap: Color
    public let peakCapHot: Color
    public let scrollerText: Color

    // Misc
    public let star: Color

    /// Drives NSWindow.appearance so the title bar uses dark or light system
    /// chrome to match the theme. The theme color is then layered on top.
    public var isDark: Bool {
        switch id {
        case "solarizedLight", "githubLight", "atomOneLight", "catppuccinLatte":
            return false
        default:
            return true
        }
    }
}

public extension AppTheme {
    static let allPresets: [AppTheme] = [
        .systemDefault,
        .nord, .tokyoNight, .dracula, .gruvboxDark,
        .catppuccinMocha, .solarizedDark, .monokai,
        .solarizedLight, .githubLight, .atomOneLight, .catppuccinLatte
    ]

    static func preset(id: String) -> AppTheme {
        allPresets.first { $0.id == id } ?? .systemDefault
    }

    // MARK: System default — uses NSColor system colors so it looks native
    static let systemDefault = AppTheme(
        id: "system",
        name: "System Default",
        windowBackground: Color(nsColor: .windowBackgroundColor),
        panelBackground:  Color(nsColor: .controlBackgroundColor),
        visualizerBackground: .black,
        textPrimary:      .primary,
        textSecondary:    .secondary,
        textAccent:       Color.accentColor,
        separator:        Color(nsColor: .separatorColor),
        selection:        Color.accentColor.opacity(0.30),
        waveform:         Color(red: 0.55, green: 0.95, blue: 0.45),
        voice1:           Color(red: 0.55, green: 0.95, blue: 0.45),
        voice2:           Color(red: 0.45, green: 0.75, blue: 1.00),
        voice3:           Color(red: 1.00, green: 0.65, blue: 0.45),
        peakGradient: [
            Color(red: 0.20, green: 0.85, blue: 0.30),
            Color(red: 0.55, green: 0.95, blue: 0.30),
            Color(red: 1.00, green: 0.85, blue: 0.20),
            Color(red: 1.00, green: 0.30, blue: 0.20)
        ],
        peakCap:    Color.white.opacity(0.85),
        peakCapHot: Color(red: 1.0, green: 0.4, blue: 0.3),
        scrollerText: Color(red: 0.55, green: 0.95, blue: 0.45),
        star: .yellow
    )

    static let nord = AppTheme(
        id: "nord", name: "Nord",
        windowBackground:     Color(hex: 0x2E3440),
        panelBackground:      Color(hex: 0x3B4252),
        visualizerBackground: Color(hex: 0x242933),
        textPrimary:   Color(hex: 0xECEFF4),
        textSecondary: Color(hex: 0x81A1C1),
        textAccent:    Color(hex: 0x88C0D0),
        separator:     Color(hex: 0x4C566A),
        selection:     Color(hex: 0x5E81AC).opacity(0.55),
        waveform:      Color(hex: 0xA3BE8C),
        voice1:        Color(hex: 0xA3BE8C),  // green
        voice2:        Color(hex: 0x88C0D0),  // cyan
        voice3:        Color(hex: 0xD08770),  // orange
        peakGradient: [
            Color(hex: 0x8FBCBB), Color(hex: 0xA3BE8C),
            Color(hex: 0xEBCB8B), Color(hex: 0xBF616A)
        ],
        peakCap:    Color(hex: 0xECEFF4),
        peakCapHot: Color(hex: 0xBF616A),
        scrollerText: Color(hex: 0xA3BE8C),
        star: Color(hex: 0xEBCB8B)
    )

    static let tokyoNight = AppTheme(
        id: "tokyoNight", name: "Tokyo Night",
        windowBackground:     Color(hex: 0x1A1B26),
        panelBackground:      Color(hex: 0x16161E),
        visualizerBackground: Color(hex: 0x16161E),
        textPrimary:   Color(hex: 0xC0CAF5),
        textSecondary: Color(hex: 0x565F89),
        textAccent:    Color(hex: 0x7AA2F7),
        separator:     Color(hex: 0x292E42),
        selection:     Color(hex: 0x3D59A1).opacity(0.55),
        waveform:      Color(hex: 0x9ECE6A),
        voice1:        Color(hex: 0x9ECE6A),  // green
        voice2:        Color(hex: 0x7DCFFF),  // cyan
        voice3:        Color(hex: 0xFF9E64),  // orange
        peakGradient: [
            Color(hex: 0x9ECE6A), Color(hex: 0x7DCFFF),
            Color(hex: 0xE0AF68), Color(hex: 0xF7768E)
        ],
        peakCap:    Color(hex: 0xC0CAF5),
        peakCapHot: Color(hex: 0xF7768E),
        scrollerText: Color(hex: 0xBB9AF7),
        star: Color(hex: 0xE0AF68)
    )

    static let dracula = AppTheme(
        id: "dracula", name: "Dracula",
        windowBackground:     Color(hex: 0x282A36),
        panelBackground:      Color(hex: 0x21222C),
        visualizerBackground: Color(hex: 0x1E1F29),
        textPrimary:   Color(hex: 0xF8F8F2),
        textSecondary: Color(hex: 0x6272A4),
        textAccent:    Color(hex: 0xBD93F9),
        separator:     Color(hex: 0x44475A),
        selection:     Color(hex: 0x44475A),
        waveform:      Color(hex: 0x50FA7B),
        voice1:        Color(hex: 0x50FA7B),
        voice2:        Color(hex: 0x8BE9FD),
        voice3:        Color(hex: 0xFF79C6),
        peakGradient: [
            Color(hex: 0x50FA7B), Color(hex: 0x8BE9FD),
            Color(hex: 0xF1FA8C), Color(hex: 0xFF5555)
        ],
        peakCap:    Color(hex: 0xF8F8F2),
        peakCapHot: Color(hex: 0xFF5555),
        scrollerText: Color(hex: 0x8BE9FD),
        star: Color(hex: 0xF1FA8C)
    )

    static let gruvboxDark = AppTheme(
        id: "gruvbox", name: "Gruvbox Dark",
        windowBackground:     Color(hex: 0x282828),
        panelBackground:      Color(hex: 0x3C3836),
        visualizerBackground: Color(hex: 0x1D2021),
        textPrimary:   Color(hex: 0xEBDBB2),
        textSecondary: Color(hex: 0x928374),
        textAccent:    Color(hex: 0xFE8019),
        separator:     Color(hex: 0x504945),
        selection:     Color(hex: 0xFE8019).opacity(0.30),
        waveform:      Color(hex: 0xB8BB26),
        voice1:        Color(hex: 0xB8BB26),
        voice2:        Color(hex: 0x83A598),
        voice3:        Color(hex: 0xFE8019),
        peakGradient: [
            Color(hex: 0xB8BB26), Color(hex: 0xFABD2F),
            Color(hex: 0xFE8019), Color(hex: 0xFB4934)
        ],
        peakCap:    Color(hex: 0xFBF1C7),
        peakCapHot: Color(hex: 0xFB4934),
        scrollerText: Color(hex: 0xFABD2F),
        star: Color(hex: 0xFABD2F)
    )

    static let catppuccinMocha = AppTheme(
        id: "catppuccin", name: "Catppuccin Mocha",
        windowBackground:     Color(hex: 0x1E1E2E),
        panelBackground:      Color(hex: 0x181825),
        visualizerBackground: Color(hex: 0x11111B),
        textPrimary:   Color(hex: 0xCDD6F4),
        textSecondary: Color(hex: 0xA6ADC8),
        textAccent:    Color(hex: 0xCBA6F7),
        separator:     Color(hex: 0x313244),
        selection:     Color(hex: 0xB4BEFE).opacity(0.30),
        waveform:      Color(hex: 0xA6E3A1),
        voice1:        Color(hex: 0xA6E3A1),
        voice2:        Color(hex: 0x89B4FA),
        voice3:        Color(hex: 0xFAB387),
        peakGradient: [
            Color(hex: 0xA6E3A1), Color(hex: 0x94E2D5),
            Color(hex: 0xF9E2AF), Color(hex: 0xF38BA8)
        ],
        peakCap:    Color(hex: 0xCDD6F4),
        peakCapHot: Color(hex: 0xF38BA8),
        scrollerText: Color(hex: 0xCBA6F7),
        star: Color(hex: 0xF9E2AF)
    )

    static let solarizedDark = AppTheme(
        id: "solarized", name: "Solarized Dark",
        windowBackground:     Color(hex: 0x002B36),
        panelBackground:      Color(hex: 0x073642),
        visualizerBackground: Color(hex: 0x001F27),
        textPrimary:   Color(hex: 0x93A1A1),
        textSecondary: Color(hex: 0x586E75),
        textAccent:    Color(hex: 0x268BD2),
        separator:     Color(hex: 0x073642),
        selection:     Color(hex: 0x268BD2).opacity(0.30),
        waveform:      Color(hex: 0x859900),
        voice1:        Color(hex: 0x859900),  // green
        voice2:        Color(hex: 0x2AA198),  // cyan
        voice3:        Color(hex: 0xCB4B16),  // orange
        peakGradient: [
            Color(hex: 0x859900), Color(hex: 0x2AA198),
            Color(hex: 0xB58900), Color(hex: 0xDC322F)
        ],
        peakCap:    Color(hex: 0xEEE8D5),
        peakCapHot: Color(hex: 0xDC322F),
        scrollerText: Color(hex: 0x2AA198),
        star: Color(hex: 0xB58900)
    )

    // MARK: - Light themes

    static let solarizedLight = AppTheme(
        id: "solarizedLight", name: "Solarized Light",
        windowBackground:     Color(hex: 0xFDF6E3),
        panelBackground:      Color(hex: 0xEEE8D5),
        visualizerBackground: Color(hex: 0x002B36),  // dark "screen" inset
        textPrimary:   Color(hex: 0x657B83),
        textSecondary: Color(hex: 0x93A1A1),
        textAccent:    Color(hex: 0x268BD2),
        separator:     Color(hex: 0xD8D2BC),
        selection:     Color(hex: 0x268BD2).opacity(0.20),
        waveform:      Color(hex: 0x859900),
        voice1:        Color(hex: 0x859900),  // green
        voice2:        Color(hex: 0x268BD2),  // blue
        voice3:        Color(hex: 0xCB4B16),  // orange
        peakGradient: [
            Color(hex: 0x859900), Color(hex: 0x2AA198),
            Color(hex: 0xB58900), Color(hex: 0xDC322F)
        ],
        peakCap:    Color(hex: 0xFDF6E3),
        peakCapHot: Color(hex: 0xDC322F),
        scrollerText: Color(hex: 0x2AA198),
        star: Color(hex: 0xB58900)
    )

    static let githubLight = AppTheme(
        id: "githubLight", name: "GitHub Light",
        windowBackground:     Color(hex: 0xFFFFFF),
        panelBackground:      Color(hex: 0xF6F8FA),
        visualizerBackground: Color(hex: 0x24292F),
        textPrimary:   Color(hex: 0x1F2328),
        textSecondary: Color(hex: 0x656D76),
        textAccent:    Color(hex: 0x0969DA),
        separator:     Color(hex: 0xD0D7DE),
        selection:     Color(hex: 0x0969DA).opacity(0.18),
        waveform:      Color(hex: 0x1A7F37),
        voice1:        Color(hex: 0x1A7F37),  // green
        voice2:        Color(hex: 0x0969DA),  // blue
        voice3:        Color(hex: 0xBC4C00),  // orange
        peakGradient: [
            Color(hex: 0x1A7F37), Color(hex: 0x0969DA),
            Color(hex: 0x9A6700), Color(hex: 0xD1242F)
        ],
        peakCap:    Color(hex: 0xFFFFFF),
        peakCapHot: Color(hex: 0xD1242F),
        scrollerText: Color(hex: 0x8250DF),
        star: Color(hex: 0xBF8700)
    )

    static let atomOneLight = AppTheme(
        id: "atomOneLight", name: "Atom One Light",
        windowBackground:     Color(hex: 0xFAFAFA),
        panelBackground:      Color(hex: 0xF0F0F0),
        visualizerBackground: Color(hex: 0x282C34),
        textPrimary:   Color(hex: 0x383A42),
        textSecondary: Color(hex: 0xA0A1A7),
        textAccent:    Color(hex: 0x4078F2),
        separator:     Color(hex: 0xE5E5E6),
        selection:     Color(hex: 0x4078F2).opacity(0.18),
        waveform:      Color(hex: 0x50A14F),
        voice1:        Color(hex: 0x50A14F),  // green
        voice2:        Color(hex: 0x4078F2),  // blue
        voice3:        Color(hex: 0xE45649),  // red-orange
        peakGradient: [
            Color(hex: 0x50A14F), Color(hex: 0x0184BC),
            Color(hex: 0xC18401), Color(hex: 0xE45649)
        ],
        peakCap:    Color(hex: 0xFAFAFA),
        peakCapHot: Color(hex: 0xE45649),
        scrollerText: Color(hex: 0xA626A4),
        star: Color(hex: 0xC18401)
    )

    static let catppuccinLatte = AppTheme(
        id: "catppuccinLatte", name: "Catppuccin Latte",
        windowBackground:     Color(hex: 0xEFF1F5),
        panelBackground:      Color(hex: 0xE6E9EF),
        visualizerBackground: Color(hex: 0x4C4F69),
        textPrimary:   Color(hex: 0x4C4F69),
        textSecondary: Color(hex: 0x6C6F85),
        textAccent:    Color(hex: 0x8839EF),
        separator:     Color(hex: 0xCCD0DA),
        selection:     Color(hex: 0x8839EF).opacity(0.20),
        waveform:      Color(hex: 0x40A02B),
        voice1:        Color(hex: 0x40A02B),  // green
        voice2:        Color(hex: 0x1E66F5),  // blue
        voice3:        Color(hex: 0xFE640B),  // peach
        peakGradient: [
            Color(hex: 0x40A02B), Color(hex: 0x179299),
            Color(hex: 0xDF8E1D), Color(hex: 0xD20F39)
        ],
        peakCap:    Color(hex: 0xEFF1F5),
        peakCapHot: Color(hex: 0xD20F39),
        scrollerText: Color(hex: 0x8839EF),
        star: Color(hex: 0xDF8E1D)
    )

    // MARK: - Dark themes (continued)

    static let monokai = AppTheme(
        id: "monokai", name: "Monokai",
        windowBackground:     Color(hex: 0x272822),
        panelBackground:      Color(hex: 0x1E1F1C),
        visualizerBackground: Color(hex: 0x1B1C18),
        textPrimary:   Color(hex: 0xF8F8F2),
        textSecondary: Color(hex: 0x75715E),
        textAccent:    Color(hex: 0xF92672),
        separator:     Color(hex: 0x49483E),
        selection:     Color(hex: 0xF92672).opacity(0.25),
        waveform:      Color(hex: 0xA6E22E),
        voice1:        Color(hex: 0xA6E22E),
        voice2:        Color(hex: 0x66D9EF),
        voice3:        Color(hex: 0xFD971F),
        peakGradient: [
            Color(hex: 0xA6E22E), Color(hex: 0x66D9EF),
            Color(hex: 0xE6DB74), Color(hex: 0xF92672)
        ],
        peakCap:    Color(hex: 0xF8F8F2),
        peakCapHot: Color(hex: 0xF92672),
        scrollerText: Color(hex: 0xA6E22E),
        star: Color(hex: 0xE6DB74)
    )
}

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >>  8) & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
