"""Put the synthetic fixture houses into the data directory (demo / first deploy).

    python -m homemesh.seed

Synthetic houses only; refuses to overwrite a house that already exists.
"""

from . import fixtures, store


def main() -> int:
    for name, fn in fixtures.ALL.items():
        h = fn()
        if h.id in store.list_houses():
            print(f"{h.id}: exists, left alone")
        else:
            store.save(h)
            print(f"{h.id}: saved")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
