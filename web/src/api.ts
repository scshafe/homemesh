import type { HeatMap, House } from "./types";

async function req<T>(url: string, init?: RequestInit): Promise<T> {
  const r = await fetch(url, init);
  if (!r.ok) {
    let detail = "";
    try { detail = JSON.stringify((await r.json()).detail); } catch { /* not JSON */ }
    throw new ApiError(r.status, `${r.status} ${detail}`.trim());
  }
  return r.json() as Promise<T>;
}

export class ApiError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

export const listHouses = () => req<string[]>("/api/houses");
export const loadHouse = (id: string) => req<House>(`/api/houses/${encodeURIComponent(id)}`);
export const createHouse = (id: string, name: string) =>
  req<House>("/api/houses", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ id, name }) });
/** Save as the next revision; the server answers 409 if `h.revision` is stale. */
export const saveHouse = (h: House) =>
  req<House>(`/api/houses/${encodeURIComponent(h.id)}?expect_revision=${h.revision}`, {
    method: "PUT", headers: { "content-type": "application/json" }, body: JSON.stringify(h),
  });

export async function loadHeatmap(id: string, x: number, y: number, level: string, band: string): Promise<HeatMap> {
  const q = new URLSearchParams({ x: String(x), y: String(y), level, band });
  const raw = await req<{ band: string; tx: HeatMap["tx"]; grids: (Omit<HeatMap["grids"][0], "rssi"> & { rssi_f32_b64: string })[] }>(
    `/api/houses/${encodeURIComponent(id)}/heatmap?${q}`,
  );
  return {
    band: raw.band,
    tx: raw.tx,
    grids: raw.grids.map(({ rssi_f32_b64, ...g }) => {
      const bin = atob(rssi_f32_b64);
      const bytes = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      return { ...g, rssi: new Float32Array(bytes.buffer) };
    }),
  };
}

export interface Page { blob: string; width_px: number; height_px: number }
/** Upload a blueprint image or PDF; the server re-encodes each page as PNG. */
export const uploadBlueprint = (houseId: string, file: File) =>
  req<Page[]>(`/api/houses/${encodeURIComponent(houseId)}/blueprints`, { method: "POST", body: file });
export const blobUrl = (houseId: string, digest: string) => `/api/houses/${encodeURIComponent(houseId)}/blobs/${digest}`;

export interface Equip { id: string; name: string; kind: string; price: number; radios: { band: string; dedicated_backhaul: boolean }[]; max_nodes: number | null }
export interface ClientProfile { id: string; name: string }
export const loadCatalogue = () => req<{ equipment: Equip[]; clients: ClientProfile[] }>("/api/catalogue");

export interface PlanRequest { k_max: number; equipment: string[]; gateway_equipment: string; client: string; trust_unknown_jacks: boolean; price_ceiling: number | null; candidate_step: number; grid: number }
export interface NodeSpec { equipment: string; position: [number, number]; level: string; height: number }
export interface BackhaulNote { index: number; kind: string; parent: number | null; mbps: number | null; hops: number; jack: string | null; band: string | null; shared: boolean }
export interface PlanResult {
  equipment: string; k: number; score: number; score_margin: number; worst: number; cost: number; valid: boolean; must_ok: boolean; stable: boolean; pareto: boolean;
  nodes: NodeSpec[]; zones: { zone: string; utility: number; mean_rate: number; frac_target: number; must_met: boolean | null }[];
  backhaul: BackhaulNote[]; problems: string[]; jacks_used: string[]; jacks_unverified: string[];
  explanation?: { lines: string[]; stability: number | null };
}
export interface PlanOutput { gateway: NodeSpec; results: PlanResult[] }
export interface JobState { state: "running" | "done" | "error"; progress: string[]; error: string | null; result: PlanOutput | null }
const json = (body: unknown): RequestInit => ({ method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
export const startPlan = (houseId: string, r: PlanRequest) => req<{ job: string }>(`/api/houses/${encodeURIComponent(houseId)}/plans`, json(r));
export const getJob = (id: string) => req<JobState>(`/api/jobs/${id}`);

export interface RateGrid { level: string; x0: number; y0: number; step: number; nx: number; ny: number; rate: (number | null)[]; serving: number[] }
export const rateMap = (houseId: string, nodes: NodeSpec[], r: Pick<PlanRequest, "gateway_equipment" | "client" | "trust_unknown_jacks" | "grid">) =>
  req<{ grids: RateGrid[]; problems: string[] }>(`/api/houses/${encodeURIComponent(houseId)}/ratemap`, json({ nodes, ...r }));

export interface ParamFit { mean: number; sd: number; prior_mean: number; prior_sd: number; identified: boolean }
export interface BandFit { band: string; n_meas: number; n: ParamFit; extra_loss: ParamFit; materials: Record<string, ParamFit>; sigma: number; rmse_train: number; rmse_cv: number | null; bias_cv: number | null; residuals: Record<string, number>; note: string }
export interface Hint { material: string; level: string; x: number; y: number; units: number }
export interface CalibrationOut { fits: Record<string, BandFit>; suggestions: Record<string, Hint[]>; calibrated: House | null; access_points: number; measurements: number }
export const calibrate = (h: House) => req<CalibrationOut>(`/api/houses/${encodeURIComponent(h.id)}/calibrate`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(h) });
export const parseMeasurements = (houseId: string, csv: File, level: string, device: string) =>
  req<import("./types").Measurement[]>(`/api/houses/${encodeURIComponent(houseId)}/measurements/parse?${new URLSearchParams({ level, device })}`, { method: "POST", body: csv });

export interface CaptureMeta { blob: string; name: string; at: number; counts: Record<string, number>; usdz: string | null }
export interface ImportReport { walls: number; paired_walls: number; openings: number; skipped_openings: number; replaced: number; notes: string[] }
export const listCaptures = (houseId: string) => req<CaptureMeta[]>(`/api/houses/${encodeURIComponent(houseId)}/captures`);
export const importCapture = (h: House, blob: string, level: string, registration?: { src: number[][]; dst: number[][] }) =>
  req<{ house: House; report: ImportReport; registration?: { rotation: number; tx: number; ty: number; max_error_m: number } }>(
    `/api/houses/${encodeURIComponent(h.id)}/captures/${blob}/import?${new URLSearchParams({ level })}`,
    { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ house: h, registration }) });
