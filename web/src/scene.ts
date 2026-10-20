import * as THREE from "three";
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js";
import type { HeatMap, House, Wall } from "./types";

// Z is up, as in the data model: no axis swap anywhere.
const WALL = new THREE.MeshStandardMaterial({ color: 0xb8b2a7 });
const OPENING = new THREE.MeshStandardMaterial({ color: 0x6aa6d6, transparent: true, opacity: 0.35 });

/** RSSI (dBm) to colour: red (weak) through yellow to green (strong). */
export function rssiColor(dbm: number): [number, number, number] {
  const t = Math.min(1, Math.max(0, (dbm + 90) / 55)); // -90 .. -35 dBm
  const c = new THREE.Color().setHSL(t * 0.33, 0.85, 0.5);
  return [c.r * 255, c.g * 255, c.b * 255];
}

export class Viewer {
  scene = new THREE.Scene();
  camera = new THREE.PerspectiveCamera(50, 1, 0.1, 500);
  renderer = new THREE.WebGLRenderer({ antialias: true });
  controls: OrbitControls;
  private house = new THREE.Group();
  private heat = new THREE.Group();
  private pickers: THREE.Mesh[] = [];
  private marker = new THREE.Mesh(new THREE.SphereGeometry(0.2), new THREE.MeshBasicMaterial({ color: 0x1e5bd6 }));
  onPick: (x: number, y: number, level: string) => void = () => {};

  constructor(private el: HTMLElement) {
    this.camera.up.set(0, 0, 1);
    this.renderer.setPixelRatio(window.devicePixelRatio);
    el.appendChild(this.renderer.domElement);
    this.scene.background = new THREE.Color(0xf4f4f2);
    this.scene.add(new THREE.AmbientLight(0xffffff, 1.2));
    const sun = new THREE.DirectionalLight(0xffffff, 1.5);
    sun.position.set(10, -20, 30);
    this.scene.add(sun, this.house, this.heat, this.marker);
    this.marker.visible = false;
    this.controls = new OrbitControls(this.camera, this.renderer.domElement);
    new ResizeObserver(() => this.resize()).observe(el);
    this.resize();
    this.renderer.setAnimationLoop(() => this.renderer.render(this.scene, this.camera));

    let down: [number, number] | null = null;
    const dom = this.renderer.domElement;
    dom.addEventListener("pointerdown", (e) => (down = [e.clientX, e.clientY]));
    dom.addEventListener("pointerup", (e) => {
      if (down && Math.hypot(e.clientX - down[0], e.clientY - down[1]) < 4) this.pick(e);
      down = null;
    });
  }

  private resize() {
    const w = this.el.clientWidth || 1, h = this.el.clientHeight || 1;
    this.renderer.setSize(w, h);
    this.camera.aspect = w / h;
    this.camera.updateProjectionMatrix();
  }

  private pick(e: PointerEvent) {
    const r = this.renderer.domElement.getBoundingClientRect();
    const ndc = new THREE.Vector2(((e.clientX - r.left) / r.width) * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1);
    const ray = new THREE.Raycaster();
    ray.setFromCamera(ndc, this.camera);
    const hit = ray.intersectObjects(this.pickers)[0];
    if (hit) this.onPick(hit.point.x, hit.point.y, hit.object.userData.level as string);
  }

  setHouse(h: House) {
    this.house.clear();
    this.heat.clear();
    this.pickers = [];
    this.marker.visible = false;
    const elev = new Map(h.levels.map((l) => [l.id, l.elevation]));
    for (const w of h.walls) this.addWall(w, elev.get(w.level) ?? 0);
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    for (const w of h.walls) for (const p of [w.a, w.b]) {
      minX = Math.min(minX, p[0]); maxX = Math.max(maxX, p[0]); minY = Math.min(minY, p[1]); maxY = Math.max(maxY, p[1]);
    }
    for (const l of h.levels) {
      const holes = [...h.slab_holes, ...h.stairs.filter((s) => s.void).map((s) => ({ level: s.to_level, polygon: s.polygon }))]
        .filter((p) => p.level === l.id);
      const shape = new THREE.Shape([[minX, minY], [maxX, minY], [maxX, maxY], [minX, maxY]].map(([x, y]) => new THREE.Vector2(x, y)));
      for (const hole of holes) shape.holes.push(new THREE.Path(hole.polygon.map(([x, y]) => new THREE.Vector2(x, y))));
      const slab = new THREE.Mesh(new THREE.ShapeGeometry(shape),
        new THREE.MeshStandardMaterial({ color: 0xdcd6c8, side: THREE.DoubleSide, transparent: true, opacity: 0.5 }));
      slab.position.z = l.elevation;
      this.house.add(slab);
      const pick = new THREE.Mesh(new THREE.PlaneGeometry(maxX - minX, maxY - minY),
        new THREE.MeshBasicMaterial({ visible: false, side: THREE.DoubleSide }));
      pick.position.set((minX + maxX) / 2, (minY + maxY) / 2, l.elevation + 1.0);
      pick.userData.level = l.id;
      this.pickers.push(pick);
      this.house.add(pick);
    }
    for (const j of h.jacks) {
      const m = new THREE.Mesh(new THREE.BoxGeometry(0.12, 0.12, 0.12),
        new THREE.MeshBasicMaterial({ color: j.state === "live" ? 0x1a9850 : j.state === "dead" ? 0xd73027 : 0xf0a020 }));
      m.position.set(j.position[0], j.position[1], (elev.get(j.level) ?? 0) + j.z);
      this.house.add(m);
    }
    const cx = (minX + maxX) / 2, cy = (minY + maxY) / 2, span = Math.max(maxX - minX, maxY - minY, 5);
    this.controls.target.set(cx, cy, 1);
    this.camera.position.set(cx - span * 0.3, cy - span * 1.2, span * 0.9);
    this.controls.update();
  }

  private addWall(w: Wall, floorZ: number) {
    const len = Math.hypot(w.b[0] - w.a[0], w.b[1] - w.a[1]);
    if (len === 0) return;
    const ang = Math.atan2(w.b[1] - w.a[1], w.b[0] - w.a[0]);
    const z0 = floorZ + w.base_z;
    const box = (u0: number, u1: number, v0: number, v1: number, mat: THREE.Material) => {
      if (u1 - u0 < 1e-6 || v1 - v0 < 1e-6) return;
      const m = new THREE.Mesh(new THREE.BoxGeometry(u1 - u0, w.thickness, v1 - v0), mat);
      const uc = (u0 + u1) / 2;
      m.position.set(w.a[0] + Math.cos(ang) * uc, w.a[1] + Math.sin(ang) * uc, z0 + (v0 + v1) / 2);
      m.rotation.z = ang;
      this.house.add(m);
    };
    const ops = [...w.openings].sort((p, q) => p.offset - q.offset);
    let u = 0;
    for (const o of ops) {
      box(u, o.offset, 0, w.height, WALL);
      box(o.offset, o.offset + o.width, 0, o.sill, WALL);
      box(o.offset, o.offset + o.width, o.sill + o.height, w.height, WALL);
      box(o.offset, o.offset + o.width, o.sill, o.sill + o.height, OPENING);
      u = o.offset + o.width;
    }
    box(u, len, 0, w.height, WALL);
  }

  setHeatmap(hm: HeatMap | null, elevations: Map<string, number>) {
    this.heat.clear();
    this.marker.visible = false;
    if (!hm) return;
    for (const g of hm.grids) {
      const data = new Uint8Array(g.nx * g.ny * 4);
      for (let i = 0; i < g.rssi.length; i++) {
        const v = g.rssi[i];
        if (Number.isNaN(v)) continue;
        const [r, gr, b] = rssiColor(v);
        data.set([r, gr, b, 200], i * 4);
      }
      const tex = new THREE.DataTexture(data, g.nx, g.ny, THREE.RGBAFormat);
      tex.magFilter = THREE.NearestFilter;
      tex.needsUpdate = true;
      const plane = new THREE.Mesh(new THREE.PlaneGeometry(g.nx * g.step, g.ny * g.step),
        new THREE.MeshBasicMaterial({ map: tex, transparent: true, side: THREE.DoubleSide }));
      plane.position.set(g.x0 + (g.nx * g.step) / 2, g.y0 + (g.ny * g.step) / 2, (elevations.get(g.level) ?? 0) + 0.03);
      this.heat.add(plane);
    }
    this.marker.position.set(hm.tx.x, hm.tx.y, (elevations.get(hm.tx.level) ?? 0) + hm.tx.height);
    this.marker.visible = true;
  }

  dispose() {
    this.renderer.setAnimationLoop(null);
    this.renderer.dispose();
    this.renderer.domElement.remove();
  }
}
