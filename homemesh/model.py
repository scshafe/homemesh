"""The house data model (docs/design.md section 2).

One versioned document per house. Units: metres, dB, dBm, Mbit/s. Frame: +Z up,
one frame for all levels. The pydantic types are the single source of truth;
the JSON Schema is generated from them (`homemesh.schema`).
"""

from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

SCHEMA_VERSION = 1

Point2 = tuple[float, float]
Point3 = tuple[float, float, float]
Band = Literal["2.4", "5", "6"]
Source = Literal["scan", "blueprint", "photo", "manual"]


class _Base(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Prov(_Base):
    """Where an element came from (design 2.2)."""

    source: Source
    ref: str | None = None  # an import id or blob hash inside the data directory
    confidence: float = Field(default=1.0, ge=0.0, le=1.0)
    edited: bool = False
    at: datetime | None = None


def manual() -> Prov:
    return Prov(source="manual")


class Material(_Base):
    id: str
    name: str
    # dB at ref_thickness (metres), per band; prior_sd is the literature spread.
    loss: dict[Band, float]
    ref_thickness: float = Field(gt=0)
    prior_sd: float = Field(default=2.0, ge=0)
    source: str = "unsourced"  # a citation, or "unsourced" until M2 sources it


class Slab(_Base):
    material: str
    thickness: float = Field(gt=0)


class Level(_Base):
    id: str
    name: str
    elevation: float  # Z of the top of the finished floor
    height: float = Field(gt=0)  # floor to ceiling
    slab: Slab | None = None  # structure below this level; None for the lowest
    height_source: Literal["default", "walls", "stair"] = "default"  # where `height` came from (stack.py)
    below_ground: bool = False  # a basement; `House.levels` is the stack, bottom to top (homemesh/stack.py)


class Opening(_Base):
    kind: Literal["door", "window", "arch", "hole"]
    offset: float = Field(ge=0)  # from wall endpoint a, along the wall
    width: float = Field(gt=0)
    height: float = Field(gt=0)
    sill: float = Field(default=0.0, ge=0)
    material: str
    state: Literal["open", "closed"] = "closed"
    prov: Prov = Field(default_factory=manual)


class WallCurve(_Base):
    """The true arc a curved wall was approximated by chords of (plan metres, degrees)."""
    group: str  # the chords of one curved wall share it
    cx: float
    cy: float
    radius: float = Field(gt=0)
    a0: float
    a1: float


class Wall(_Base):
    id: str
    level: str
    a: Point2
    b: Point2
    thickness: float = Field(gt=0)
    height: float = Field(gt=0)
    base_z: float = 0.0  # above the level's floor
    material: str
    thickness_defaulted: bool = False  # true when a scan gave no thickness
    material_defaulted: bool = False
    # Non-rectangular walls (a scan under a sloped or vaulted ceiling): the outline as (offset along a to b, height above
    # base_z) points. The RF model keeps using the rectangle `height`; the 3D view draws the profile.
    profile: list[tuple[float, float]] | None = None
    curve: WallCurve | None = None
    openings: list[Opening] = Field(default_factory=list)
    prov: Prov = Field(default_factory=manual)

    @property
    def length(self) -> float:
        return ((self.b[0] - self.a[0]) ** 2 + (self.b[1] - self.a[1]) ** 2) ** 0.5


class Room(_Base):
    id: str
    level: str
    name: str
    description: str = ""
    polygon: list[Point2] = Field(min_length=3)
    kind: str = "room"
    prov: Prov = Field(default_factory=manual)


class SlabHole(_Base):
    id: str
    level: str  # the level whose floor has the hole
    polygon: list[Point2] = Field(min_length=3)
    prov: Prov = Field(default_factory=manual)


class Stair(_Base):
    id: str
    from_level: str
    to_level: str
    polygon: list[Point2] = Field(min_length=3)
    void: bool = True  # an open stairwell: also a SlabHole on to_level
    prov: Prov = Field(default_factory=manual)


JackType = Literal["cat5e", "cat6", "cat6a", "coax_moca"]


class Entry(_Base):
    position: Point2
    level: str
    kind: Literal["modem", "ont", "coax_drop"] = "modem"
    wan_down: float | None = Field(default=None, gt=0)  # Mbit/s
    wan_up: float | None = Field(default=None, gt=0)
    leads_to: str | None = None
    prov: Prov = Field(default_factory=manual)


class Switch(_Base):
    id: str
    position: Point2
    level: str
    ports: int = Field(default=8, gt=0)
    port_rate: float = Field(default=1000.0, gt=0)
    uplink: str | None = None  # a Jack id, a Switch id, or "entry"
    prov: Prov = Field(default_factory=manual)


class Jack(_Base):
    id: str
    position: Point2
    level: str
    z: float = 0.3  # height above the level's floor
    wall: str | None = None
    type: JackType
    state: Literal["live", "dead", "unknown"] = "unknown"
    leads_to: str = "unknown"  # free text
    switch: str | None = None  # structured: the Switch id it terminates on
    poe: bool = False
    run_length: float | None = Field(default=None, gt=0)
    measured_rate: float | None = Field(default=None, gt=0)  # Mbit/s
    prov: Prov = Field(default_factory=manual)


class Outlet(_Base):
    id: str
    position: Point2
    level: str
    z: float = 0.3
    circuit: str | None = None
    prov: Prov = Field(default_factory=manual)


class Need(_Base):
    min_rssi: float | None = None  # dBm
    min_throughput: float | None = Field(default=None, gt=0)  # Mbit/s
    max_latency: float | None = Field(default=None, gt=0)  # ms; proxy only in v1
    band_pref: Band | None = None
    must: bool = False
    rx_height: float = Field(default=1.0, ge=0)


class Zone(_Base):
    id: str
    level: str
    polygon: list[Point2] = Field(min_length=1)  # one point = a single spot
    kind: Literal["allow", "forbid", "demand"]
    name: str = ""
    weight: float = Field(default=1.0, ge=0)  # demand
    need: Need | None = None  # demand
    requires: Literal["outlet", "poe", "none"] = "none"  # allow
    mounts: list[Literal["floor", "shelf", "ceiling", "wall"]] = Field(default_factory=list)
    heights: list[float] = Field(default_factory=list)  # allowed mount heights
    prov: Prov = Field(default_factory=manual)

    @model_validator(mode="after")
    def _kind_fields(self) -> Zone:
        if self.kind == "demand" and self.need is None:
            raise ValueError(f"zone {self.id}: a demand zone needs `need`")
        if self.kind != "demand" and self.need is not None:
            raise ValueError(f"zone {self.id}: only a demand zone has `need`")
        return self


class Underlay(_Base):
    """A blueprint image under the plan of one level (design section 11).

    World position of image pixel (u, v), v down: origin + R(rotation) * (scale*u, -scale*v).
    `blob` is a PNG in the house's blob store (the upload is re-encoded, so no metadata survives).
    """

    id: str
    level: str
    blob: str = Field(pattern=r"^[0-9a-f]{64}$")
    width_px: int = Field(gt=0)
    height_px: int = Field(gt=0)
    scale: float = Field(gt=0)  # metres per pixel
    rotation: float = 0.0  # degrees, counter-clockwise in the plan
    origin: Point2 = (0.0, 0.0)  # world position of the top-left pixel
    opacity: float = Field(default=0.5, ge=0.0, le=1.0)
    scaled: bool = False  # true once the owner has set the scale from a known dimension
    name: str = ""
    prov: Prov = Field(default_factory=lambda: Prov(source="blueprint"))


class AccessPoint(_Base):
    """The house's existing access point: the known source for calibration walks."""

    id: str
    name: str = ""
    position: Point2
    level: str
    height: float = Field(default=1.5, ge=0)
    eirp_dbm: float = 23.0  # transmit power plus antenna gain; the fit absorbs an error in it as extra loss
    bssids: list[str] = Field(default_factory=list)  # one per band/radio, as the device reports them
    prov: Prov = Field(default_factory=manual)


class Calibration(_Base):
    """What the last accepted fit changed (design section 7)."""

    at: datetime | None = None
    n: dict[Band, float] = Field(default_factory=dict)
    extra_loss_db: dict[Band, float] = Field(default_factory=dict)
    rmse_cv: dict[Band, float | None] = Field(default_factory=dict)  # held-out error by area
    n_measurements: dict[Band, int] = Field(default_factory=dict)


class Measurement(_Base):
    id: str
    position: Point2
    level: str
    device: str
    band: Band
    bssid: str | None = None
    rssi: float | None = None
    snr: float | None = None
    throughput: float | None = None
    at: datetime | None = None


class PlacedNode(_Base):
    equipment: str
    position: Point2
    level: str
    mount_height: float = Field(default=1.0, ge=0)
    backhaul: Literal["auto", "wired", "wireless"] = "auto"
    jack: str | None = None  # when wired
    parent: int | None = None  # index into nodes, when wireless


class Arrangement(_Base):
    id: str
    name: str = ""
    nodes: list[PlacedNode]


class MeasureCheck(_Base):
    """A tape-measure reading against what the scan says (the accuracy check before deciding about blueprints)."""

    id: str
    what: str  # "Kitchen north wall", "Front door width", "Ceiling height"
    level: str | None = None
    wall: str | None = None  # the wall id at the time (ids can change when a scan is imported again)
    scanned: float = Field(gt=0)  # metres, as the plan has it
    measured: float = Field(gt=0)  # metres, the tape
    at: str = ""  # ISO date


class House(_Base):
    schema_version: int = SCHEMA_VERSION
    id: str
    name: str
    synthetic: bool = False  # fixtures must say true (design 2.6)
    jog_fold: float = Field(default=0.3, ge=0.0)  # walls shorter than this between two walls are folded into them on import
    region: str = "US"  # regulatory domain; strictest common until stated
    revision: int = 0
    levels: list[Level] = Field(min_length=1)
    materials: list[Material] = Field(default_factory=list)
    walls: list[Wall] = Field(default_factory=list)
    rooms: list[Room] = Field(default_factory=list)
    slab_holes: list[SlabHole] = Field(default_factory=list)
    measure_checks: list[MeasureCheck] = Field(default_factory=list)
    stairs: list[Stair] = Field(default_factory=list)
    entry: Entry | None = None
    switches: list[Switch] = Field(default_factory=list)
    jacks: list[Jack] = Field(default_factory=list)
    outlets: list[Outlet] = Field(default_factory=list)
    zones: list[Zone] = Field(default_factory=list)
    underlays: list[Underlay] = Field(default_factory=list)
    access_points: list[AccessPoint] = Field(default_factory=list)
    calibration: Calibration | None = None
    measurements: list[Measurement] = Field(default_factory=list)
    arrangements: list[Arrangement] = Field(default_factory=list)

    def validate_refs(self) -> list[str]:
        """Referential integrity; returns problems (empty when sound)."""
        errs: list[str] = []
        levels = {lv.id for lv in self.levels}
        mats = {m.id for m in self.materials}
        walls = {w.id for w in self.walls}
        switches = {s.id for s in self.switches}
        jacks = {j.id for j in self.jacks}

        def dupes(kind: str, ids: list[str]) -> None:
            seen: set[str] = set()
            for i in ids:
                if i in seen:
                    errs.append(f"duplicate {kind} id {i}")
                seen.add(i)

        dupes("level", [x.id for x in self.levels])
        dupes("material", [x.id for x in self.materials])
        dupes("wall", [x.id for x in self.walls])
        dupes("room", [x.id for x in self.rooms])
        dupes("switch", [x.id for x in self.switches])
        dupes("jack", [x.id for x in self.jacks])
        dupes("outlet", [x.id for x in self.outlets])
        dupes("zone", [x.id for x in self.zones])
        dupes("measure check", [x.id for x in self.measure_checks])

        def lv(what: str, level: str) -> None:
            if level not in levels:
                errs.append(f"{what}: unknown level {level}")

        def mat(what: str, m: str) -> None:
            if m not in mats and m != "air":
                errs.append(f"{what}: unknown material {m}")

        for level in self.levels:
            if level.slab:
                mat(f"level {level.id} slab", level.slab.material)
        for w in self.walls:
            lv(f"wall {w.id}", w.level)
            mat(f"wall {w.id}", w.material)
            if w.length == 0:
                errs.append(f"wall {w.id}: zero length")
            for o in w.openings:
                mat(f"wall {w.id} opening", o.material)
                if o.offset + o.width > w.length + 1e-9:
                    errs.append(f"wall {w.id}: opening runs past the wall end")
        for r in self.rooms:
            lv(f"room {r.id}", r.level)
        for h in self.slab_holes:
            lv(f"slab hole {h.id}", h.level)
        for s in self.stairs:
            lv(f"stair {s.id}", s.from_level)
            lv(f"stair {s.id}", s.to_level)
        if self.entry:
            lv("entry", self.entry.level)
        for s in self.switches:
            lv(f"switch {s.id}", s.level)
            if s.uplink and s.uplink != "entry" and s.uplink not in jacks | switches:
                errs.append(f"switch {s.id}: unknown uplink {s.uplink}")
        for j in self.jacks:
            lv(f"jack {j.id}", j.level)
            if j.wall and j.wall not in walls:
                errs.append(f"jack {j.id}: unknown wall {j.wall}")
            if j.switch and j.switch not in switches:
                errs.append(f"jack {j.id}: unknown switch {j.switch}")
        for o in self.outlets:
            lv(f"outlet {o.id}", o.level)
        for z in self.zones:
            lv(f"zone {z.id}", z.level)
        dupes("underlay", [x.id for x in self.underlays])
        dupes("access point", [x.id for x in self.access_points])
        dupes("measurement", [x.id for x in self.measurements])
        for a in self.access_points:
            lv(f"access point {a.id}", a.level)
        for u in self.underlays:
            lv(f"underlay {u.id}", u.level)
        for m in self.measurements:
            lv(f"measurement {m.id}", m.level)
        for a in self.arrangements:
            for n in a.nodes:
                lv(f"arrangement {a.id}", n.level)
                if n.jack and n.jack not in jacks:
                    errs.append(f"arrangement {a.id}: unknown jack {n.jack}")
                if n.parent is not None and not 0 <= n.parent < len(a.nodes):
                    errs.append(f"arrangement {a.id}: bad parent index")
        return errs
