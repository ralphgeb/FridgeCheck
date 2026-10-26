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

/// The Balance radar: one spoke per axis and a filled shape for this week.
/// The accent marks the weakest spoke, or the one you picked (`highlight`), which also gets
/// a soft accent glow spreading from its point.
struct RadarChart: View {
    var axes: [BalanceAxis]
    var showsLabels = true
    var highlight: String? = nil

    var body: some View {
        GeometryReader { g in
            // labels sit outside the shape: a line of text above and below, a word or two either side
            let r = showsLabels
                ? min(g.size.width / 2 - 52, g.size.height / 2 - 20)
                : min(g.size.width, g.size.height) / 2 - 5
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            let marked = highlight.flatMap { h in axes.firstIndex { $0.id == h } }
                ?? axes.indices.min { axes[$0].value < axes[$1].value }
            ZStack {
                Canvas { ctx, _ in
                    guard axes.count >= 3 else { return }
                    for level in [0.25, 0.5, 0.75, 1.0] {
                        ctx.stroke(polygon(axes.map { _ in level }, c: c, r: r),
                                   with: .color(Theme.ink.opacity(level == 1 ? 0.16 : 0.07)), lineWidth: 1)
                    }
                    for i in axes.indices {
                        var spoke = Path()
                        spoke.move(to: c)
                        spoke.addLine(to: point(i, 1, c: c, r: r))
                        ctx.stroke(spoke, with: .color(Theme.ink.opacity(0.07)), lineWidth: 1)
                    }
                    let shape = polygon(axes.map { max(0.04, $0.value) }, c: c, r: r)
                    ctx.fill(shape, with: .color(Theme.ink.opacity(0.1)))
                    if highlight != nil, let m = marked {
                        let p = point(m, max(0.04, axes[m].value), c: c, r: r)
                        ctx.fill(shape, with: .radialGradient(Gradient(colors: [Theme.accent.opacity(0.55), Theme.accent.opacity(0)]),
                                                              center: p, startRadius: 0, endRadius: r * 1.25))
                    }
                    ctx.stroke(shape, with: .color(Theme.ink), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    for i in axes.indices where i != marked {
                        let p = point(i, max(0.04, axes[i].value), c: c, r: r)
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2.25, y: p.y - 2.25, width: 4.5, height: 4.5)), with: .color(Theme.ink))
                    }
                    // the marked point goes last, with a ring of card color, so nothing draws over it
                    if let m = marked {
                        let p = point(m, max(0.04, axes[m].value), c: c, r: r)
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(Theme.card))
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(Theme.accent))
                    }
                }
                if showsLabels {
                    ForEach(Array(axes.enumerated()), id: \.offset) { i, axis in
                        Text(axis.short)
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.3)
                            .foregroundStyle(i == marked ? Theme.accent : Theme.secondary)
                            .fixedSize()
                            // pinned by the edge nearest the shape, so every label sits the same distance away
                            .frame(width: 0, height: 0, alignment: labelAlignment(i))
                            .position(point(i, 1, c: c, r: r + 8))
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(axes.map { "\($0.name) \(Int(($0.value * 100).rounded()))" }.joined(separator: ", "))
    }

    private func angle(_ i: Int) -> Double {
        -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(max(axes.count, 1))
    }

    private func labelAlignment(_ i: Int) -> Alignment {
        let x = cos(angle(i)), y = sin(angle(i))
        let h: HorizontalAlignment = x > 0.2 ? .leading : (x < -0.2 ? .trailing : .center)
        let v: VerticalAlignment = y > 0.5 ? .top : (y < -0.5 ? .bottom : .center)
        return Alignment(horizontal: h, vertical: v)
    }

    private func point(_ i: Int, _ v: Double, c: CGPoint, r: CGFloat) -> CGPoint {
        let a = angle(i)
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
