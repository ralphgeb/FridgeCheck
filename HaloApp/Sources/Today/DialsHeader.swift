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

        // Collapsed: three bars side by side.
        let gap: CGFloat = 18
        var barWidth: CGFloat { (width - 2 * gap) / 3 }
        func barStart(_ i: Int) -> CGFloat { CGFloat(i) * (barWidth + gap) }
        let barY: CGFloat = 38
        let barLabelY: CGFloat = 18

        var lineWidth: CGFloat { lerp(9, 4, collapse) }

        /// Point at fraction `s` (0...1) along dial `i`.
        /// The dial is an arc that starts at its top, heading right. As it collapses its curvature
        /// falls to zero and its length goes from the ring's circumference to the bar's width,
        /// so the ring uncurls into the bar like a ribbon.
        func point(_ s: Double, _ i: Int) -> CGPoint {
            let c = ringCenter(i)
            let r = diameter / 2 - 6
            let start = CGPoint(x: lerp(c.x, barStart(i), collapse), y: lerp(c.y - r, barY, collapse))
            let length = lerp(2 * .pi * r, barWidth, collapse)
            let kappa = (1 - collapse) / r
            let l = length * CGFloat(s)
            let theta = kappa * l
            if abs(theta) < 0.0001 { return CGPoint(x: start.x + l, y: start.y + kappa * l * l / 2) }
            return CGPoint(x: start.x + sin(theta) / kappa, y: start.y + (1 - cos(theta)) / kappa)
        }

        /// Text fades out while the ring is mid-way and back in once it has landed.
        var textOpacity: Double { Double(max(0, max(1 - 3 * collapse, 3 * collapse - 2))) }

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
        let e = layout.collapse
        let center = layout.ringCenter(i)
        let barStart = layout.barStart(i)
        let barEnd = barStart + layout.barWidth
        let value = kind.value(in: scores)

        // Number: centre of the ring -> right end of the bar.
        Group {
            if let value {
                Text("\(Int((value * reveal * 100).rounded()))")
            } else {
                Text("–")
            }
        }
        .font(Theme.number(lerp(30, 14, e), weight: .semibold))
        .foregroundStyle(Theme.ink)
        .opacity(layout.textOpacity)
        .placed(CGPoint(x: lerp(center.x, barEnd, e), y: lerp(center.y, layout.barLabelY, e)),
                anchor: UnitPoint(x: lerp(0.5, 1, e), y: 0.5))

        // Label: under the ring -> left end of the bar.
        Text(kind.title)
            .haloLabel()
            .opacity(layout.textOpacity)
            .placed(CGPoint(x: lerp(center.x, barStart, e), y: lerp(layout.ringLabelY, layout.barLabelY, e)),
                    anchor: UnitPoint(x: lerp(0.5, 0, e), y: 0.5))
    }
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
