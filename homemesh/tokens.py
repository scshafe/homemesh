"""Upload tokens for the capture app (design 10.2, 12).

The app cannot do the door's browser login, so it carries a revocable bearer
token that is good for the capture endpoints only (upload a scan). Only a hash
is stored, in the data directory; the token is shown once when created.

    python -m homemesh.tokens create NAME | revoke NAME | list
"""

from __future__ import annotations

import hashlib
import hmac
import json
import re
import secrets
import sys
import time

from . import store

_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,40}$")


def _path():
    return store.data_dir() / "tokens.json"


def _load() -> dict:
    try:
        return json.loads(_path().read_text())
    except FileNotFoundError:
        return {}


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def create(name: str) -> str:
    if not _NAME.match(name):
        raise store.StoreError("invalid token name")
    d = _load()
    if name in d:
        raise store.StoreError("a token with this name exists; revoke it first")
    token = "hm_" + secrets.token_urlsafe(32)
    d[name] = {"hash": _hash(token), "created": int(time.time())}
    p = _path()
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name(p.name + ".tmp")
    tmp.write_text(json.dumps(d, indent=2))
    tmp.chmod(0o600)
    tmp.replace(p)
    return token


def revoke(name: str) -> bool:
    d = _load()
    if name not in d:
        return False
    del d[name]
    _path().write_text(json.dumps(d, indent=2))
    return True


def verify(token: str | None) -> str | None:
    """The token's name when it is valid, else None."""
    if not token or not token.startswith("hm_") or len(token) > 200:
        return None
    h = _hash(token)
    found = None
    for name, rec in _load().items():  # no early exit: constant work per stored token
        if hmac.compare_digest(rec["hash"], h):
            found = name
    return found


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[0] == "create":
        print(create(argv[1]))
        return 0
    if len(argv) == 2 and argv[0] == "revoke":
        print("revoked" if revoke(argv[1]) else "no such token")
        return 0
    if argv == ["list"]:
        for name, rec in _load().items():
            print(name, time.strftime("%Y-%m-%d", time.gmtime(rec["created"])))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
