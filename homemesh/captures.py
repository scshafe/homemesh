"""Stored scans: the capture JSON (and its USDZ) as blobs, with a small index.

    houses/<id>/blobs/<sha256>            the JSON as uploaded, and the USDZ
    houses/<id>/captures/<sha256>.json    {name, at, counts, usdz, rooms, descriptions, level, replaces, baro, stairs_found, stair, purpose, stories, room_levels}  (derived; rebuildable from the blob)
"""

from __future__ import annotations

import json
import time

from . import store
from .roomplan import ImportError_, _rooms, _surfaces, room_names, stair_footprints

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


def baro_of(data: dict) -> dict | None:
    """The barometer reading the app took at scan start: {session, rel_m, kpa, at}; anything malformed is dropped."""
    b = data.get("baro")
    if not isinstance(b, dict):
        return None
    try:
        return {"session": str(b["session"])[:64], "rel_m": float(b["rel_m"]), "kpa": float(b["kpa"]), "at": float(b["at"])}
    except (KeyError, TypeError, ValueError):
        return None


def stairs_found(data: dict) -> list[dict]:
    """What RoomPlan found of staircases: [{rise, width, run}] (metres)."""
    return [{k: f[k] for k in ("rise", "width", "run")} for f in stair_footprints(data)]


def room_levels_of(data: dict) -> list[str | None] | None:
    """The app's floor for each room when a scan spans stories (`room_levels` in the wrapper), else None."""
    rl = data.get("room_levels")
    n = len(data["rooms"]) if isinstance(data.get("rooms"), list) else 1
    if isinstance(rl, list) and len(rl) == n and all(x is None or isinstance(x, str) for x in rl):
        return [x or None for x in rl]
    return None


def stories_of(data: dict) -> list[int | None]:
    """RoomPlan's `story` of each room."""
    return [r.get("story") if isinstance(r.get("story"), int) else None for r in _rooms(data)]


def save_capture(house_id: str, raw: bytes, name: str = "", level: str = "", replaces: str = "", purpose: str = "",
                 stair: dict | None = None) -> dict:
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
    meta = {"blob": digest, "name": name[:80], "at": int(time.time()), "counts": counts, "usdz": None, "rooms": room_names(data), "level": level or None, "replaces": replaces or None, "baro": baro_of(data),
            "stairs_found": stairs_found(data), "stair": stair or None, "purpose": purpose or None,
            "stories": stories_of(data), "room_levels": room_levels_of(data)}
    path = _dir(house_id) / f"{digest}.json"
    if path.exists():  # the same scan uploaded twice: keep what is known (the USDZ, the name)
        old = json.loads(path.read_text())
        meta.update({"usdz": old.get("usdz"), "name": old.get("name") or meta["name"], "at": old["at"],
                     "rooms": old.get("rooms") if any(old.get("rooms") or []) else meta["rooms"],
                     "level": level or old.get("level"), "replaces": replaces or old.get("replaces"),
                     "baro": meta["baro"] or old.get("baro"), "stair": stair or old.get("stair"),
                     "purpose": purpose or old.get("purpose"),
                     "room_levels": meta["room_levels"] or old.get("room_levels")})
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


def set_room_names(house_id: str, digest: str, names: list[str], descriptions: list[str] | None = None) -> dict:
    """The owner's names (and optionally descriptions) for the capture's rooms, in the order of the capture."""
    meta = get_meta(house_id, digest)
    n = meta["counts"]["rooms"]
    if len(names) != n or (descriptions is not None and len(descriptions) != n):
        raise CaptureError(f"the capture has {n} room(s); give one name{' and one description' if descriptions is not None else ''} for each")
    meta["rooms"] = [str(x).strip()[:80] for x in names]
    if descriptions is not None:
        meta["descriptions"] = [str(x).strip()[:500] for x in descriptions]
    store._write_atomic(_dir(house_id) / f"{digest}.json", json.dumps(meta).encode())
    return meta


def set_level(house_id: str, digest: str, level: str) -> dict:
    meta = get_meta(house_id, digest)
    meta["level"] = level
    meta["room_levels"] = None   # the whole scan is on one floor now
    store._write_atomic(_dir(house_id) / f"{digest}.json", json.dumps(meta).encode())
    return meta


def set_stair(house_id: str, digest: str, stair: dict | None) -> dict:
    """The floors the capture's staircase joins ({from_level, to_level}), or None to clear."""
    meta = get_meta(house_id, digest)
    meta["stair"] = stair
    store._write_atomic(_dir(house_id) / f"{digest}.json", json.dumps(meta).encode())
    return meta


def get_meta(house_id: str, digest: str) -> dict:
    if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
        raise CaptureError("invalid capture id")
    try:
        meta = json.loads((_dir(house_id) / f"{digest}.json").read_text())
    except FileNotFoundError:
        raise CaptureError("no such capture") from None
    return _with_stairs(house_id, meta)


def _with_stairs(house_id: str, meta: dict) -> dict:
    """Captures stored before staircases were summarised get theirs from the stored JSON, once."""
    if "stairs_found" not in meta:
        try:
            meta["stairs_found"] = stairs_found(json.loads(store.get_blob(house_id, meta["blob"])))
        except (ValueError, KeyError, OSError, ImportError_, store.StoreError):
            meta["stairs_found"] = []
        store._write_atomic(_dir(house_id) / f"{meta['blob']}.json", json.dumps(meta).encode())
    return meta


def list_captures(house_id: str) -> list[dict]:
    d = _dir(house_id)
    out = [_with_stairs(house_id, json.loads(p.read_text())) for p in d.glob("*.json")] if d.is_dir() else []
    return sorted(out, key=lambda m: m["at"], reverse=True)


def load_capture(house_id: str, digest: str) -> dict:
    get_meta(house_id, digest)
    return json.loads(store.get_blob(house_id, digest))
