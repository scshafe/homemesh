"""The doors checklist: every scan's doors and openings, whether each says where it leads, and whether the room it leads to
has a door that says it leads back. Placement by connections needs both sides (docs/design-ios-app.md, section 4)."""

from __future__ import annotations


def fold(name: str) -> str:
    return " ".join((name or "").lower().split())


def checklist(metas: list[dict], placed_ids: set[str] | None = None) -> list[dict]:
    """One entry per scan (replaced scans left out): its doors with a `status` of unlabelled, outside, ok or missing, and `issues`
    in words. A door in room R labelled B is `ok` when some door of a scan room named B is labelled R, `missing` otherwise."""
    live = [m for m in metas if m.get("purpose") != "stairs" and m["blob"] not in {(x.get("replaces") or "").partition(":")[0] for x in metas}]
    back: dict[str, set[str]] = {}   # room name -> the names its doors are labelled with
    for m in live:
        rooms = m.get("rooms") or []
        for d in m.get("doors") or []:
            to = (m.get("door_labels") or {}).get(d["id"])
            if to and d["room"] < len(rooms) and fold(rooms[d["room"]]):
                back.setdefault(fold(rooms[d["room"]]), set()).add(fold(to))
    known = set(back) | {fold(n) for m in live for n in (m.get("rooms") or []) if fold(n)}
    out = []
    for m in sorted(live, key=lambda m: m["at"]):
        rooms = m.get("rooms") or []
        labels = m.get("door_labels") or {}
        doors, issues = [], []
        for d in m.get("doors") or []:
            mine = rooms[d["room"]] if d["room"] < len(rooms) else ""
            to = labels.get(d["id"], "")
            if not to:
                status = "unlabelled"
            elif fold(to) == "outside":
                status = "outside"
            elif fold(mine) in back.get(fold(to), set()):
                status = "ok"
            else:
                status = "missing"
                if fold(to) not in known:
                    issues.append(f"{mine or 'A room'} says door {d['number']} leads to {to}, but there is no scanned room called {to}")
                else:
                    issues.append(f"{mine or 'A room'} says door {d['number']} leads to {to}, but {to} has no door labelled {mine or 'this room'}")
            doors.append({**d, "room_name": mine, "label": to, "status": status})
        if any(x["status"] == "unlabelled" for x in doors):
            n = sum(1 for x in doors if x["status"] == "unlabelled")
            issues.append(f"{n} door(s) not labelled yet")
        out.append({"capture": m["blob"], "name": m.get("name", ""), "level": m.get("level"), "rooms": rooms, "doors": doors, "issues": issues,
                    "complete": bool(doors) and not issues})
    return out
