import SwiftUI

/// True on a wide screen (the iPhone Duo opened up): pages lay their cards out in columns.
private struct WideLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var wideLayout: Bool {
        get { self[WideLayoutKey.self] }
        set { self[WideLayoutKey.self] = newValue }
    }
}

/// Cards in columns, each going under whichever column is shortest so far: the first card sits
/// at the top left, and the rest fill the width evenly with no tall gaps. A card marked
/// `spansColumns()` runs across all of them.
struct ColumnsLayout: Layout {
    var columns = 2
    var spacing: CGFloat = 14

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 700
        return CGSize(width: width, height: frames(width: width, subviews: subviews).1)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, r) in zip(subviews, frames(width: bounds.width, subviews: subviews).0) {
            view.place(at: CGPoint(x: bounds.minX + r.minX, y: bounds.minY + r.minY),
                       proposal: ProposedViewSize(width: r.width, height: r.height))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> ([CGRect], CGFloat) {
        let n = max(1, columns)
        let column = (width - spacing * CGFloat(n - 1)) / CGFloat(n)
        var tops = [CGFloat](repeating: 0, count: n)
        var rects: [CGRect] = []
        for view in subviews {
            if view[SpansColumnsKey.self] {
                let h = view.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
                let y = tops.max() ?? 0
                rects.append(CGRect(x: 0, y: y, width: width, height: h))
                if h > 0 { tops = tops.map { _ in y + h + spacing } }
                continue
            }
            let h = view.sizeThatFits(ProposedViewSize(width: column, height: nil)).height
            // the shortest column (the leftmost on a tie)
            let c = tops.indices.min { tops[$0] < tops[$1] || (tops[$0] == tops[$1] && $0 < $1) } ?? 0
            rects.append(CGRect(x: CGFloat(c) * (column + spacing), y: tops[c], width: column, height: h))
            if h > 0 { tops[c] += h + spacing }
        }
        return (rects, max(0, (tops.max() ?? 0) - spacing))
    }
}

private struct SpansColumnsKey: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    /// Runs across every column on a wide screen (a strip of days, a footnote).
    func spansColumns() -> some View {
        layoutValue(key: SpansColumnsKey.self, value: true)
    }
}
