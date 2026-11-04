import SwiftUI

/// The three score dials. `collapse` (0...1, driven by scroll) unrolls each ring into a straight
/// progress bar pinned at the top. `reveal` (0...1, animated) fills the rings and counts the numbers up.
///
/// Every point of a ring is interpolated toward the matching point of its bar, so the circle
/// visibly unwinds into a line instead of cross-fading.
struct DialsHeader: View, Animatable {
    var scores: Scores
    var collapse: Double
    var reveal: Double

    var animatableData: Double {
        get { reveal }
        set { reveal = newValue }
    }

    static let expandedHeight: CGFloat = 154   // just below the labels, so the first card sits close
    static let collapsedHeight: CGFloat = 52

    var body: some View {
        GeometryReader { geo in
            let layout = Layout(width: geo.size.width, collapse: CGFloat(eased))
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for (i, kind) in ScoreKind.allCases.enumerated() {
                        draw(kind, index: i, layout: layout, in: &ctx)
                    }
                }
                ForEach(Array(ScoreKind.allCases.enumerated()), id: \.element) { i, kind in
                    labels(kind, index: i, layout: layout)
                }
            }
        }
        .frame(height: lerp(Self.expandedHeight, Self.collapsedHeight, CGFloat(eased)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ScoreKind.allCases.map { "\($0.title) \($0.value(in: scores).map { $0.percentText } ?? "no data")" }.joined(separator: ", "))
    }

    /// Smoothstep: the morph starts and ends gently.
    private var eased: Double {
        let t = min(1, max(0, collapse))
        return t * t * (3 - 2 * t)
    }

    // MARK: Geometry

    struct Layout {
        let width: CGFloat
        let collapse: CGFloat

        // Expanded: three rings in a row.
        var diameter: CGFloat { min(104, (width - 48) / 3) }
        func ringCenter(_ i: Int) -> CGPoint {
            CGPoint(x: width * CGFloat(2 * i + 1) / 6, y: 8 + diameter / 2)
        }
        var ringLabelY: CGFloat { 8 + diameter + 26 }

        // Collapsed: three bars side by side, the words under them (as they sit under the rings),
        // so the text never has to jump over the line.
        let gap: CGFloat = 18
        var barWidth: CGFloat { (width - 2 * gap) / 3 }
        func barStart(_ i: Int) -> CGFloat { CGFloat(i) * (barWidth + gap) }
        let barY: CGFloat = 12
        let barLabelY: CGFloat = 32

        // The fold in three overlapping steps: the ring shrinks around its centre (and the number
        // shrinks into a dot), the small ring moves to its place, then it opens into the line (and
        // a dot there grows into the number). The words follow the ring's bottom edge, so the two
        // never cross.
        var shrink: CGFloat { smooth(0, 0.45, collapse) }
        var move: CGFloat { smooth(0.25, 1, collapse) }
        var open: CGFloat { smooth(0.35, 1, collapse) }
        static let smallRadius: CGFloat = 10

        var lineWidth: CGFloat { lerp(9, 4, shrink) }

        /// The ring's radius as it shrinks.
        var radius: CGFloat { lerp(diameter / 2 - 6, Self.smallRadius, shrink) }

        /// Where the ring (or line) starts: the top of the ring, moving to the bar's left end.
        func start(_ i: Int) -> CGPoint {
            let c = ringCenter(i)
            return CGPoint(x: lerp(c.x, barStart(i), move), y: lerp(c.y - radius, barY, move))
        }

        /// Point at fraction `s` (0...1) along dial `i`: an arc from the start, heading right,
        /// whose curvature falls to zero as it opens, and whose length goes from the (shrinking)
        /// ring's circumference to the bar's width.
        func point(_ s: Double, _ i: Int) -> CGPoint {
            let start = start(i)
            let length = lerp(2 * .pi * radius, barWidth, open)
            let kappa = (1 - open) * 2 * .pi / length
            let l = length * CGFloat(s)
            let theta = kappa * l
            if abs(theta) < 0.0001 { return CGPoint(x: start.x + l, y: start.y + kappa * l * l / 2) }
            return CGPoint(x: start.x + sin(theta) / kappa, y: start.y + (1 - cos(theta)) / kappa)
        }

        /// The ring's centre while it's still round (where the number shrinks to).
        func center(_ i: Int) -> CGPoint {
            let s = start(i)
            return CGPoint(x: s.x, y: s.y + radius * (1 - open))
        }

        /// How big the number is in the ring (1 → 0) and at the bar's end (0 → 1).
        var numberOut: CGFloat { 1 - smooth(0, 0.4, collapse) }
        var numberIn: CGFloat { smooth(0.72, 1, collapse) }

        func path(_ i: Int, to s: Double) -> Path {
            var p = Path()
            let steps = max(2, Int(96 * s))
            p.move(to: point(0, i))
            for k in 1...steps { p.addLine(to: point(s * Double(k) / Double(steps), i)) }
            return p
        }
    }

    // MARK: Drawing

    private func draw(_ kind: ScoreKind, index i: Int, layout: Layout, in ctx: inout GraphicsContext) {
        let style = StrokeStyle(lineWidth: layout.lineWidth, lineCap: .round, lineJoin: .round)
        ctx.stroke(layout.path(i, to: 1), with: .color(Theme.track), style: style)

        guard let value = kind.value(in: scores) else { return }
        let fill = max(0.001, value * reveal)
        ctx.stroke(layout.path(i, to: fill), with: .color(Theme.ink), style: style)

        // Accent tip at the end of the filled arc.
        let tip = layout.point(fill, i)
        let d = layout.lineWidth * 0.5
        ctx.fill(Path(ellipseIn: CGRect(x: tip.x - d / 2, y: tip.y - d / 2, width: d, height: d)),
                 with: .color(Theme.accent))
    }

    @ViewBuilder
    private func labels(_ kind: ScoreKind, index i: Int, layout: Layout) -> some View {
        let move = layout.move
        let barStart = layout.barStart(i)
        let barEnd = barStart + layout.barWidth
        let value = kind.value(in: scores)
        let text = value.map { "\(Int(($0 * reveal * 100).rounded()))" } ?? "–"
        let ring = layout.center(i)

        // The number in the ring: shrinks to a dot at the ring's centre, the dot to a point.
        let out = layout.numberOut
        if out > 0 {
            Text(text)
                .font(Theme.number(30, weight: .semibold))
                .foregroundStyle(Theme.text)
                .scaleEffect(max(out, 0.01))
                .opacity(Double(smooth(0.3, 0.65, out)))
                .placed(ring, anchor: .center)
            Circle().fill(Theme.ink)
                .frame(width: 8, height: 8)
                .scaleEffect(out > 0.4 ? (1 - out) / 0.6 : out / 0.4)
                .placed(ring, anchor: .center)
        }

        // At the bar's end: a point grows into a dot, the dot into the number.
        let into = layout.numberIn
        if into > 0 {
            let spot = CGPoint(x: barEnd, y: layout.barLabelY)
            Circle().fill(Theme.ink)
                .frame(width: 7, height: 7)
                .scaleEffect(into < 0.4 ? into / 0.4 : max(0, 1 - (into - 0.4) / 0.3))
                .placed(CGPoint(x: barEnd - 4, y: layout.barLabelY), anchor: .center)
            Text(text)
                .font(Theme.number(14, weight: .semibold))
                .foregroundStyle(Theme.text)
                .scaleEffect(max(into, 0.01), anchor: .trailing)
                .opacity(Double(smooth(0.35, 0.75, into)))
                .placed(spot, anchor: UnitPoint(x: 1, y: 0.5))
        }

        // The label: under the ring, riding up with its bottom edge, then to the bar's left end
        // under the line.
        let underRing = ring.y + layout.radius + 22 + 10 * (1 - layout.shrink)
        Text(kind.title)
            .haloLabel()
            .placed(CGPoint(x: lerp(layout.ringCenter(i).x, barStart, move), y: lerp(underRing, layout.barLabelY, move)),
                    anchor: UnitPoint(x: lerp(0.5, 0, move), y: 0.5))
    }
}

/// 0 below `a`, 1 above `b`, easing in and out between.
func smooth(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = min(1, max(0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

extension View {
    /// Places a view inside a top-leading ZStack so that `anchor` (a unit point of the view's own size)
    /// lands exactly on `point`. Lets text slide between centred and edge-aligned positions smoothly.
    func placed(_ point: CGPoint, anchor: UnitPoint) -> some View {
        self.fixedSize()
            .alignmentGuide(.leading) { d in d.width * anchor.x - point.x }
            .alignmentGuide(.top) { d in d.height * anchor.y - point.y }
    }
}
