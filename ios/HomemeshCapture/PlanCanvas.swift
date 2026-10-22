import SwiftUI

/// A point thing on the plan: an outlet, a jack or an access point.
struct PlanMarker: Hashable, Identifiable {
    enum Kind { case outlet, jack, accessPoint }
    let id: String
    let kind: Kind
    let at: Pt
}

/// The plan of one level in 2D: rooms (named), walls, and optionally a ghost scan the owner can drag.
/// Plan Y points up, the screen's Y points down; `bounds` is fixed by the caller so dragging does not re-fit the view.
struct PlanCanvas: View {
    let walls: [PlanWall]
    let rooms: [PlanRoom]
    var ghost: [Seg] = []
    let bounds: CGRect
    var zoom: CGFloat = 1
    var selected: String?
    var markers: [PlanMarker] = []
    var stairs: [[Pt]] = []
    var draft: [Pt] = []                // points of a stair or zone being drawn
    var selectedMarker: String?
    var zones: [PlanZone] = []
    var selectedZone: String?
    var onTapPlan: ((Pt, Double) -> Void)?    // a tap, in plan metres, with a tolerance of about 24 points in metres
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
                    ctx.stroke(path, with: .color(w.id == selected ? .accentColor : .primary), lineWidth: max(w.id == selected ? 4 : 1.5, CGFloat(w.thickness) * scale))
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
                for z in zones {
                    let color: Color = z.kind == "allow" ? .green : z.kind == "forbid" ? .red : .orange
                    let sel = z.id == selectedZone
                    if z.polygon.count >= 3 {
                        var path = Path()
                        path.move(to: map(z.polygon[0]))
                        for p in z.polygon.dropFirst() { path.addLine(to: map(p)) }
                        path.closeSubpath()
                        ctx.fill(path, with: .color(color.opacity(sel ? 0.35 : 0.18)))
                        ctx.stroke(path, with: .color(sel ? .accentColor : color), style: StrokeStyle(lineWidth: sel ? 3 : 1.5, dash: [5, 3]))
                    } else if let p = z.polygon.first {
                        let c = map(p), r: CGFloat = sel ? 9 : 7
                        let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
                        ctx.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.5)))
                        ctx.stroke(Path(ellipseIn: rect), with: .color(sel ? .accentColor : color), lineWidth: 2)
                    }
                    if !z.name.isEmpty, let c = z.polygon.first {
                        let n = Double(z.polygon.count)
                        let mid = Pt(z.polygon.map(\.x).reduce(0, +) / n, z.polygon.map(\.y).reduce(0, +) / n)
                        _ = c
                        ctx.draw(Text(z.name).font(.caption2).foregroundStyle(color), at: map(mid))
                    }
                }
                for poly in stairs where poly.count >= 3 {
                    var path = Path()
                    path.move(to: map(poly[0]))
                    for p in poly.dropFirst() { path.addLine(to: map(p)) }
                    path.closeSubpath()
                    ctx.fill(path, with: .color(.purple.opacity(0.25)))
                    ctx.stroke(path, with: .color(.purple), lineWidth: 1.5)
                }
                if draft.count >= 1 {
                    var path = Path()
                    path.move(to: map(draft[0]))
                    for p in draft.dropFirst() { path.addLine(to: map(p)) }
                    ctx.stroke(path, with: .color(.pink), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    for p in draft { ctx.fill(Path(ellipseIn: CGRect(x: map(p).x - 3, y: map(p).y - 3, width: 6, height: 6)), with: .color(.pink)) }
                }
                for m in markers {
                    let c = map(m.at), sel = m.id == selectedMarker
                    let r: CGFloat = sel ? 9 : 6
                    let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
                    switch m.kind {
                    case .outlet: ctx.fill(Path(ellipseIn: rect), with: .color(.yellow)); ctx.stroke(Path(ellipseIn: rect), with: .color(sel ? .accentColor : .black), lineWidth: 1.5)
                    case .jack: ctx.fill(Path(rect), with: .color(.green)); ctx.stroke(Path(rect), with: .color(sel ? .accentColor : .black), lineWidth: 1.5)
                    case .accessPoint:
                        ctx.fill(Path(ellipseIn: rect), with: .color(.blue))
                        ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -4, dy: -4)), with: .color(sel ? .accentColor : .blue), lineWidth: 1.5)
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
            .onTapGesture(coordinateSpace: .local) { loc in
                let mx = bounds.midX, my = bounds.midY
                let p = Pt(mx + Double((loc.x - geo.size.width / 2) / scale), my - Double((loc.y - geo.size.height / 2) / scale))
                onTapPlan?(p, Double(24 / scale))
            }
            .gesture(DragGesture()
                .onChanged { v in onDrag?(Pt(Double(v.translation.width / scale), Double(-v.translation.height / scale))) }
                .onEnded { _ in onDragEnd?() })
        }
    }
}
