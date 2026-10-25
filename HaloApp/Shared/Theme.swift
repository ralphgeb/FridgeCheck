import SwiftUI
import UIKit

/// Halo's palette: one main color (ink) and one accent, both chosen in Settings.
/// Everything else is ink at a lower opacity, so any palette stays coherent in light and dark.
enum Theme {
    static var ink: Color {
        Color(UIColor { Appearance.current.colors(for: $0.userInterfaceStyle).ink.uiColor })
    }

    static var accent: Color { Appearance.current.accent.color }

    static var background: Color {
        Color(UIColor { Appearance.current.colors(for: $0.userInterfaceStyle).background.uiColor })
    }

    static var card: Color {
        Color(UIColor { Appearance.current.colors(for: $0.userInterfaceStyle).card.uiColor })
    }

    static var secondary: Color { ink.opacity(0.5) }
    static var tertiary: Color { ink.opacity(0.28) }
    static var track: Color { ink.opacity(0.08) }
    static var hairline: Color { ink.opacity(0.08) }

    // MARK: Type

    /// Big numbers in the chosen style, with fixed-width digits so counters don't wobble.
    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: Appearance.current.numberStyle.design).monospacedDigit()
    }

    /// Small uppercase labels.
    static let label = Font.system(size: 11, weight: .semibold)
    static let labelTracking: CGFloat = 1.1
}

extension View {
    /// Small uppercase label style used across the app.
    func haloLabel() -> some View {
        self.font(Theme.label)
            .tracking(Theme.labelTracking)
            .textCase(.uppercase)
            .foregroundStyle(Theme.secondary)
    }

    /// The single card surface.
    func haloCard(padding: CGFloat = 18) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
