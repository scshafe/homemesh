import SwiftUI

/// The plan of one level in 2D: rooms (named), walls, and optionally a ghost scan the owner can drag.
/// Plan Y points up, the screen's Y points down; `bounds` is fixed by the caller so dragging does not re-fit the view.
struct PlanCanvas: View {
    let walls: [PlanWall]
    let rooms: [PlanRoom]
    var ghost: [Seg] = []
    let bounds: CGRect
    var zoom: CGFloat = 1
    var onDrag: ((Pt) -> Void)?       // plan metres moved since the gesture began
    var onDragEnd: (() -> Void)?

    private func mapping(_ size: CGSize) -> (CGFloat, (Pt) -> CGPoint) {
        let s = min(size.width / bounds.width, size.height / bounds.height) * 0.85 * zoom
        let mx = bounds.midX, my = bounds.midY
        return (s, { CGPoint(x: size.width / 2 + CGFloat($0.x - mx) * s, y: size.height / 2 - CGFloat($0.y - my) * s) })
    }

    var body: some View {
        GeometryReader { geo in
            let (scale, map) = mapping(geo.size)
            Canvas { ctx, _ in
                for r in rooms where r.polygon.count >= 3 {
                    var path = Path()
                    path.move(to: map(r.polygon[0]))
                    for p in r.polygon.dropFirst() { path.addLine(to: map(p)) }
                    path.closeSubpath()
                    ctx.fill(path, with: .color(.blue.opacity(0.08)))
                    let c = Pt(r.polygon.map(\.x).reduce(0, +) / Double(r.polygon.count), r.polygon.map(\.y).reduce(0, +) / Double(r.polygon.count))
                    ctx.draw(Text(r.name).font(.caption).foregroundStyle(.secondary), at: map(c))
                }
                for w in walls {
                    var path = Path()
                    path.move(to: map(w.a))
                    path.addLine(to: map(w.b))
                    ctx.stroke(path, with: .color(.primary), lineWidth: max(1.5, CGFloat(w.thickness) * scale))
                    let ln = hypot(w.b.x - w.a.x, w.b.y - w.a.y)
                    if ln > 0 {
                        for o in w.openings {   // openings drawn as gaps in the wall's colour of the background
                            let t0 = o.offset / ln, t1 = (o.offset + o.width) / ln
                            var gap = Path()
                            gap.move(to: map(Pt(w.a.x + (w.b.x - w.a.x) * t0, w.a.y + (w.b.y - w.a.y) * t0)))
                            gap.addLine(to: map(Pt(w.a.x + (w.b.x - w.a.x) * t1, w.a.y + (w.b.y - w.a.y) * t1)))
                            ctx.stroke(gap, with: .color(o.kind == "window" ? .cyan : .orange), lineWidth: max(2, CGFloat(w.thickness) * scale))
                        }
                    }
                }
                for g in ghost {
                    var path = Path()
                    path.move(to: map(g.a))
                    path.addLine(to: map(g.b))
                    ctx.stroke(path, with: .color(.red.opacity(0.8)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture()
                .onChanged { v in onDrag?(Pt(Double(v.translation.width / scale), Double(-v.translation.height / scale))) }
                .onEnded { _ in onDragEnd?() })
        }
    }
}
