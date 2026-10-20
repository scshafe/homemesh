"""CLI: write RSSI heat-map grids for a fixture/house JSON to a directory.

    python -m homemesh.sim HOUSE.json OUTDIR --tx X Y LEVEL [--height H] [--band 5]

Writes OUTDIR/<level>-<band>.npy (float32, NaN in walls) and OUTDIR/meta.json.
OUTDIR must be outside the repository.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from .model import House
from .propagation import BAND_MHZ, Tx, level_grid, rssi_map

ROOT = Path(__file__).resolve().parent.parent


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="homemesh.sim")
    ap.add_argument("house")
    ap.add_argument("out")
    ap.add_argument("--tx", nargs=3, metavar=("X", "Y", "LEVEL"), required=True)
    ap.add_argument("--height", type=float, default=1.8)
    ap.add_argument("--band", action="append", choices=sorted(BAND_MHZ))
    ap.add_argument("--step", type=float, default=0.5)
    a = ap.parse_args(argv)

    out = Path(a.out).resolve()
    if out == ROOT or ROOT in out.parents:
        ap.error("OUTDIR must be outside the repository")
    house = House.model_validate_json(Path(a.house).read_text())
    problems = house.validate_refs()
    if problems:
        ap.error("invalid house: " + "; ".join(problems))
    tx = Tx((float(a.tx[0]), float(a.tx[1])), a.tx[2], height=a.height)
    out.mkdir(parents=True, exist_ok=True)
    meta = {"tx": a.tx, "grids": []}
    for band in a.band or sorted(BAND_MHZ):
        for lv in house.levels:
            if not any(w.level == lv.id for w in house.walls):
                continue
            g = level_grid(house, lv.id, a.step)
            m = rssi_map(house, tx, band, g)
            np.save(out / f"{lv.id}-{band}.npy", m)
            meta["grids"].append({"level": lv.id, "band": band, "x0": g.x0, "y0": g.y0, "step": g.step,
                                  "nx": g.nx, "ny": g.ny, "min": float(np.nanmin(m)), "max": float(np.nanmax(m))})
    (out / "meta.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(f"wrote {len(meta['grids'])} grids")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
