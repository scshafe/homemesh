// Subset of the house model (homemesh/model.py) the viewer reads. Generated
// types from the JSON Schema replace this when the editor (M4) needs more.
export type P2 = [number, number];
export interface Opening { kind: string; offset: number; width: number; height: number; sill: number; material: string; state: string }
export interface Wall { id: string; level: string; a: P2; b: P2; thickness: number; height: number; base_z: number; material: string; openings: Opening[] }
export interface Level { id: string; name: string; elevation: number; height: number; slab: { material: string; thickness: number } | null }
export interface Poly { level: string; polygon: P2[] }
export interface Zone extends Poly { id: string; kind: "allow" | "forbid" | "demand"; name: string }
export interface Jack { id: string; position: P2; level: string; z: number; type: string; state: string }
export interface House {
  id: string; name: string; synthetic: boolean; levels: Level[]; walls: Wall[];
  slab_holes: Poly[]; stairs: (Poly & { void: boolean; to_level: string })[]; zones: Zone[]; jacks: Jack[];
  entry: { position: P2; level: string } | null;
}
export interface Grid { level: string; x0: number; y0: number; step: number; nx: number; ny: number; rssi: Float32Array }
export interface HeatMap { band: string; tx: { x: number; y: number; level: string; height: number }; grids: Grid[] }
