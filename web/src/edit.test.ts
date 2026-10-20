import { describe, expect, it } from "vitest";
import { History, addHole, addJack, addLevel, addOpening, addWall, addZone, hitTest, nearestWall, nextId, remove, setEntry, snap } from "./edit";
import type { House } from "./types";

const base = (): House => ({
  id: "t", name: "t", synthetic: true, revision: 1, region: "US",
  levels: [{ id: "L0", name: "g", elevation: 0, height: 2.5, slab: null }], materials: [],
  walls: [], rooms: [], slab_holes: [], stairs: [], zones: [], jacks: [], outlets: [], switches: [], entry: null,
});

describe("edit", () => {
  it("ids skip taken ones", () => expect(nextId("w", ["w1", "w3"])).toBe("w2"));

  it("adds a wall with the level height; ignores a degenerate one", () => {
    const h = addWall(base(), "L0", [0, 0], [4, 0], "drywall", 0.1);
    expect(h.walls[0]).toMatchObject({ id: "w1", height: 2.5, material: "drywall", openings: [] });
    expect(addWall(h, "L0", [1, 1], [1, 1.01], "drywall", 0.1)).toBe(h);
  });

  it("snaps to endpoints first, then to the grid", () => {
    const h = addWall(base(), "L0", [0, 0], [4, 0], "drywall", 0.1);
    expect(snap(h, "L0", [4.08, 0.05])).toEqual([4, 0]);
    expect(snap(h, "L0", [2.04, 1.26])).toEqual([2, 1.3]);
  });

  it("places a door centred, clamped, and refuses overlaps", () => {
    let h = addWall(base(), "L0", [0, 0], [4, 0], "drywall", 0.1);
    h = addOpening(h, "w1", 0.1, "door", "wood-door");
    expect(h.walls[0].openings[0].offset).toBe(0);
    const again = addOpening(h, "w1", 0.5, "window", "glass");
    expect(again.walls[0].openings).toHaveLength(1);
    h = addOpening(h, "w1", 3.9, "window", "glass");
    expect(h.walls[0].openings[1].offset).toBeCloseTo(2.8);
    expect(addOpening(addWall(base(), "L0", [0, 0], [0.5, 0], "drywall", 0.1), "w1", 0.2, "door", "x").walls[0].openings).toHaveLength(0);
  });

  it("finds the nearest wall and distance along it", () => {
    const h = addWall(base(), "L0", [0, 0], [4, 0], "drywall", 0.1);
    expect(nearestWall(h, "L0", [1.5, 0.2])!.along).toBeCloseTo(1.5);
    expect(nearestWall(h, "L0", [1.5, 2])).toBeNull();
  });

  it("jack attaches to a near wall; removing the wall detaches it", () => {
    let h = addWall(base(), "L0", [0, 0], [4, 0], "drywall", 0.1);
    h = addJack(h, "L0", [1, 0.1], "cat6");
    expect(h.jacks[0].wall).toBe("w1");
    h = remove(h, { kind: "wall", id: "w1" });
    expect(h.jacks[0].wall).toBeNull();
    expect(h.walls).toHaveLength(0);
  });

  it("removing a switch clears references to it", () => {
    let h = base();
    h = { ...h, switches: [{ id: "sw1", position: [0, 0], level: "L0", ports: 8, port_rate: 1000, uplink: null }] };
    h = addJack(h, "L0", [1, 1], "cat6");
    h = { ...h, jacks: [{ ...h.jacks[0], switch: "sw1" }] };
    h = remove(h, { kind: "switch", id: "sw1" });
    expect(h.jacks[0].switch).toBeNull();
  });

  it("demand zones get a need, others none; levels stack above the last", () => {
    let h = addZone(base(), "L0", [[0, 0], [1, 0], [1, 1]], "demand");
    h = addZone(h, "L0", [[0, 0]], "allow");
    expect(h.zones[0].need).not.toBeNull();
    expect(h.zones[1].need).toBeNull();
    h = addLevel(h, "First");
    expect(h.levels[1]).toMatchObject({ id: "L1", elevation: 2.8 });
    expect(addHole(h, "L1", [[0, 0], [1, 1]])).toBe(h);
  });

  it("hit-tests points before walls before areas", () => {
    let h = addWall(base(), "L0", [0, 0], [4, 0], "drywall", 0.1);
    h = addJack(h, "L0", [1, 0], "cat6");
    h = setEntry(h, "L0", [3, 0]);
    h = addZone(h, "L0", [[0, -1], [4, -1], [4, 1], [0, 1]], "allow");
    expect(hitTest(h, "L0", [1.02, 0.01], 0.15)).toEqual({ kind: "jack", id: "j1" });
    expect(hitTest(h, "L0", [3, 0], 0.15)).toEqual({ kind: "entry" });
    expect(hitTest(h, "L0", [2, 0.05], 0.15)).toEqual({ kind: "wall", id: "w1" });
    expect(hitTest(h, "L0", [2, 0.8], 0.15)).toEqual({ kind: "zone", id: "z1" });
    expect(hitTest(h, "L0", [2, 5], 0.15)).toBeNull();
  });

  it("history undoes and redoes, and a new edit drops the redo branch", () => {
    const hist = new History(base());
    hist.push(addWall(hist.present, "L0", [0, 0], [1, 0], "drywall", 0.1));
    hist.push(addWall(hist.present, "L0", [0, 1], [1, 1], "drywall", 0.1));
    expect(hist.present.walls).toHaveLength(2);
    hist.undo();
    expect(hist.present.walls).toHaveLength(1);
    hist.redo();
    expect(hist.present.walls).toHaveLength(2);
    hist.undo();
    hist.push(addWall(hist.present, "L0", [5, 5], [6, 5], "drywall", 0.1));
    expect(hist.canRedo).toBe(false);
  });
});
