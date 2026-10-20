"""Backhaul and client-rate evaluation of one arrangement (design sections 4, 5.2).

An arrangement is a gateway (at the internet entry) plus extra nodes. Each extra
node reaches the gateway over a wired link (a live jack whose switch chain
reaches the entry) or a wireless hop to another node. Each cell of the house
then gets the best client rate over the nodes, limited by that node's
end-to-end backhaul.

Modelling choices stated in the design and kept here:
  * single client, otherwise idle network, downlink;
  * wireless hops that can hear each other share airtime: the path rate is
    min over hops i of 1 / sum_{j in S_i} (1 / r_j), where S_i is hop i plus the
    adjacent hops and the hops within carrier-sense range on the same band;
  * a node whose backhaul uses a radio it also serves clients with loses airtime
    on that band: client rate there is 1 / (1/access + 1/backhaul);
  * parents are chosen greedily, best end-to-end rate first (real systems steer
    in their own way);
  * no interference from neighbours or from other nodes of the same arrangement.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from .equipment import Client, ClientRadio, Equipment, Radio
from .model import Band, House
from .propagation import Grid, Params, _in_polygon, grid_mask, level_grid, level_z, path_loss
from .rates import MAC_EFFICIENCY, noise_floor_dbm, throughput

# Strictest-common-region widths (owner decision D13 pending): no 40 MHz on 2.4, 80 MHz at most above.
BAND_WIDTH_CAP: dict[str, int] = {"2.4": 20, "5": 80, "6": 80}
JACK_RATE: dict[str, float] = {"cat5e": 1000.0, "cat6": 2500.0, "cat6a": 5000.0, "coax_moca": 1000.0}  # D9, conservative
CARRIER_SENSE_LOSS_DB = 100.0  # two nodes closer than this path loss share a channel
_STD = {"n": 0, "ac": 1, "ax": 2}
_STD_NAME = ["n", "ac", "ax"]


@dataclass(frozen=True)
class Placement:
    equipment: str
    position: tuple[float, float]
    level: str
    height: float = 1.5


@dataclass(frozen=True)
class Policy:
    floor_mbps: float = 25.0  # a cell below this earns no utility
    margin_db: float = 6.0  # shadowing margin for the robust evaluation (design 3.7)
    mac_eff: float = MAC_EFFICIENCY
    trust_unknown_jacks: bool = False  # the "if it works" variant (D9)
    must_fraction: float = 0.9  # a `must` zone is met when this share of its cells reach the target at the margin


@dataclass
class NodeResult:
    index: int
    kind: str  # gateway | wired | wireless | disconnected
    parent: int | None = None
    backhaul_mbps: float = 0.0
    hops: int = 0
    jack: str | None = None
    link_band: str | None = None
    shared_radio: bool = False


@dataclass
class Evaluation:
    problems: list[str]
    nodes: list[NodeResult]
    rate: np.ndarray  # best client rate per cell, Mbit/s
    serving: np.ndarray  # serving node index per cell, -1 where none
    limited_by: np.ndarray  # 0 access, 1 backhaul, per cell
    cost: float
    jacks_used: list[str] = field(default_factory=list)
    jacks_unverified: list[str] = field(default_factory=list)

    @property
    def valid(self) -> bool:
        return not self.problems


def _std_min(a: str, b: str) -> str:
    return _STD_NAME[min(_STD[a], _STD[b])]


class Context:
    """House + catalogue + client, with the receiver grid and cached loss maps."""

    def __init__(self, house: House, catalogue: dict[str, Equipment], client: Client,
                 params: Params | None = None, step: float = 0.5, rx_height: float = 1.0):
        self.house, self.catalogue, self.client = house, catalogue, client
        self.params = params or Params()
        self.grids: list[Grid] = [level_grid(house, lv.id, step, rx_height) for lv in house.levels
                                  if any(w.level == lv.id for w in house.walls)]
        pts, lvl, ok = [], [], []
        for gi, g in enumerate(self.grids):
            p = g.points()
            pts.append(np.column_stack([p, np.full(len(p), g.z)]))
            lvl.append(np.full(len(p), gi))
            ok.append(grid_mask(house, g))
        self.cells = np.vstack(pts) if pts else np.zeros((0, 3))
        self.cell_level = np.concatenate(lvl) if lvl else np.zeros(0, dtype=int)
        self.cell_ok = np.concatenate(ok) if ok else np.zeros(0, dtype=bool)
        self._loss: dict[tuple, np.ndarray] = {}
        self._pair: dict[tuple, float] = {}
        self._elev = level_z(house)

    def abs_pos(self, pl: Placement) -> tuple[float, float, float]:
        return (pl.position[0], pl.position[1], self._elev[pl.level] + pl.height)

    def loss_to_cells(self, pl: Placement, band: str) -> np.ndarray:
        key = (pl.position, pl.level, pl.height, band)
        if key not in self._loss:
            self._loss[key] = path_loss(self.house, self.abs_pos(pl), self.cells, band, self.params)  # type: ignore[arg-type]
        return self._loss[key]

    def pair_loss(self, a: Placement, b: Placement, band: str) -> float:
        k = (a.position, a.level, a.height, b.position, b.level, b.height, band)
        k2 = (b.position, b.level, b.height, a.position, a.level, a.height, band)
        if k not in self._pair:
            v = float(path_loss(self.house, self.abs_pos(a), np.array([self.abs_pos(b)]), band, self.params)[0])  # type: ignore[arg-type]
            self._pair[k] = self._pair[k2] = v
        return self._pair[k]

    def zone_mask(self, zone) -> np.ndarray:
        lv = [i for i, g in enumerate(self.grids) if g.level == zone.level]
        m = np.zeros(len(self.cells), dtype=bool)
        if not lv:
            return m
        sel = self.cell_level == lv[0]
        pts = self.cells[sel][:, :2]
        if len(zone.polygon) >= 3:
            inside = _in_polygon(pts, [tuple(p) for p in zone.polygon])
        else:
            inside = np.hypot(pts[:, 0] - zone.polygon[0][0], pts[:, 1] - zone.polygon[0][1]) <= 0.75
        m[sel] = inside
        return m


# --- wired fabric --------------------------------------------------------------

def jack_rate(jack) -> float:
    return jack.measured_rate if jack.measured_rate else JACK_RATE[jack.type]


def wired_at(house: House, pl: Placement, trust_unknown: bool, near: float = 0.6):
    """(rate, jack id, verified) for a live jack at `pl` whose chain reaches the entry, else None."""
    usable = {"live", "unknown"} if trust_unknown else {"live"}
    jacks = {j.id: j for j in house.jacks}
    switches = {s.id: s for s in house.switches}

    def chain(switch_id: str | None, seen: frozenset[str] = frozenset()) -> float | None:
        if switch_id is None or switch_id in seen or switch_id not in switches:
            return None
        s = switches[switch_id]
        up = s.uplink
        if up == "entry":
            return s.port_rate
        if up in switches:
            r = chain(up, seen | {switch_id})
            return None if r is None else min(r, s.port_rate)
        if up in jacks and jacks[up].state in usable:
            r = chain(jacks[up].switch, seen | {switch_id})
            return None if r is None else min(r, s.port_rate, jack_rate(jacks[up]))
        return None

    best = None
    for j in house.jacks:
        if j.level != pl.level or j.state not in usable:
            continue
        if np.hypot(j.position[0] - pl.position[0], j.position[1] - pl.position[1]) > near:
            continue
        up = chain(j.switch)
        if up is None:
            continue
        rate = min(jack_rate(j), up)
        if best is None or rate > best[0]:
            best = (rate, j.id, j.state == "live")
    return best


# --- radio math ------------------------------------------------------------------

def _client_radio(client: Client, band: str) -> ClientRadio | None:
    return client.radios.get(band)  # type: ignore[call-overload]


def access_rate(ctx: Context, pl: Placement, radio: Radio, policy: Policy, margin: float) -> np.ndarray:
    """Client rate per cell served by `radio` of the node at `pl` (Mbit/s)."""
    cr = _client_radio(ctx.client, radio.band)
    if cr is None:
        return np.zeros(len(ctx.cells))
    width = min(radio.max_width, cr.max_width, BAND_WIDTH_CAP[radio.band])
    rssi = radio.tx_dbm + radio.ant_gain_dbi + cr.ant_gain_dbi - (ctx.loss_to_cells(pl, radio.band) + margin)
    snr = rssi - noise_floor_dbm(width, ctx.client.noise_figure_db)
    rate = throughput(snr, _std_min(radio.standard, cr.standard), width, min(radio.chains, cr.chains), policy.mac_eff)
    return np.where(ctx.cell_ok, rate, 0.0)


def link_rate(ctx: Context, parent: Placement, child: Placement, policy: Policy, margin: float = 0.0):
    """Best wireless backhaul link between two placed nodes: (rate, band, shared_radio) or None."""
    pe, ce = ctx.catalogue[parent.equipment], ctx.catalogue[child.equipment]
    best = None
    for cr in ce.backhaul_radios():
        cands = [r for r in pe.radios if r.band == cr.band and (r.dedicated_backhaul or not cr.dedicated_backhaul)]
        for pr in cands:
            if cr.dedicated_backhaul and not pr.dedicated_backhaul:
                continue
            loss = ctx.pair_loss(parent, child, cr.band) + margin
            width = min(pr.max_width, cr.max_width, BAND_WIDTH_CAP[cr.band])
            # the weaker direction limits a symmetric link
            r_down = pr.tx_dbm + pr.ant_gain_dbi + cr.ant_gain_dbi - loss
            r_up = cr.tx_dbm + cr.ant_gain_dbi + pr.ant_gain_dbi - loss
            snr = min(r_down, r_up) - noise_floor_dbm(width, 7.0)
            rate = float(throughput(snr, _std_min(pr.standard, cr.standard), width, min(pr.chains, cr.chains), policy.mac_eff))
            if rate > 0 and (best is None or rate > best[0]):
                best = (rate, cr.band, not cr.dedicated_backhaul)
    return best


def path_rate(ctx: Context, hops: list[tuple[Placement, Placement, float, str]]) -> float:
    """Rate of a chain of wireless hops (parent, child, rate, band) with airtime sharing."""
    if not hops:
        return float("inf")
    worst = float("inf")
    for i, (a, b, r, band) in enumerate(hops):
        inv = 1.0 / r
        for j, (c, d, r2, band2) in enumerate(hops):
            if j == i or band2 != band:
                continue
            if {a, b} & {c, d} or min(ctx.pair_loss(x, y, band) for x in (a, b) for y in (c, d)) <= CARRIER_SENSE_LOSS_DB:
                inv += 1.0 / r2
        worst = min(worst, 1.0 / inv)
    return worst


# --- the arrangement -------------------------------------------------------------

def evaluate(ctx: Context, gateway: Placement, extras: list[Placement], policy: Policy = Policy(),
             margin: float = 0.0) -> Evaluation:
    """Resolve backhaul and per-cell client rate. `margin` dB is added to every path loss (robust run)."""
    house, cat = ctx.house, ctx.catalogue
    nodes_pl = [gateway, *extras]
    problems: list[str] = []
    cost = sum(cat[p.equipment].price for p in nodes_pl)
    wan = house.entry.wan_down if house.entry and house.entry.wan_down else float("inf")
    gw_port = cat[gateway.equipment].port_rate or float("inf")

    # system limits
    systems = {cat[p.equipment].system for p in nodes_pl[1:] if cat[p.equipment].system}
    for p in nodes_pl[1:]:
        e = cat[p.equipment]
        if e.max_nodes is not None and len(nodes_pl) > e.max_nodes:
            problems.append(f"{e.name}: system allows at most {e.max_nodes} nodes")
    if len(systems) > 1:
        problems.append("nodes from different mesh systems")

    res = [NodeResult(0, "gateway", None, wan, 0)]
    paths: dict[int, list[tuple[Placement, Placement, float, str]]] = {0: []}
    done = {0}
    jacks_used: list[str] = []
    jacks_unverified: list[str] = []

    for i, pl in enumerate(extras, start=1):
        res.append(NodeResult(i, "disconnected"))
        e = cat[pl.equipment]
        w = wired_at(house, pl, policy.trust_unknown_jacks) if e.wired_backhaul else None
        if w:
            rate, jid, verified = w
            res[i] = NodeResult(i, "wired", None, min(rate, e.port_rate or rate, gw_port, wan), 0, jid)
            paths[i] = []
            done.add(i)
            jacks_used.append(jid)
            if not verified:
                jacks_unverified.append(jid)

    remaining = set(range(1, len(nodes_pl))) - done
    while remaining:
        best = None  # (rate, node, parent, band, shared, hops)
        for n in remaining:
            for m in done:
                if len(paths[m]) + 1 > (cat[nodes_pl[n].equipment].max_hops or 99):
                    continue
                lk = link_rate(ctx, nodes_pl[m], nodes_pl[n], policy, margin)
                if lk is None:
                    continue
                hops = paths[m] + [(nodes_pl[m], nodes_pl[n], lk[0], lk[1])]
                top = _root_rate(res, m, wan)
                r = min(path_rate(ctx, hops), top)
                if best is None or r > best[0]:
                    best = (r, n, m, lk[1], lk[2], hops)
        if best is None:
            break
        r, n, m, band, shared, hops = best
        res[n] = NodeResult(n, "wireless", m, r, len(hops), None, band, shared)
        paths[n] = hops
        done.add(n)
        remaining.discard(n)
    for n in remaining:
        problems.append(f"node {n} cannot reach the gateway")

    # per-cell client rate
    ncell = len(ctx.cells)
    rate = np.zeros(ncell)
    serving = np.full(ncell, -1)
    limited = np.zeros(ncell, dtype=np.int8)
    for i, pl in enumerate(nodes_pl):
        nr = res[i]
        if nr.kind == "disconnected":
            continue
        bh = nr.backhaul_mbps if i else min(wan, gw_port)
        if i and nr.kind == "wired":
            bh = nr.backhaul_mbps
        e = cat[pl.equipment]
        node_best = np.zeros(ncell)
        node_lim = np.zeros(ncell, dtype=np.int8)
        for radio in e.radios:
            if radio.dedicated_backhaul:
                continue
            acc = access_rate(ctx, pl, radio, policy, margin)
            if nr.kind == "wireless" and nr.shared_radio and nr.link_band == radio.band:
                eff = np.where(acc > 0, 1.0 / (1.0 / np.maximum(acc, 1e-9) + 1.0 / bh), 0.0)
            else:
                eff = np.minimum(acc, bh)
            lim = (bh < acc).astype(np.int8)
            better = eff > node_best
            node_best = np.where(better, eff, node_best)
            node_lim = np.where(better, lim, node_lim)
        better = node_best > rate
        rate = np.where(better, node_best, rate)
        serving = np.where(better, i, serving)
        limited = np.where(better, node_lim, limited)
    return Evaluation(problems, res, rate, serving, limited, cost, jacks_used, jacks_unverified)


def _root(res: list[NodeResult], n: int) -> int:
    while res[n].kind == "wireless":
        n = res[n].parent  # type: ignore[assignment]
    return n


def _root_rate(res: list[NodeResult], n: int, wan: float) -> float:
    r = _root(res, n)
    return min(wan, res[r].backhaul_mbps) if res[r].kind == "wired" else wan


# --- zones -----------------------------------------------------------------------

@dataclass
class ZoneScore:
    zone: str
    utility: float  # 0..1, mean over the zone's cells
    utility_margin: float  # the same at the shadowing margin
    mean_rate: float
    frac_target: float  # share of cells reaching the target at the margin
    must_met: bool | None  # None when the zone is not `must`


def zone_scores(ctx: Context, ev: Evaluation, ev_margin: Evaluation, policy: Policy = Policy()) -> list[ZoneScore]:
    out = []
    for z in ctx.house.zones:
        if z.kind != "demand" or z.need is None:
            continue
        m = ctx.zone_mask(z) & ctx.cell_ok
        if not m.any():
            out.append(ZoneScore(z.id, 0.0, 0.0, 0.0, 0.0, False if z.need.must else None))
            continue
        target = z.need.min_throughput or policy.floor_mbps
        floor = min(policy.floor_mbps, target * 0.999)

        def util(r: np.ndarray) -> float:
            return float(np.clip((r[m] - floor) / (target - floor), 0.0, 1.0).mean())

        frac = float((ev_margin.rate[m] >= target).mean())
        out.append(ZoneScore(z.id, util(ev.rate), util(ev_margin.rate), float(ev.rate[m].mean()), frac,
                             (frac >= policy.must_fraction) if z.need.must else None))
    return out
