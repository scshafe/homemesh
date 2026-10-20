"""Equipment and client profiles as data (design 2.5).

The catalogue shipped here is GENERIC: invented round numbers that stand for a
class of device, not claims about any product. M9 adds real models from public
spec sheets with sources and `assumed` flags.
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from .model import Band

Standard = Literal["n", "ac", "ax"]


class _Base(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Radio(_Base):
    band: Band
    chains: int = Field(gt=0, le=8)
    max_width: int  # MHz
    tx_dbm: float  # conducted power per the region cap; EIRP = tx_dbm + ant_gain_dbi
    ant_gain_dbi: float
    standard: Standard
    dedicated_backhaul: bool = False  # a radio that carries only the node-to-node link
    assumed: bool = True  # figures not taken from a spec sheet


class Port(_Base):
    rate: float = Field(gt=0)  # Mbit/s


class Equipment(_Base):
    id: str
    name: str
    kind: Literal["router", "mesh_node", "extender"]
    system: str = ""  # mesh system the limits belong to
    radios: list[Radio]
    ports: list[Port] = Field(default_factory=list)
    poe_in: bool = False
    max_nodes: int | None = None  # of the whole system
    max_hops: int | None = None
    wired_backhaul: bool = True
    price: float = Field(default=0.0, ge=0)
    notes: str = ""
    sources: list[str] = Field(default_factory=list)  # where the figures came from (spec sheet URLs, "measured by the owner")

    def radio(self, band: str) -> Radio | None:
        return next((r for r in self.radios if r.band == band and not r.dedicated_backhaul), None)

    def backhaul_radios(self) -> list[Radio]:
        """Radios usable for a wireless uplink: dedicated ones first."""
        return sorted(self.radios, key=lambda r: (not r.dedicated_backhaul, -_BAND_RANK[r.band]))

    @property
    def port_rate(self) -> float:
        return max((p.rate for p in self.ports), default=0.0)


_BAND_RANK = {"2.4": 0, "5": 1, "6": 2}


class Client(_Base):
    id: str
    name: str
    radios: dict[Band, "ClientRadio"]
    noise_figure_db: float = 7.0
    sources: list[str] = Field(default_factory=list)


class ClientRadio(_Base):
    chains: int = Field(gt=0, le=8)
    max_width: int
    standard: Standard
    ant_gain_dbi: float = 0.0


Client.model_rebuild()


def generic_catalogue() -> dict[str, Equipment]:
    ax2 = dict(chains=2, standard="ax")
    items = [
        Equipment(
            id="generic-router-ax", name="Generic dual-band AX router", kind="router",
            radios=[Radio(band="2.4", max_width=20, tx_dbm=20, ant_gain_dbi=3, **ax2),
                    Radio(band="5", max_width=80, tx_dbm=23, ant_gain_dbi=4, **ax2)],
            ports=[Port(rate=1000)] * 4, price=120,
            notes="Invented round numbers for a class of device.",
        ),
        Equipment(
            id="generic-mesh-ax", name="Generic dual-band AX mesh node", kind="mesh_node", system="generic",
            radios=[Radio(band="2.4", max_width=20, tx_dbm=20, ant_gain_dbi=3, **ax2),
                    Radio(band="5", max_width=80, tx_dbm=23, ant_gain_dbi=4, **ax2)],
            ports=[Port(rate=1000)] * 2, max_nodes=6, max_hops=3, price=100,
            notes="Backhaul shares the 5 GHz radio with clients.",
        ),
        Equipment(
            id="generic-mesh-tri", name="Generic tri-band AX mesh node", kind="mesh_node", system="generic-tri",
            radios=[Radio(band="2.4", max_width=20, tx_dbm=20, ant_gain_dbi=3, **ax2),
                    Radio(band="5", max_width=80, tx_dbm=23, ant_gain_dbi=4, **ax2),
                    Radio(band="5", max_width=80, tx_dbm=23, ant_gain_dbi=4, dedicated_backhaul=True, **ax2)],
            ports=[Port(rate=2500), Port(rate=1000)], max_nodes=5, max_hops=3, price=180,
            notes="A dedicated 5 GHz radio carries the node-to-node link.",
        ),
    ]
    return {e.id: e for e in items}


def generic_clients() -> dict[str, Client]:
    items = [
        Client(id="phone-2x2-ax", name="Generic 2x2 AX phone",
               radios={"2.4": ClientRadio(chains=2, max_width=20, standard="ax"),
                       "5": ClientRadio(chains=2, max_width=80, standard="ax")}),
        Client(id="laptop-1x1-ac", name="Generic 1x1 AC laptop",
               radios={"2.4": ClientRadio(chains=1, max_width=20, standard="n"),
                       "5": ClientRadio(chains=1, max_width=80, standard="ac")}),
    ]
    return {c.id: c for c in items}
