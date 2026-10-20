// Blueprint underlay geometry (design section 11). World position of image pixel
// (u, v), v down: origin + R(rotation) * (scale*u, -scale*v). Pure functions.
import type { P2, Underlay } from "./types";

const rad = (d: number) => (d * Math.PI) / 180;
const rot = (p: P2, deg: number): P2 => {
  const c = Math.cos(rad(deg)), s = Math.sin(rad(deg));
  return [c * p[0] - s * p[1], s * p[0] + c * p[1]];
};

export function pxToWorld(u: Underlay, px: P2): P2 {
  const r = rot([u.scale * px[0], -u.scale * px[1]], u.rotation);
  return [u.origin[0] + r[0], u.origin[1] + r[1]];
}

export function worldToPx(u: Underlay, w: P2): P2 {
  const r = rot([w[0] - u.origin[0], w[1] - u.origin[1]], -u.rotation);
  return [r[0] / u.scale, -r[1] / u.scale];
}

const len = (a: P2, b: P2) => Math.hypot(b[0] - a[0], b[1] - a[1]);

/** Rescale so the world points a and b (picked on the drawing) are `metres` apart; a stays put. */
export function scaleAbout(u: Underlay, a: P2, b: P2, metres: number): Underlay {
  const d = len(a, b);
  if (d < 1e-9 || !(metres > 0)) return u;
  const f = metres / d;
  return { ...u, scale: u.scale * f, scaled: true, origin: [a[0] + f * (u.origin[0] - a[0]), a[1] + f * (u.origin[1] - a[1])] };
}

/** Rotate about a so that the line a-b becomes horizontal (axis "x") or vertical ("y"). */
export function levelLine(u: Underlay, a: P2, b: P2, axis: "x" | "y"): Underlay {
  if (len(a, b) < 1e-9) return u;
  let ang = (Math.atan2(b[1] - a[1], b[0] - a[0]) * 180) / Math.PI - (axis === "y" ? 90 : 0);
  ang = ((((ang + 90) % 180) + 180) % 180) - 90; // into [-90, 90): the smallest turn
  const delta = -ang;
  const o = rot([u.origin[0] - a[0], u.origin[1] - a[1]], delta);
  return { ...u, rotation: u.rotation + delta, origin: [a[0] + o[0], a[1] + o[1]] };
}

/** Move so the drawing point `from` lands on `to`. */
export function moveBy(u: Underlay, from: P2, to: P2): Underlay {
  return { ...u, origin: [u.origin[0] + to[0] - from[0], u.origin[1] + to[1] - from[1]] };
}

/** How far the measured length is from the known one, in percent (signed). */
export function scaleErrorPct(measured: number, known: number): number {
  return ((measured - known) / known) * 100;
}
