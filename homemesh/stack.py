"""The floor stack: levels in order from the bottom, elevations derived from that order and the measured heights.

Ground is the first level that is not below ground and sits at 0. Each level above is the one below plus its
height plus the slab between them; each basement is the one above minus the slab minus its own height. A level's
height is the median wall height of the scans on it when it has walls, else what it had.
"""

from __future__ import annotations

import statistics

from .model import House, Level, Slab

SLAB = 0.3


class StackError(ValueError):
    pass


def measured_height(house: House, level_id: str) -> float | None:
    hs = [w.height for w in house.walls if w.level == level_id and w.height > 0]
    return round(statistics.median(hs), 2) if hs else None


def restack(house: House, order: list[str], below_ground: list[str] | None = None, measure: bool = True) -> House:
    """`order` lists every level id, bottom to top; `below_ground` the basements (must be a prefix of the order)."""
    by_id = {lv.id: lv for lv in house.levels}
    if sorted(order) != sorted(by_id) or len(set(order)) != len(order):
        raise StackError("the order must list every level exactly once")
    below = set(below_ground if below_ground is not None else [lv.id for lv in house.levels if lv.below_ground])
    if not below <= set(by_id):
        raise StackError("unknown level in below_ground")
    flags = [i in below for i in order]
    if flags != sorted(flags, reverse=True):
        raise StackError("basements must be the lowest levels in the stack")
    lvls = []
    for i in order:
        lv = by_id[i]
        walls = measured_height(house, i) if measure and lv.height_source != "stair" else None
        lvls.append(lv.model_copy(update={"below_ground": i in below, "height": walls or lv.height,
                                          "height_source": "walls" if walls else lv.height_source}))
    ground = next((n for n, lv in enumerate(lvls) if not lv.below_ground), None)
    if ground is None:
        raise StackError("at least one level must be above ground")
    mat = next((lv.slab.material for lv in lvls if lv.slab), None) or next((m.id for m in house.materials if m.id == "slab-wood"), None) \
        or (house.materials[0].id if house.materials else None)
    elev = [0.0] * len(lvls)
    for n in range(ground + 1, len(lvls)):
        elev[n] = round(elev[n - 1] + lvls[n - 1].height + _slab(lvls[n]), 3)
    for n in range(ground - 1, -1, -1):
        elev[n] = round(elev[n + 1] - _slab(lvls[n + 1]) - lvls[n].height, 3)
    out = []
    for n, lv in enumerate(lvls):
        slab = None if n == 0 else (lv.slab or (Slab(material=mat, thickness=SLAB) if mat else None))
        out.append(lv.model_copy(update={"elevation": elev[n], "slab": slab}))
    return house.model_copy(update={"levels": out})


def _slab(lv: Level) -> float:
    return lv.slab.thickness if lv.slab else SLAB


def with_rise(house: House, level_a: str, level_b: str, rise: float) -> House:
    """A staircase's measured rise is the floor-to-floor distance of the two levels it joins, when they are neighbours
    in the stack: the lower level's height becomes rise minus the slab. Anything else is left as it was."""
    order = [lv.id for lv in house.levels]
    if level_a not in order or level_b not in order or abs(order.index(level_a) - order.index(level_b)) != 1:
        return house
    lo, hi = sorted((level_a, level_b), key=order.index)
    upper = house.levels[order.index(hi)]
    height = round(rise - _slab(upper), 2)
    if not 1.8 <= height <= 6.0:
        return house
    levels = [lv.model_copy(update={"height": height, "height_source": "stair"}) if lv.id == lo else lv for lv in house.levels]
    return restack(house.model_copy(update={"levels": levels}), order, [lv.id for lv in levels if lv.below_ground])
