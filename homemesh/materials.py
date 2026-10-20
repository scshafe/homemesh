"""Default material priors (design 3.4).

These are starting points, not facts. Figures are order-of-magnitude losses
from several published vendor and survey tables that disagree with each other
by several dB (no single standards-based table has been checked yet: ITU-R
P.2040 is the candidate), so each carries `source="unsourced"` and a wide
`prior_sd`. Calibration (M7) replaces them with the house's own numbers.
"""

from __future__ import annotations

from .model import Material

_UNSOURCED = "unsourced: spread of vendor/survey tables; see module docstring"


def _m(i: str, name: str, loss: tuple[float, float, float], ref: float, sd: float) -> Material:
    return Material(
        id=i, name=name, loss={"2.4": loss[0], "5": loss[1], "6": loss[2]},
        ref_thickness=ref, prior_sd=sd, source=_UNSOURCED,
    )


def default_materials() -> list[Material]:
    return [
        _m("drywall", "Drywall partition", (3.0, 4.0, 5.0), 0.10, 2.0),
        _m("wood-door", "Wooden door", (3.0, 4.0, 5.0), 0.04, 2.0),
        _m("glass", "Plain glass", (2.0, 3.0, 4.0), 0.01, 2.0),
        _m("brick", "Brick", (7.0, 9.0, 11.0), 0.20, 3.0),
        _m("concrete", "Poured concrete", (12.0, 17.0, 20.0), 0.20, 5.0),
        _m("slab-wood", "Wood joist floor", (9.0, 12.0, 14.0), 0.30, 4.0),
        _m("slab-concrete", "Concrete floor slab", (15.0, 20.0, 24.0), 0.20, 6.0),
    ]
