"""The equipment catalogue (design 2.5, M9): data, layered, validated.

Layers, later wins on an id clash:
  1. generic entries built in (`equipment.generic_catalogue`): invented round numbers, always `assumed`;
  2. `catalogue/*.json` in the repository: public spec-sheet figures, each entry with `sources`;
  3. `$HOMEMESH_DATA/catalogue/*.json`: the owner's own models, measurements and prices (private, never in git).

A file is {"equipment": [...], "clients": [...]} using the `Equipment` / `Client` schemas. Vendors rarely
publish antenna gain or per-band transmit power: a radio whose figures are not from a source says
`"assumed": true`, and the UI shows that. Repository entries must name a source.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

from pydantic import ValidationError

from . import store
from .equipment import Client, Equipment, generic_catalogue, generic_clients

REPO_DIR = Path(__file__).resolve().parent.parent / "catalogue"


class CatalogueError(ValueError):
    pass


@dataclass
class Catalogue:
    equipment: dict[str, Equipment] = field(default_factory=dict)
    clients: dict[str, Client] = field(default_factory=dict)
    origin: dict[str, str] = field(default_factory=dict)  # id -> "generic" | "repo" | "owner"


def _read(path: Path, require_sources: bool) -> tuple[list[Equipment], list[Client]]:
    try:
        raw = json.loads(path.read_text())
        if not isinstance(raw, dict) or set(raw) - {"equipment", "clients"}:
            raise CatalogueError('expected an object with only "equipment" and "clients"')
        eq = [Equipment.model_validate(e) for e in raw.get("equipment", [])]
        cl = [Client.model_validate(c) for c in raw.get("clients", [])]
    except (OSError, ValueError, ValidationError) as e:
        raise CatalogueError(f"{path.name}: {e}") from None
    if require_sources:
        for item in [*eq, *cl]:
            if not item.sources:
                raise CatalogueError(f"{path.name}: {item.id} names no source (public entries must)")
    ids = [i.id for i in [*eq, *cl]]
    if len(ids) != len(set(ids)):
        raise CatalogueError(f"{path.name}: duplicate ids")
    return eq, cl


def load(owner_dir: Path | None = None, repo_dir: Path = REPO_DIR) -> Catalogue:
    cat = Catalogue()
    for i, e in generic_catalogue().items():
        cat.equipment[i], cat.origin[i] = e, "generic"
    for i, c in generic_clients().items():
        cat.clients[i], cat.origin[i] = c, "generic"
    layers = [(repo_dir, True, "repo")]
    if owner_dir is None:
        try:
            owner_dir = store.data_dir() / "catalogue"
        except store.StoreError:
            owner_dir = None
    if owner_dir is not None:
        layers.append((owner_dir, False, "owner"))
    for d, strict, tag in layers:
        for path in sorted(d.glob("*.json")) if d.is_dir() else []:
            eq, cl = _read(path, strict)
            for e in eq:
                cat.equipment[e.id], cat.origin[e.id] = e, tag
            for c in cl:
                cat.clients[c.id], cat.origin[c.id] = c, tag
    return cat


def describe(cat: Catalogue) -> dict:
    return {
        "equipment": [{**e.model_dump(mode="json"), "origin": cat.origin[e.id], "assumed": any(r.assumed for r in e.radios)}
                      for e in cat.equipment.values()],
        "clients": [{**c.model_dump(mode="json"), "origin": cat.origin[c.id]} for c in cat.clients.values()],
    }
