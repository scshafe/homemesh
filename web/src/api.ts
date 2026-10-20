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
