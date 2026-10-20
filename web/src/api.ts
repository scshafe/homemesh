import type { HeatMap, House } from "./types";

async function get<T>(url: string): Promise<T> {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`${r.status} ${url}`);
  return r.json() as Promise<T>;
}

export const listHouses = () => get<string[]>("/api/houses");
export const loadHouse = (id: string) => get<House>(`/api/houses/${encodeURIComponent(id)}`);

export async function loadHeatmap(id: string, x: number, y: number, level: string, band: string): Promise<HeatMap> {
  const q = new URLSearchParams({ x: String(x), y: String(y), level, band });
  const raw = await get<{ band: string; tx: HeatMap["tx"]; grids: (Omit<HeatMap["grids"][0], "rssi"> & { rssi_f32_b64: string })[] }>(
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
