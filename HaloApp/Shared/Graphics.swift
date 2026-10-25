import SwiftUI

/// Three thin concentric rings: Recovery (outer), Effort, Sleep (inner).
/// Used around each day in the calendar and in the small widget.
struct TripleRing: View {
    var scores: Scores
    var lineWidth: CGFloat = 2.4
    var gap: CGFloat = 1.6
    var showsTip = false

    var body: some View {
        ZStack {
            ForEach(Array(ScoreKind.allCases.enumerated()), id: \.offset) { i, kind in
                let inset = CGFloat(i) * (lineWidth + gap) + lineWidth / 2
                let v = min(1, max(0, kind.value(in: scores) ?? 0))
                Circle().inset(by: inset).stroke(Theme.track, lineWidth: lineWidth)
                Circle().inset(by: inset)
                    .trim(from: 0, to: max(0.001, v))
                    .stroke(Theme.ink.opacity(1 - 0.28 * Double(i)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(v > 0 ? 1 : 0)
            }
            if showsTip, let v = scores.recovery, v > 0.02 {
                GeometryReader { g in
                    let r = min(g.size.width, g.size.height) / 2 - lineWidth / 2
                    let a = Angle.degrees(-90 + 360 * min(v, 1)).radians
                    Circle().fill(Theme.accent)
                        .frame(width: lineWidth * 0.6, height: lineWidth * 0.6)
                        .position(x: g.size.width / 2 + r * cos(a), y: g.size.height / 2 + r * sin(a))
                }
            }
        }
    }
}

/// The Balance radar: one spoke per axis, a filled shape for this week,
/// and the weakest spoke marked with the accent so you know what to work on.
struct RadarChart: View {
    var axes: [BalanceAxis]
    var showsLabels = true
    var labelFont: Font = .system(size: 11, weight: .semibold)

    var body: some View {
        GeometryReader { g in
            let size = min(g.size.width, g.size.height)
            let inset: CGFloat = showsLabels ? 34 : 4
            let r = size / 2 - inset
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            let weakest = axes.indices.min { axes[$0].value < axes[$1].value }
            ZStack {
                Canvas { ctx, _ in
                    guard axes.count >= 3 else { return }
                    // grid
                    for level in [0.25, 0.5, 0.75, 1.0] {
                        ctx.stroke(polygon(axes.map { _ in level }, c: c, r: r), with: .color(Theme.ink.opacity(level == 1 ? 0.14 : 0.07)), lineWidth: 1)
                    }
                    for i in axes.indices {
                        var spoke = Path()
                        spoke.move(to: c)
                        spoke.addLine(to: point(i, 1, c: c, r: r))
                        ctx.stroke(spoke, with: .color(Theme.ink.opacity(0.07)), lineWidth: 1)
                    }
                    // this week
                    let shape = polygon(axes.map { max(0.04, $0.value) }, c: c, r: r)
                    ctx.fill(shape, with: .color(Theme.ink.opacity(0.12)))
                    ctx.stroke(shape, with: .color(Theme.ink), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                    for i in axes.indices {
                        let p = point(i, max(0.04, axes[i].value), c: c, r: r)
                        let d: CGFloat = i == weakest ? 7 : 4.5
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)),
                                 with: .color(i == weakest ? Theme.accent : Theme.ink))
                    }
                }
                if showsLabels {
                    ForEach(Array(axes.enumerated()), id: \.offset) { i, axis in
                        let p = point(i, 1, c: c, r: r + 16)
                        Text(axis.name)
                            .font(labelFont)
                            .foregroundStyle(i == weakest ? Theme.accent : Theme.secondary)
                            .fixedSize()
                            .position(p)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(axes.map { "\($0.name) \(Int(($0.value * 100).rounded()))" }.joined(separator: ", "))
    }

    private func point(_ i: Int, _ v: Double, c: CGPoint, r: CGFloat) -> CGPoint {
        let a = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(max(axes.count, 1))
        return CGPoint(x: c.x + r * CGFloat(v * cos(a)), y: c.y + r * CGFloat(v * sin(a)))
    }

    private func polygon(_ values: [Double], c: CGPoint, r: CGFloat) -> Path {
        var p = Path()
        for (i, v) in values.enumerated() {
            let pt = point(i, v, c: c, r: r)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

extension Array where Element == BalanceAxis {
    /// Average of all spokes, 0...1.
    var overall: Double { isEmpty ? 0 : reduce(0) { $0 + $1.value } / Double(count) }
}
