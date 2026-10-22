import SceneKit
import SwiftUI

/// The house as a 3D model built from the plan data: walls as boxes at their floor's height, a thin translucent slab per floor,
/// staircases as purple blocks. Plan (x, y) becomes scene (x, z = -y) with Y up, as in the web view.
enum House3D {
    static let floorColors: [UIColor] = [.systemBlue, .systemTeal, .systemOrange, .systemPink, .systemIndigo]

    static func build(_ plan: PlanHouse, visible: Set<String>? = nil) -> SCNScene {
        let scene = SCNScene()
        let elevation = Dictionary(uniqueKeysWithValues: plan.levels.map { ($0.id, $0.elevation) })
        let levelHeight = Dictionary(uniqueKeysWithValues: plan.levels.map { ($0.id, $0.height) })
        for (li, level) in plan.levels.enumerated() where visible?.contains(level.id) ?? true {
            let color = floorColors[li % floorColors.count]
            let walls = plan.walls.filter { $0.level == level.id }
            for w in walls {
                let len = max(w.length, 0.05), h = w.height ?? levelHeight[level.id] ?? 2.5
                if let outline = w.profile, outline.count >= 3, outline.allSatisfy({ $0.count == 2 }) {   // under a sloped or vaulted ceiling
                    let path = UIBezierPath()
                    for (i, p) in outline.enumerated() { i == 0 ? path.move(to: CGPoint(x: p[0], y: p[1])) : path.addLine(to: CGPoint(x: p[0], y: p[1])) }
                    path.close()
                    let shape = SCNShape(path: path, extrusionDepth: max(w.thickness, 0.05))
                    shape.firstMaterial?.diffuse.contents = color.withAlphaComponent(0.85)
                    shape.firstMaterial?.isDoubleSided = true
                    let n = SCNNode(geometry: shape)
                    n.name = "wall:\(w.id)"
                    n.pivot = SCNMatrix4MakeTranslation(0, 0, Float(max(w.thickness, 0.05) / 2))
                    n.position = SCNVector3(Float(w.a.x), Float((elevation[level.id] ?? 0) + (w.base_z ?? 0)), Float(-w.a.y))
                    n.eulerAngles.y = Float(atan2(w.b.y - w.a.y, w.b.x - w.a.x))
                    scene.rootNode.addChildNode(n)
                    continue
                }
                let box = SCNBox(width: len, height: h, length: max(w.thickness, 0.05), chamferRadius: 0)
                box.firstMaterial?.diffuse.contents = color.withAlphaComponent(0.85)
                let n = SCNNode(geometry: box)
                n.name = "wall:\(w.id)"
                n.position = SCNVector3(Float((w.a.x + w.b.x) / 2), Float((elevation[level.id] ?? 0) + (w.base_z ?? 0) + h / 2), Float(-(w.a.y + w.b.y) / 2))
                n.eulerAngles.y = Float(atan2(w.b.y - w.a.y, w.b.x - w.a.x))
                scene.rootNode.addChildNode(n)
            }
            let pts = walls.flatMap { [$0.a, $0.b] }
            if !pts.isEmpty {
                let b = Geometry.bounds(pts)
                let slab = SCNBox(width: b.width, height: 0.04, length: b.height, chamferRadius: 0)
                slab.firstMaterial?.diffuse.contents = UIColor.systemGray.withAlphaComponent(0.25)
                let n = SCNNode(geometry: slab)
                n.name = "floor:\(level.id)"
                n.position = SCNVector3(Float(b.midX), Float(elevation[level.id] ?? 0), Float(-b.midY))
                scene.rootNode.addChildNode(n)
            }
        }
        for st in plan.stairs where visible == nil || visible!.contains(st.from_level) || visible!.contains(st.to_level) {
            let b = Geometry.bounds(st.polygon)
            let lo = elevation[st.from_level] ?? 0, hi = elevation[st.to_level] ?? lo + 2.5
            let box = SCNBox(width: b.width, height: max(hi - lo, 0.1), length: b.height, chamferRadius: 0)
            box.firstMaterial?.diffuse.contents = UIColor.systemPurple.withAlphaComponent(0.4)
            let n = SCNNode(geometry: box)
            n.name = "stair:\(st.id)"
            n.position = SCNVector3(Float(b.midX), Float((lo + hi) / 2), Float(-b.midY))
            scene.rootNode.addChildNode(n)
        }
        return scene
    }
}

struct SceneContainer: UIViewRepresentable {
    let scene: SCNScene

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.allowsCameraControl = true
        v.autoenablesDefaultLighting = true
        v.backgroundColor = .systemBackground
        v.antialiasingMode = .multisampling4X
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) { v.scene = scene }
}

/// Orbit, pinch and pan around the whole house; floors can be hidden.
struct House3DView: View {
    let houseId: String
    @EnvironmentObject var model: AppModel
    @State private var plan: PlanHouse?
    @State private var hidden: Set<String> = []
    @State private var status = ""

    var body: some View {
        VStack(spacing: 8) {
            if let plan {
                SceneContainer(scene: House3D.build(plan, visible: Set(plan.levels.map(\.id)).subtracting(hidden)))
                    .accessibilityLabel("3D model of the house with \(plan.walls.count) walls")
                HStack {
                    ForEach(plan.levels, id: \.id) { lv in
                        Toggle(lv.name, isOn: Binding(get: { !hidden.contains(lv.id) }, set: { if $0 { hidden.remove(lv.id) } else { hidden.insert(lv.id) } }))
                            .toggleStyle(.button)
                    }
                }
                Text("Drag to turn, pinch to zoom, two fingers to move.").font(.footnote).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            if !status.isEmpty { Text(status).font(.footnote) }
        }
        .padding(.bottom)
        .navigationTitle("3D view")
        .task {
            do { plan = try JSONDecoder().decode(PlanHouse.self, from: try await model.client().call("GET", "/api/houses/\(houseId)")) }
            catch { status = "Could not load the house: \(error.localizedDescription)" }
        }
    }
}
