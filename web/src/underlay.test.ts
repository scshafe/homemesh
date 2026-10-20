import { describe, expect, it } from "vitest";
import { levelLine, moveBy, pxToWorld, scaleAbout, scaleErrorPct, worldToPx } from "./underlay";
import type { P2, Underlay } from "./types";

const u0 = (): Underlay => ({ id: "u1", level: "L0", blob: "a".repeat(64), width_px: 1000, height_px: 800, scale: 0.01, rotation: 0, origin: [0, 0], opacity: 0.5, scaled: false, name: "" });
const near = (a: P2, b: P2) => { expect(a[0]).toBeCloseTo(b[0], 6); expect(a[1]).toBeCloseTo(b[1], 6); };

describe("underlay", () => {
  it("maps pixels to world with v down", () => {
    near(pxToWorld(u0(), [100, 200]), [1, -2]);
    near(pxToWorld({ ...u0(), origin: [5, 5], rotation: 90 }, [100, 0]), [5, 6]);
  });

  it("round-trips through any transform", () => {
    const u = { ...u0(), scale: 0.0173, rotation: 33, origin: [2, -4] as P2 };
    near(worldToPx(u, pxToWorld(u, [321, 654])), [321, 654]);
  });

  it("scaleAbout makes two picked points the known distance apart and keeps the first fixed", () => {
    const u = u0();
    const a = pxToWorld(u, [100, 100]), b = pxToWorld(u, [500, 100]); // 4 m apart at 0.01 m/px
    const v = scaleAbout(u, a, b, 8);
    expect(v.scaled).toBe(true);
    expect(v.scale).toBeCloseTo(0.02);
    near(pxToWorld(v, [100, 100]), a);
    const d = Math.hypot(...(pxToWorld(v, [500, 100]).map((c, i) => c - a[i]) as P2));
    expect(d).toBeCloseTo(8);
  });

  it("scaleAbout ignores a zero-length pick or a bad distance", () => {
    const u = u0();
    expect(scaleAbout(u, [1, 1], [1, 1], 3)).toBe(u);
    expect(scaleAbout(u, [0, 0], [1, 0], -3)).toBe(u);
  });

  it("levelLine turns a slanted line horizontal about its first point", () => {
    const u = { ...u0(), rotation: 7 };
    const pa: P2 = [100, 100], pb: P2 = [600, 150];
    const a = pxToWorld(u, pa), b = pxToWorld(u, pb);
    const v = levelLine(u, a, b, "x");
    near(pxToWorld(v, pa), a);
    const b2 = pxToWorld(v, pb);
    expect(b2[1]).toBeCloseTo(a[1], 6);
    expect(Math.abs(v.rotation - u.rotation)).toBeLessThan(90);
  });

  it("levelLine to vertical", () => {
    const u = u0();
    const a = pxToWorld(u, [100, 100]), b = pxToWorld(u, [130, 600]);
    const v = levelLine(u, a, b, "y");
    expect(pxToWorld(v, [130, 600])[0]).toBeCloseTo(pxToWorld(v, [100, 100])[0], 6);
  });

  it("moveBy lands the picked point on the target", () => {
    const u = { ...u0(), rotation: 20 };
    const from = pxToWorld(u, [50, 50]);
    near(pxToWorld(moveBy(u, from, [3, 4]), [50, 50]), [3, 4]);
  });

  it("scale error is signed percent", () => {
    expect(scaleErrorPct(10.5, 10)).toBeCloseTo(5);
    expect(scaleErrorPct(9, 10)).toBeCloseTo(-10);
  });
});
