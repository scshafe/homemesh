"""Synthetic houses for tests (design 2.6). Invented, never a real house.

`python -m homemesh.fixtures DIR` writes them as JSON; tests/fixtures holds the
committed copies and a test keeps the two equal.
"""

from __future__ import annotations

import sys
from pathlib import Path

from .model import (
    Entry,
    House,
    Jack,
    Level,
    Material,
    Need,
    Opening,
    Outlet,
    Room,
    Slab,
    SlabHole,
    Stair,
    Switch,
    Wall,
    Zone,
)
from .materials import default_materials
from .store import export_json


def _materials() -> list[Material]:
    return default_materials()


def _box(prefix: str, level: str, x0: float, y0: float, x1: float, y1: float, mat: str, t: float) -> list[Wall]:
    pts = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    return [
        Wall(id=f"{prefix}{i}", level=level, a=pts[i], b=pts[(i + 1) % 4], thickness=t, height=2.5, material=mat)
        for i in range(4)
    ]


def one_floor_box() -> House:
    walls = _box("e", "L0", 0, 0, 10, 8, "brick", 0.2)
    walls.append(Wall(id="p0", level="L0", a=(5, 0), b=(5, 8), thickness=0.1, height=2.5, material="drywall",
                      openings=[Opening(kind="door", offset=3.5, width=0.9, height=2.0, material="wood-door")]))
    return House(
        id="synthetic-box", name="Synthetic box", synthetic=True,
        levels=[Level(id="L0", name="Ground", elevation=0.0, height=2.5)],
        materials=_materials(), walls=walls,
        rooms=[Room(id="r0", level="L0", name="West", polygon=[(0, 0), (5, 0), (5, 8), (0, 8)]),
               Room(id="r1", level="L0", name="East", polygon=[(5, 0), (10, 0), (10, 8), (5, 8)])],
        entry=Entry(position=(0.5, 0.5), level="L0", wan_down=1000, wan_up=1000),
        outlets=[Outlet(id="o0", position=(1, 0.2), level="L0"), Outlet(id="o1", position=(9, 7.8), level="L0")],
        zones=[Zone(id="z-allow", level="L0", kind="allow", polygon=[(0, 0), (10, 0), (10, 8), (0, 8)], requires="outlet"),
               Zone(id="z-office", level="L0", kind="demand", name="Office", polygon=[(6, 4), (9, 4), (9, 7), (6, 7)],
                    weight=3.0, need=Need(min_throughput=300, must=True))],
    )


def two_floor_stairwell() -> House:
    walls = _box("a", "L0", 0, 0, 8, 6, "brick", 0.2) + _box("b", "L1", 0, 0, 8, 6, "brick", 0.2)
    return House(
        id="synthetic-two-floor", name="Synthetic two floors", synthetic=True,
        levels=[Level(id="L0", name="Ground", elevation=0.0, height=2.6),
                Level(id="L1", name="First", elevation=2.9, height=2.6, slab=Slab(material="slab-wood", thickness=0.3))],
        materials=_materials(), walls=walls,
        slab_holes=[SlabHole(id="h0", level="L1", polygon=[(6, 1), (7.5, 1), (7.5, 3), (6, 3)])],
        stairs=[Stair(id="s0", from_level="L0", to_level="L1", polygon=[(6, 1), (7.5, 1), (7.5, 3), (6, 3)])],
        entry=Entry(position=(0.5, 0.5), level="L0"),
        zones=[Zone(id="z-up", level="L1", kind="demand", polygon=[(1, 1), (4, 1), (4, 5), (1, 5)],
                    need=Need(min_throughput=100))],
    )


def long_thin() -> House:
    """30 m x 4 m: the case where wireless hops lose."""
    return House(
        id="synthetic-long", name="Synthetic long house", synthetic=True,
        levels=[Level(id="L0", name="Ground", elevation=0.0, height=2.5)],
        materials=_materials(), walls=_box("e", "L0", 0, 0, 30, 4, "brick", 0.2),
        entry=Entry(position=(0.5, 2), level="L0"),
        zones=[Zone(id="z-far", level="L0", kind="demand", polygon=[(26, 1), (29, 1), (29, 3), (26, 3)],
                    need=Need(min_throughput=200))],
    )


def wired_ends() -> House:
    """Jacks at both ends; one live, one unknown; a switch at the entry."""
    h = long_thin()
    return h.model_copy(update={
        "id": "synthetic-wired", "name": "Synthetic wired ends",
        "switches": [Switch(id="sw0", position=(0.6, 3), level="L0", uplink="entry")],
        "jacks": [Jack(id="j0", position=(0.2, 3), level="L0", wall="e3", type="cat6", state="live", switch="sw0", poe=True),
                  Jack(id="j1", position=(29.8, 1), level="L0", wall="e1", type="cat5e", state="unknown", leads_to="switch sw0")],
    })


ALL = {f.__name__: f for f in (one_floor_box, two_floor_stairwell, long_thin, wired_ends)}


def write_all(directory: Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    for name, fn in ALL.items():
        (directory / f"{name}.json").write_text(export_json(fn()))


if __name__ == "__main__":
    write_all(Path(sys.argv[1]))
