// Pure editing operations on a House: no DOM, no network. Each returns a new
// House (shallow-copied along the changed path) so history is a stack of values.
import type { House, JackType, Opening, P2, Prov, Wall, Zone } from "./types";

export const manual: Prov = { source: "manual" };

export type Kind = "wall" | "jack" | "outlet" | "switch" | "zone" | "hole";
export type Ref = { kind: Kind; id: string } | { kind: "entry" } | { kind: "opening"; wall: string; index: number };

export function nextId(prefix: string, taken: Iterable<string>): string {
  const used = new Set(taken);
  let n = 1;
  while (used.has(`${prefix}${n}`)) n++;
  return `${prefix}${n}`;
}

export const dist = (a: P2, b: P2) => Math.hypot(a[0] - b[0], a[1] - b[1]);
export const levelOf = (h: House, id: string) => h.levels.find((l) => l.id === id)!;

/** Snap to a nearby wall endpoint on the level, else to the grid (metres). */
export function snap(h: House, level: string, p: P2, grid = 0.1, tol = 0.15): P2 {
  let best: P2 | null = null, bd = tol;
  for (const w of h.walls) if (w.level === level) for (const e of [w.a, w.b]) {
    const d = dist(p, e);
    if (d <= bd) { bd = d; best = e; }
  }
  return best ?? [Math.round(p[0] / grid) * grid, Math.round(p[1] / grid) * grid];
}

/** Nearest wall on the level within `max` metres, and the distance along it. */
export function nearestWall(h: House, level: string, p: P2, max = 0.4): { wall: Wall; along: number } | null {
  let best: { wall: Wall; along: number } | null = null, bd = max;
  for (const w of h.walls) {
    if (w.level !== level) continue;
    const ex = w.b[0] - w.a[0], ey = w.b[1] - w.a[1], len2 = ex * ex + ey * ey;
    if (len2 === 0) continue;
    const t = Math.min(1, Math.max(0, ((p[0] - w.a[0]) * ex + (p[1] - w.a[1]) * ey) / len2));
    const d = dist(p, [w.a[0] + t * ex, w.a[1] + t * ey]);
    if (d <= bd) { bd = d; best = { wall: w, along: t * Math.sqrt(len2) }; }
  }
  return best;
}

export const wallLength = (w: Wall) => dist(w.a, w.b);

export function addWall(h: House, level: string, a: P2, b: P2, material: string, thickness: number): House {
  if (dist(a, b) < 0.05) return h;
  const w: Wall = {
    id: nextId("w", h.walls.map((x) => x.id)), level, a, b, thickness, height: levelOf(h, level).height,
    base_z: 0, material, openings: [], prov: manual,
  };
  return { ...h, walls: [...h.walls, w] };
}

const OPENING_DEFAULTS: Record<"door" | "window", Omit<Opening, "offset" | "material">> = {
  door: { kind: "door", width: 0.9, height: 2.0, sill: 0, state: "closed" },
  window: { kind: "window", width: 1.2, height: 1.2, sill: 0.9, state: "closed" },
};

/** Put a door or window centred at `along` on a wall, clamped inside it. */
export function addOpening(h: House, wallId: string, along: number, kind: "door" | "window", material: string): House {
  return mapWall(h, wallId, (w) => {
    const d = OPENING_DEFAULTS[kind];
    const len = wallLength(w);
    if (d.width > len) return w;
    const offset = Math.min(len - d.width, Math.max(0, along - d.width / 2));
    const clash = w.openings.some((o) => offset < o.offset + o.width && o.offset < offset + d.width);
    if (clash) return w;
    return { ...w, openings: [...w.openings, { ...d, offset, material, prov: manual }] };
  });
}

export function mapWall(h: House, id: string, f: (w: Wall) => Wall): House {
  return { ...h, walls: h.walls.map((w) => (w.id === id ? edited(f(w), w) : w)) };
}

function edited<T extends { prov?: Prov }>(next: T, prev: T): T {
  return next === prev || !next.prov ? next : { ...next, prov: { ...next.prov, edited: next.prov.source !== "manual" } };
}

export function addJack(h: House, level: string, p: P2, type: JackType): House {
  const near = nearestWall(h, level, p, 0.3);
  const jack = {
    id: nextId("j", h.jacks.map((x) => x.id)), position: p, level, z: 0.3, wall: near?.wall.id ?? null, type,
    state: "unknown" as const, leads_to: "unknown", switch: null, poe: false, prov: manual,
  };
  return { ...h, jacks: [...h.jacks, jack] };
}

export function addOutlet(h: House, level: string, p: P2): House {
  return { ...h, outlets: [...h.outlets, { id: nextId("o", h.outlets.map((x) => x.id)), position: p, level, z: 0.3, prov: manual }] };
}

export function addSwitch(h: House, level: string, p: P2): House {
  return { ...h, switches: [...h.switches, { id: nextId("sw", h.switches.map((x) => x.id)), position: p, level, ports: 8, port_rate: 1000, prov: manual }] };
}

export function setEntry(h: House, level: string, p: P2): House {
  return { ...h, entry: { position: p, level, kind: "modem", prov: manual } };
}

export function addZone(h: House, level: string, polygon: P2[], kind: Zone["kind"]): House {
  if (polygon.length < 1) return h;
  const z: Zone = {
    id: nextId("z", h.zones.map((x) => x.id)), level, polygon, kind, name: "", weight: 1, requires: "none", mounts: [], heights: [],
    need: kind === "demand" ? { must: false, rx_height: 1.0, min_throughput: 50 } : null, prov: manual,
  };
  return { ...h, zones: [...h.zones, z] };
}

export function addHole(h: House, level: string, polygon: P2[]): House {
  if (polygon.length < 3) return h;
  return { ...h, slab_holes: [...h.slab_holes, { id: nextId("h", h.slab_holes.map((x) => x.id)), level, polygon, prov: manual }] };
}

export function addLevel(h: House, name: string, height = 2.5, slabMaterial = "slab-wood"): House {
  const top = h.levels.reduce((m, l) => Math.max(m, l.elevation + l.height), 0);
  const slabT = 0.3;
  const id = nextId("L", h.levels.map((l) => l.id));
  const elevation = Math.round((top + slabT) * 100) / 100;
  return { ...h, levels: [...h.levels, { id, name, elevation, height, slab: { material: slabMaterial, thickness: slabT } }] };
}

export function remove(h: House, r: Ref): House {
  switch (r.kind) {
    case "wall":
      return { ...h, walls: h.walls.filter((w) => w.id !== r.id), jacks: h.jacks.map((j) => (j.wall === r.id ? { ...j, wall: null } : j)) };
    case "jack":
      return { ...h, jacks: h.jacks.filter((j) => j.id !== r.id), switches: h.switches.map((s) => (s.uplink === r.id ? { ...s, uplink: null } : s)) };
    case "outlet": return { ...h, outlets: h.outlets.filter((o) => o.id !== r.id) };
    case "switch":
      return {
        ...h, switches: h.switches.filter((s) => s.id !== r.id).map((s) => (s.uplink === r.id ? { ...s, uplink: null } : s)),
        jacks: h.jacks.map((j) => (j.switch === r.id ? { ...j, switch: null } : j)),
      };
    case "zone": return { ...h, zones: h.zones.filter((z) => z.id !== r.id) };
    case "hole": return { ...h, slab_holes: h.slab_holes.filter((x) => x.id !== r.id) };
    case "entry": return { ...h, entry: null };
    case "opening":
      return mapWall(h, r.wall, (w) => ({ ...w, openings: w.openings.filter((_, i) => i !== r.index) }));
  }
}

function distToSeg(p: P2, a: P2, b: P2): number {
  const ex = b[0] - a[0], ey = b[1] - a[1], l2 = ex * ex + ey * ey;
  const t = l2 ? Math.min(1, Math.max(0, ((p[0] - a[0]) * ex + (p[1] - a[1]) * ey) / l2)) : 0;
  return dist(p, [a[0] + t * ex, a[1] + t * ey]);
}

function inPoly(p: P2, poly: P2[]): boolean {
  let inside = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const [xi, yi] = poly[i], [xj, yj] = poly[j];
    if (yi > p[1] !== yj > p[1] && p[0] < ((xj - xi) * (p[1] - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

/** The element under `p` on `level`, nearest point-like things first. `tol` in metres. */
export function hitTest(h: House, level: string, p: P2, tol: number): Ref | null {
  const pts: [Ref, P2][] = [
    ...h.jacks.filter((j) => j.level === level).map((j): [Ref, P2] => [{ kind: "jack", id: j.id }, j.position]),
    ...h.outlets.filter((o) => o.level === level).map((o): [Ref, P2] => [{ kind: "outlet", id: o.id }, o.position]),
    ...h.switches.filter((s) => s.level === level).map((s): [Ref, P2] => [{ kind: "switch", id: s.id }, s.position]),
  ];
  if (h.entry && h.entry.level === level) pts.push([{ kind: "entry" }, h.entry.position]);
  let best: Ref | null = null, bd = tol;
  for (const [r, q] of pts) { const d = dist(p, q); if (d <= bd) { bd = d; best = r; } }
  if (best) return best;
  for (const w of h.walls) {
    if (w.level !== level) continue;
    const d = distToSeg(p, w.a, w.b);
    if (d <= Math.max(tol, w.thickness / 2) && d <= bd) { bd = d; best = { kind: "wall", id: w.id }; }
  }
  if (best) return best;
  for (const z of h.zones) if (z.level === level && (z.polygon.length >= 3 ? inPoly(p, z.polygon) : dist(p, z.polygon[0]) <= tol)) return { kind: "zone", id: z.id };
  for (const x of h.slab_holes) if (x.level === level && inPoly(p, x.polygon)) return { kind: "hole", id: x.id };
  return null;
}

/** Undo/redo over immutable House values. */
export class History {
  private past: House[] = [];
  private future: House[] = [];
  constructor(public present: House) {}
  push(next: House): void {
    if (next === this.present) return;
    this.past.push(this.present);
    if (this.past.length > 200) this.past.shift();
    this.present = next;
    this.future = [];
  }
  undo(): boolean { const p = this.past.pop(); if (!p) return false; this.future.push(this.present); this.present = p; return true; }
  redo(): boolean { const f = this.future.pop(); if (!f) return false; this.past.push(this.present); this.present = f; return true; }
  get canUndo() { return this.past.length > 0; }
  get canRedo() { return this.future.length > 0; }
}
