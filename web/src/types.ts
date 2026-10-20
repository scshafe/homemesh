// The house model (homemesh/model.py) as the front end edits it. Fields the
// editor does not touch pass through unchanged because edits spread the loaded
// object. Generated types from the JSON Schema can replace this later.
export type P2 = [number, number];
export interface Prov { source: "scan" | "blueprint" | "photo" | "manual"; ref?: string | null; confidence?: number; edited?: boolean }
export interface Opening { kind: "door" | "window" | "arch" | "hole"; offset: number; width: number; height: number; sill: number; material: string; state: "open" | "closed"; prov?: Prov }
export interface Wall { id: string; level: string; a: P2; b: P2; thickness: number; height: number; base_z: number; material: string; openings: Opening[]; prov?: Prov; [k: string]: unknown }
export interface Level { id: string; name: string; elevation: number; height: number; slab: { material: string; thickness: number } | null }
export interface Material { id: string; name: string; loss: Record<string, number>; ref_thickness: number }
export interface Poly { id: string; level: string; polygon: P2[]; prov?: Prov }
export interface Need { min_rssi?: number | null; min_throughput?: number | null; max_latency?: number | null; band_pref?: string | null; must: boolean; rx_height: number }
export interface Zone extends Poly { kind: "allow" | "forbid" | "demand"; name: string; weight: number; need: Need | null; requires: "outlet" | "poe" | "none"; mounts: string[]; heights: number[] }
export type JackType = "cat5e" | "cat6" | "cat6a" | "coax_moca";
export interface Jack { id: string; position: P2; level: string; z: number; wall?: string | null; type: JackType; state: "live" | "dead" | "unknown"; leads_to: string; switch?: string | null; poe: boolean; prov?: Prov; [k: string]: unknown }
export interface Outlet { id: string; position: P2; level: string; z: number; prov?: Prov }
export interface Switch { id: string; position: P2; level: string; ports: number; port_rate: number; uplink?: string | null; prov?: Prov }
export interface Entry { position: P2; level: string; kind: string; wan_down?: number | null; wan_up?: number | null; prov?: Prov }
export interface Underlay { id: string; level: string; blob: string; width_px: number; height_px: number; scale: number; rotation: number; origin: P2; opacity: number; scaled: boolean; name: string; prov?: Prov }
export interface Stair extends Poly { from_level: string; to_level: string; void: boolean }
export interface House {
  id: string; name: string; synthetic: boolean; revision: number; region: string;
  levels: Level[]; materials: Material[]; walls: Wall[]; rooms: Poly[];
  slab_holes: Poly[]; stairs: Stair[]; zones: Zone[]; underlays: Underlay[]; jacks: Jack[]; outlets: Outlet[]; switches: Switch[];
  entry: Entry | null;
  [k: string]: unknown;
}
export interface Grid { level: string; x0: number; y0: number; step: number; nx: number; ny: number; rssi: Float32Array }
export interface HeatMap { band: string; tx: { x: number; y: number; level: string; height: number }; grids: Grid[] }
