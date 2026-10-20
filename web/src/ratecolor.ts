// Colour scales for client-rate maps (Mbit/s) and for the difference between two maps.

/** Log scale from 5 Mbit/s (red) to 1000 Mbit/s (green); null/NaN/0 = no service (grey). */
export function rateColor(mbps: number | null): [number, number, number] {
  if (mbps === null || !Number.isFinite(mbps) || mbps <= 0) return [200, 200, 200];
  const t = Math.min(1, Math.max(0, Math.log(mbps / 5) / Math.log(1000 / 5)));
  const hue = t * 120; // 0 red .. 120 green
  return hslToRgb(hue, 0.75, 0.5);
}

/** Blue where B is faster, red where A is faster, white near equal (relative to the larger of the two). */
export function diffColor(a: number | null, b: number | null): [number, number, number] {
  const x = a && Number.isFinite(a) ? a : 0, y = b && Number.isFinite(b) ? b : 0;
  const d = (y - x) / Math.max(x, y, 25);
  const k = Math.min(1, Math.abs(d) * 2);
  const white = 255;
  return d >= 0 ? [Math.round(white - k * 190), Math.round(white - k * 120), white] : [white, Math.round(white - k * 190), Math.round(white - k * 190)];
}

function hslToRgb(h: number, s: number, l: number): [number, number, number] {
  const c = (1 - Math.abs(2 * l - 1)) * s, x = c * (1 - Math.abs(((h / 60) % 2) - 1)), m = l - c / 2;
  const [r, g, b] = h < 60 ? [c, x, 0] : h < 120 ? [x, c, 0] : [0, c, x];
  return [Math.round((r + m) * 255), Math.round((g + m) * 255), Math.round((b + m) * 255)];
}
