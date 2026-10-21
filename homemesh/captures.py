"""Stored scans: the capture JSON (and its USDZ) as blobs, with a small index.

    houses/<id>/blobs/<sha256>            the JSON as uploaded, and the USDZ
    houses/<id>/captures/<sha256>.json    {name, at, counts, usdz, rooms}  (derived; rebuildable from the blob)
"""

from __future__ import annotations

import json
import time

from . import store
from .roomplan import ImportError_, _rooms, _surfaces, room_names

MAX_JSON = 30 * 1024 * 1024
MAX_USDZ = 200 * 1024 * 1024


class CaptureError(ValueError):
    pass


def _dir(house_id: str):
    return store._house_dir(house_id) / "captures"


def summarise(data: dict) -> dict:
    counts = {"rooms": 0, "walls": 0, "doors": 0, "windows": 0, "openings": 0}
    try:
        rooms = _rooms(data)
        counts["rooms"] = len(rooms)
        for r in rooms:
            for s in _surfaces(r):
                counts[s.kind + "s"] = counts.get(s.kind + "s", 0) + 1
    except ImportError_ as e:
        raise CaptureError(str(e)) from None
    if not counts["walls"]:
        raise CaptureError("the capture has no walls")
    return counts


def save_capture(house_id: str, raw: bytes, name: str = "") -> dict:
    if len(raw) > MAX_JSON:
        raise CaptureError("capture too large")
    try:
        data = json.loads(raw)
    except ValueError:
        raise CaptureError("not JSON") from None
    if not isinstance(data, dict):
        raise CaptureError("not a capture")
    counts = summarise(data)
    digest = store.put_blob(house_id, raw)
    meta = {"blob": digest, "name": name[:80], "at": int(time.time()), "counts": counts, "usdz": None, "rooms": room_names(data)}
    path = _dir(house_id) / f"{digest}.json"
    if path.exists():  # the same scan uploaded twice: keep what is known (the USDZ, the name)
        old = json.loads(path.read_text())
        meta.update({"usdz": old.get("usdz"), "name": old.get("name") or meta["name"], "at": old["at"],
                     "rooms": old.get("rooms") if any(old.get("rooms") or []) else meta["rooms"]})
    store._write_atomic(path, json.dumps(meta).encode())
    return meta


def attach_usdz(house_id: str, digest: str, raw: bytes) -> dict:
    meta = get_meta(house_id, digest)
    if len(raw) > MAX_USDZ:
        raise CaptureError("USDZ too large")
    if raw[:2] != b"PK":
        raise CaptureError("not a USDZ (zip) file")
    meta["usdz"] = store.put_blob(house_id, raw)
    store._write_atomic(_dir(house_id) / f"{digest}.json", json.dumps(meta).encode())
    return meta


def set_room_names(house_id: str, digest: str, names: list[str]) -> dict:
    """The owner's names for the capture's rooms, in the order of the capture (one per room)."""
    meta = get_meta(house_id, digest)
    if len(names) != meta["counts"]["rooms"]:
        raise CaptureError(f"the capture has {meta['counts']['rooms']} room(s), got {len(names)} name(s)")
    meta["rooms"] = [str(n).strip()[:80] for n in names]
    store._write_atomic(_dir(house_id) / f"{digest}.json", json.dumps(meta).encode())
    return meta


def get_meta(house_id: str, digest: str) -> dict:
    if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
        raise CaptureError("invalid capture id")
    try:
        return json.loads((_dir(house_id) / f"{digest}.json").read_text())
    except FileNotFoundError:
        raise CaptureError("no such capture") from None


def list_captures(house_id: str) -> list[dict]:
    d = _dir(house_id)
    out = [json.loads(p.read_text()) for p in d.glob("*.json")] if d.is_dir() else []
    return sorted(out, key=lambda m: m["at"], reverse=True)


def load_capture(house_id: str, digest: str) -> dict:
    get_meta(house_id, digest)
    return json.loads(store.get_blob(house_id, digest))
