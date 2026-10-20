"""Storage outside git (design section 8, D15).

    $HOMEMESH_DATA/houses/<id>/house.json          current revision
                              /revisions/<n>.json  history
                              /blobs/<sha256>      content-addressed, immutable

The data directory comes only from HOMEMESH_DATA. There is no default: the app
refuses to start rather than guess a path (it might be inside the checkout).
"""

from __future__ import annotations

import hashlib
import json
import os
import re
from pathlib import Path

from .model import House

ENV = "HOMEMESH_DATA"
_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")


class StoreError(Exception):
    pass


class Conflict(StoreError):
    """The caller saved on top of a stale revision."""


def _repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def data_dir() -> Path:
    raw = os.environ.get(ENV)
    if not raw:
        raise StoreError(f"{ENV} is not set; refusing to pick a data directory")
    p = Path(raw)
    if not p.is_absolute():
        raise StoreError(f"{ENV} must be an absolute path")
    p = p.resolve()
    root = _repo_root()
    if p == root or root in p.parents:
        raise StoreError(f"{ENV} must be outside the repository checkout")
    return p


def _house_dir(house_id: str) -> Path:
    if not _ID.match(house_id):
        raise StoreError("invalid house id")
    return data_dir() / "houses" / house_id


def _write_atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_bytes(data)
    os.replace(tmp, path)


def list_houses() -> list[str]:
    d = data_dir() / "houses"
    return sorted(p.name for p in d.iterdir() if p.is_dir()) if d.is_dir() else []


def load(house_id: str, revision: int | None = None) -> House:
    d = _house_dir(house_id)
    path = d / "house.json" if revision is None else d / "revisions" / f"{revision}.json"
    try:
        raw = path.read_text()
    except FileNotFoundError:
        raise StoreError("no such house or revision") from None
    return House.model_validate_json(raw)


def save(house: House, expect_revision: int | None = None) -> House:
    """Write `house` as the next revision; returns it with `revision` set.

    `expect_revision` is the revision the caller edited from (None for a new
    house). A mismatch raises Conflict. Referential problems raise StoreError.
    """
    problems = house.validate_refs()
    if problems:
        raise StoreError("invalid house: " + "; ".join(problems))
    d = _house_dir(house.id)
    current = None
    if (d / "house.json").exists():
        current = load(house.id).revision
    if expect_revision != current:
        raise Conflict(f"stale revision (have {current}, got {expect_revision})")
    new = house.model_copy(update={"revision": (current or 0) + 1})
    data = (new.model_dump_json(indent=2) + "\n").encode()
    _write_atomic(d / "revisions" / f"{new.revision}.json", data)
    _write_atomic(d / "house.json", data)
    return new


def put_blob(house_id: str, content: bytes) -> str:
    digest = hashlib.sha256(content).hexdigest()
    path = _house_dir(house_id) / "blobs" / digest
    if not path.exists():
        _write_atomic(path, content)
    return digest


def get_blob(house_id: str, digest: str) -> bytes:
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise StoreError("invalid blob id")
    try:
        return (_house_dir(house_id) / "blobs" / digest).read_bytes()
    except FileNotFoundError:
        raise StoreError("no such blob") from None


def export_json(house: House) -> str:
    return json.dumps(json.loads(house.model_dump_json()), indent=2, sort_keys=True) + "\n"
