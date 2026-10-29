import SwiftUI
import UIKit
import WidgetKit

/// A color that can be stored in the App Group (Color itself isn't Codable).
struct RGBA: Codable, Hashable {
    var r: Double
    var g: Double
    var b: Double

    var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }
    var color: Color { Color(uiColor) }

    init(r: Double, g: Double, b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    init(hex: UInt32) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255)
    }

    init(_ color: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        func clamp(_ v: CGFloat) -> Double { min(max(Double(v), 0), 1) }
        self.init(r: clamp(r), g: clamp(g), b: clamp(b))
    }
}

/// The three surface colors for one appearance (light or dark). The accent is shared.
struct PaletteColors: Codable, Hashable {
    var ink: RGBA          // main color: rings, numbers, charts, text
    var background: RGBA
    var card: RGBA
}

/// Number typeface, from Settings.
enum NumberStyle: String, Codable, CaseIterable, Identifiable {
    case rounded, classic, serif, mono

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rounded: return "Rounded"
        case .classic: return "Classic"
        case .serif: return "Serif"
        case .mono: return "Mono"
        }
    }

    var design: Font.Design {
        switch self {
        case .rounded: return .rounded
        case .classic: return .default
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }
}

/// Light, dark, or following the iPhone (Settings › Appearance).
enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Automatic"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// A ready-made look: one main color and one accent, each tuned for light and dark.
struct Preset: Identifiable, Hashable {
    let id: String
    let name: String
    let light: PaletteColors
    let dark: PaletteColors
    let accent: RGBA

    static let all: [Preset] = [
        // Halo's first colors, and what Reset goes back to.
        Preset(id: "graphite", name: "Original",
               light: .init(ink: .init(hex: 0x121214), background: .init(hex: 0xF9F9F7), card: .init(hex: 0xFFFFFF)),
               dark: .init(ink: .init(hex: 0xF2F2ED), background: .init(hex: 0x090909), card: .init(hex: 0x171717)),
               accent: .init(hex: 0xFF6129)),
        Preset(id: "ocean", name: "Ocean",
               light: .init(ink: .init(hex: 0x0E2A47), background: .init(hex: 0xF4F7FA), card: .init(hex: 0xFFFFFF)),
               dark: .init(ink: .init(hex: 0xE4EEF7), background: .init(hex: 0x07111C), card: .init(hex: 0x0F1C2B)),
               accent: .init(hex: 0x1FC8B4)),
        Preset(id: "forest", name: "Forest",
               light: .init(ink: .init(hex: 0x1C3324), background: .init(hex: 0xF5F7F3), card: .init(hex: 0xFFFFFF)),
               dark: .init(ink: .init(hex: 0xE5EFE6), background: .init(hex: 0x08100B), card: .init(hex: 0x111C15)),
               accent: .init(hex: 0xE8B04A)),
        Preset(id: "mono", name: "Mono",
               light: .init(ink: .init(hex: 0x000000), background: .init(hex: 0xFFFFFF), card: .init(hex: 0xF3F3F3)),
               dark: .init(ink: .init(hex: 0xFFFFFF), background: .init(hex: 0x000000), card: .init(hex: 0x141414)),
               accent: .init(hex: 0xE5484D)),
        Preset(id: "dusk", name: "Dusk",
               light: .init(ink: .init(hex: 0x2B2540), background: .init(hex: 0xF7F6FA), card: .init(hex: 0xFFFFFF)),
               dark: .init(ink: .init(hex: 0xECE9F6), background: .init(hex: 0x0D0B14), card: .init(hex: 0x18151F)),
               accent: .init(hex: 0xFF8A65)),
        Preset(id: "sand", name: "Sand",
               light: .init(ink: .init(hex: 0x3A2E27), background: .init(hex: 0xF7F3EE), card: .init(hex: 0xFFFDFA)),
               dark: .init(ink: .init(hex: 0xF3ECE4), background: .init(hex: 0x120E0B), card: .init(hex: 0x1D1814)),
               accent: .init(hex: 0x3D8BFD)),
    ]
}

/// The whole look of the app and widgets. Stored in the App Group so the widgets match.
struct Appearance: Codable, Hashable {
    var presetID: String
    var light: PaletteColors
    var dark: PaletteColors
    var accent: RGBA
    var sameInBoth: Bool
    var numberStyle: NumberStyle
    /// Halo opens in dark until you pick otherwise (saved looks from before this setting too).
    private var modeSetting: AppearanceMode?

    var mode: AppearanceMode {
        get { modeSetting ?? .dark }
        set { modeSetting = newValue }
    }

    init(preset: Preset, numberStyle: NumberStyle = .rounded) {
        presetID = preset.id
        light = preset.light
        dark = preset.dark
        accent = preset.accent
        sameInBoth = false
        self.numberStyle = numberStyle
    }

    static let standard = Appearance(preset: Preset.all[0])

    func colors(for style: UIUserInterfaceStyle) -> PaletteColors {
        let dark: Bool
        switch mode {
        case .system: dark = style == .dark
        case .light: dark = false
        case .dark: dark = true
        }
        return sameInBoth || !dark ? light : self.dark
    }

    /// Light/dark is read when the color is drawn, so the widget follows the system too.
    static var current: Appearance = load()

    private static let key = "appearance"

    static func load() -> Appearance {
        guard let data = WidgetSnapshot.defaults.data(forKey: key),
              let a = try? JSONDecoder().decode(Appearance.self, from: data) else { return .standard }
        return a
    }

    static func save(_ a: Appearance) {
        current = a
        if let data = try? JSONEncoder().encode(a) { WidgetSnapshot.defaults.set(data, forKey: key) }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
