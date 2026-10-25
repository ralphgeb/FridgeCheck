import SwiftUI

/// The three rings, in the order they appear.
enum ScoreKind: String, CaseIterable, Identifiable {
    case recovery, effort, sleep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recovery: return "Recovery"
        case .effort: return "Effort"
        case .sleep: return "Sleep"
        }
    }

    var symbol: String {
        switch self {
        case .recovery: return "bolt.heart"
        case .effort: return "flame"
        case .sleep: return "moon"
        }
    }

    func value(in s: Scores) -> Double? {
        switch self {
        case .recovery: return s.recovery
        case .effort: return s.effort
        case .sleep: return s.sleep
        }
    }
}

/// A plain progress ring: a faint track with a round-capped arc starting at 12 o'clock.
/// Used by the widgets and small places; the Today screen draws its own morphing version.
struct Ring: View {
    var progress: Double
    var lineWidth: CGFloat = 8
    var showsTip = true

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(progress, 1)))
                .stroke(Theme.ink, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showsTip && progress > 0.02 {
                // the accent dot rides on the end of the arc
                GeometryReader { geo in
                    let r = min(geo.size.width, geo.size.height) / 2
                    let a = Angle.degrees(-90 + 360 * min(progress, 1)).radians
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: lineWidth * 0.55, height: lineWidth * 0.55)
                        .position(x: geo.size.width / 2 + r * cos(a), y: geo.size.height / 2 + r * sin(a))
                }
            }
        }
        .padding(lineWidth / 2)
    }
}

extension Double {
    /// 0.823 -> "82"
    var percentText: String { String(Int((self * 100).rounded())) }
}
