import { describe, expect, it } from "vitest";
import { diffColor, rateColor } from "./ratecolor";

describe("rateColor", () => {
  it("is grey with no service and for bad input", () => {
    for (const v of [null, 0, -5, NaN]) expect(rateColor(v as number)).toEqual([200, 200, 200]);
  });
  it("runs from red-ish to green-ish as the rate grows", () => {
    const [r1, g1] = rateColor(5), [r2, g2] = rateColor(1000);
    expect(r1).toBeGreaterThan(g1);
    expect(g2).toBeGreaterThan(r2);
    expect(rateColor(100000)).toEqual(rateColor(1000));
  });
  it("stays in byte range", () => {
    for (let v = 1; v < 5000; v *= 1.7) for (const c of rateColor(v)) { expect(c).toBeGreaterThanOrEqual(0); expect(c).toBeLessThanOrEqual(255); }
  });
});

describe("diffColor", () => {
  it("is white when equal, blue when B is faster, red when A is", () => {
    expect(diffColor(300, 300)).toEqual([255, 255, 255]);
    const [rb, , bb] = diffColor(100, 800), [ra, , ba] = diffColor(800, 100);
    expect(bb).toBeGreaterThan(rb);
    expect(ra).toBeGreaterThan(ba);
  });
  it("treats no service as zero", () => {
    expect(diffColor(null, 500)).not.toEqual([255, 255, 255]);
    expect(diffColor(null, null)).toEqual([255, 255, 255]);
  });
});
