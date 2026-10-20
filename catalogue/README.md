# Equipment catalogue (public entries)

Real models go here as `*.json`, one file per vendor or product line:

```json
{
  "equipment": [{
    "id": "vendor-model", "name": "Vendor Model", "kind": "mesh_node", "system": "vendor-line",
    "radios": [
      {"band": "5", "chains": 2, "max_width": 80, "tx_dbm": 23, "ant_gain_dbi": 4, "standard": "ax", "assumed": true}
    ],
    "ports": [{"rate": 1000}], "max_nodes": 5, "max_hops": 3, "wired_backhaul": true,
    "price": 0, "sources": ["https://example.com/spec-sheet"]
  }],
  "clients": []
}
```

Rules:

- Public data only, from a spec sheet or a published measurement. Every entry names its `sources`
  (`tests/test_catalogue.py` and the loader reject an entry without one).
- Vendors rarely publish antenna gain or per-band transmit power. A radio whose numbers are not from
  a source says `"assumed": true`; the app shows the flag, and calibration (not this file) is how
  assumptions get tested.
- Price changes often and differs by region: leave it `0` here unless the source dates it.
- The owner's own models, measured figures and prices go in `$HOMEMESH_DATA/catalogue/*.json`
  (same schema, no source required, never in git). They win over this directory on an id clash.
- Generic entries (`generic-*`) are built in and are invented round numbers, not products.
