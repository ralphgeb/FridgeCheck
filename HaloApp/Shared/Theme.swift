import SwiftUI
import UIKit

/// Halo's whole palette: one main color (ink) and one accent.
/// Everything else is ink at a lower opacity, so light and dark mode stay in step.
enum Theme {
    /// Main color: near-black on light, warm off-white on dark.
    static let ink = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.95, green: 0.95, blue: 0.93, alpha: 1)
            : UIColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)
    })

    /// Accent: one warm orange, used sparingly (ring tips, today, awake time, alerts).
    static let accent = Color(red: 1.0, green: 0.38, blue: 0.16)

    static let background = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 0.035, alpha: 1)
            : UIColor(red: 0.975, green: 0.975, blue: 0.97, alpha: 1)
    })

    static let card = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(white: 0.09, alpha: 1) : .white
    })

    static let secondary = ink.opacity(0.5)
    static let tertiary = ink.opacity(0.28)
    static let track = ink.opacity(0.08)
    static let hairline = ink.opacity(0.08)

    // MARK: Type

    /// Big numbers: rounded, tight, with fixed-width digits so counters don't wobble.
    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
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
