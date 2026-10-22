"""Diagnostics from the phone: the app's rolling event log and MetricKit payloads (crashes, hangs), stored so the
owner never has to fetch logs from the device.

    $HOMEMESH_DATA/diagnostics/<device>/<epoch>-<kind>-<sha8>.<json|jsonl>

`kind` is `events` (JSON lines from the app's own log) or `metrickit` (an MXDiagnosticPayload as JSON). The same
content uploaded twice is stored once. Retention: files older than 30 days go, then the oldest until the total is
under 50 MB. Standard library only, so the CLI runs anywhere the data directory is readable:

    python -m homemesh.diagnostics latest-crash [--device D]
    python -m homemesh.diagnostics events [-n 50] [--device D]
    python -m homemesh.diagnostics list
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path

KINDS = {"events": "jsonl", "metrickit": "json"}
MAX_BYTES = 5 * 1024 * 1024
KEEP_SECONDS = 30 * 86400
KEEP_BYTES = 50 * 1024 * 1024
_NAME = re.compile(r"^[A-Za-z0-9._-]{1,64}$")


class DiagnosticsError(ValueError):
    pass


def root() -> Path:
    raw = os.environ.get("HOMEMESH_DATA")
    if not raw:
        raise DiagnosticsError("HOMEMESH_DATA is not set")
    return Path(raw) / "diagnostics"


def _device(name: str) -> str:
    if not _NAME.match(name or "") or name.startswith("."):
        raise DiagnosticsError("device must be 1-64 letters, digits, . _ -")
    return name


def save(device: str, kind: str, raw: bytes, now: float | None = None) -> dict:
    if kind not in KINDS:
        raise DiagnosticsError("kind must be events or metrickit")
    if not raw or len(raw) > MAX_BYTES:
        raise DiagnosticsError("empty or too large")
    if kind == "metrickit":
        try:
            json.loads(raw)
        except ValueError:
            raise DiagnosticsError("metrickit payload is not JSON") from None
    else:
        for line in raw.decode("utf-8", "replace").splitlines():
            if line.strip():
                try:
                    json.loads(line)
                except ValueError:
                    raise DiagnosticsError("events must be JSON lines") from None
    d = root() / _device(device)
    d.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256(raw).hexdigest()[:8]
    existing = [p for p in d.iterdir() if p.name.endswith(f"-{kind}-{digest}.{KINDS[kind]}")]
    if existing:
        return {"name": existing[0].name, "device": device, "stored": False}
    at = int(now if now is not None else time.time())
    path = d / f"{at}-{kind}-{digest}.{KINDS[kind]}"
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_bytes(raw)
    tmp.replace(path)
    prune(now=now)
    return {"name": path.name, "device": device, "stored": True}


def files() -> list[dict]:
    out = []
    base = root()
    if not base.is_dir():
        return out
    for d in sorted(p for p in base.iterdir() if p.is_dir()):
        for p in d.iterdir():
            if p.suffix in (".json", ".jsonl"):
                at, _, rest = p.name.partition("-")
                out.append({"device": d.name, "name": p.name, "at": int(at) if at.isdigit() else 0,
                            "kind": rest.split("-")[0], "size": p.stat().st_size})
    return sorted(out, key=lambda f: (f["at"], f["name"]))


def read(device: str, name: str) -> bytes:
    p = root() / _device(device) / name
    if not _NAME.match(name) or not p.is_file():
        raise DiagnosticsError("no such file")
    return p.read_bytes()


def prune(now: float | None = None) -> int:
    """Delete what is past retention; returns how many files went."""
    t = now if now is not None else time.time()
    fs = files()
    gone = 0
    keep = []
    for f in fs:
        if f["at"] < t - KEEP_SECONDS:
            (root() / f["device"] / f["name"]).unlink(missing_ok=True)
            gone += 1
        else:
            keep.append(f)
    total = sum(f["size"] for f in keep)
    for f in keep[:-1]:  # oldest first; the newest file always stays
        if total <= KEEP_BYTES:
            break
        (root() / f["device"] / f["name"]).unlink(missing_ok=True)
        total -= f["size"]
        gone += 1
    return gone


# --- reading it back (the CLI) ---

def events(n: int = 50, device: str | None = None) -> list[dict]:
    rows = []
    for f in files():
        if f["kind"] != "events" or (device and f["device"] != device):
            continue
        for line in read(f["device"], f["name"]).decode("utf-8", "replace").splitlines():
            try:
                rows.append({**json.loads(line), "_device": f["device"]})
            except ValueError:
                continue
    rows.sort(key=lambda r: r.get("t", 0))
    seen, out = set(), []
    for r in rows:  # uploads overlap; the same event is kept once
        k = json.dumps(r, sort_keys=True)
        if k not in seen:
            seen.add(k)
            out.append(r)
    return out[-n:]


def latest_crash(device: str | None = None) -> dict | None:
    """The newest MetricKit diagnostic payload that has a crash (or, failing that, the newest payload)."""
    best, best_any = None, None
    for f in reversed(files()):
        if f["kind"] != "metrickit" or (device and f["device"] != device):
            continue
        try:
            data = json.loads(read(f["device"], f["name"]))
        except ValueError:
            continue
        best_any = best_any or {"file": f, "payload": data}
        if _has(data, "crashDiagnostics"):
            best = {"file": f, "payload": data}
            break
    return best or best_any


def _has(o, key: str) -> bool:
    if isinstance(o, dict):
        return bool(o.get(key)) or any(_has(v, key) for v in o.values())
    if isinstance(o, list):
        return any(_has(v, key) for v in o)
    return False


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python -m homemesh.diagnostics")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    e = sub.add_parser("events")
    e.add_argument("-n", type=int, default=50)
    e.add_argument("--device")
    c = sub.add_parser("latest-crash")
    c.add_argument("--device")
    a = ap.parse_args(argv)
    try:
        if a.cmd == "list":
            for f in files():
                print(f"{time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(f['at']))}  {f['device']}  {f['kind']:9} {f['size']:>8}  {f['name']}")
        elif a.cmd == "events":
            for r in events(a.n, a.device):
                print(json.dumps(r, sort_keys=True))
        else:
            c_ = latest_crash(a.device)
            if not c_:
                print("no MetricKit payloads stored yet", file=sys.stderr)
                return 1
            print(f"# {c_['file']['device']} {c_['file']['name']}", file=sys.stderr)
            print(json.dumps(c_["payload"], indent=2, sort_keys=True))
    except DiagnosticsError as err:
        print(err, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
