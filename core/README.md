# HomemeshCore

The on-device engine of the standalone homemesh app (`docs/design-standalone-app.md`). A Swift package that depends on Foundation only,
so it builds and tests on Linux and with Xcode.

- `Model.swift`: the house document as the Python model writes it (P0 carries what propagation needs; P1 completes it).
- `Propagation.swift`, `Rates.swift`: ports of `homemesh/propagation.py` and `rates.py`.
- `Layout.swift`: stitching by labelled doorways (spanning tree, least squares, loop residuals, right-angle prior).
- `Snap.swift`, `EditOps.swift`: the editor's snapping, edits, undo and redo.
- `Tests/.../Golden`: vectors written by the Python engine (`scripts/golden`, checked by `tests/test_golden.py`).

```sh
swift test --package-path core                 # debug
swift test --package-path core -c release      # also runs the timing test
```

On the agent's Linux host the toolchain is under `~/swift` (`. ~/swift/env.sh`).
