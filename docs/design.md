# homemesh: design

Status: **proposed**. This is the designer's first PR. The owner accepts it
(or changes it) before anything past the skeleton is built.
[`brief.md`](brief.md) is the owner's request and is fixed; this document
answers it. Every choice the owner has to make is collected in
[Owner decisions](#owner-decisions); where the text says "recommended" it
means the recommendation listed there, not a decision.

Privacy rule that shapes everything below: **house data never enters git, an
issue, a CI log or a fixture.** Blueprints, photos, video, scans, RoomPlan
exports and the model of a real house live in a data directory outside the
repository. Every fixture in the repository is a synthetic house. Hostnames of
the tailnet are never written in this repository; `<tailnet>` stands for it.

## 1. What the tool is for

Given a model of a house, the fixed network facts (internet entry, ethernet
jacks), the places where a node may go, and the places where coverage
matters, answer: *which arrangement of routers/extenders/mesh nodes gives the
best result, and why?* Three engines do this, in order:

1. **Propagation**: path loss from any point where a radio could sit to any
   point where a client could be, per band.
2. **Backhaul**: how each node reaches the internet (wire or air) and what
   rate that leaves for its clients.
3. **Planner**: searches the arrangements the rules allow, ranks them,
   explains the ranking.

Everything is a deterministic function of the house model, the equipment
catalogue and the calibration parameters. The same inputs give the same
ranking; every number can be traced to a stated assumption.

Non-goals (stated so nobody builds them by accident): a real-time Wi-Fi
analyser, channel-level RF planning to the quality of a commercial site
survey tool, controlling real routers, multi-tenant hosting, anything that
leaves the tailnet.

## 2. Data model

### 2.1 Conventions

- **Units:** metres, decibels, dBm, Mbit/s internally and in files. The UI may
  display feet (decision D3). Angles in degrees in files.
- **Frame:** one right-handed frame per house, **+Z up**, +X and +Y in the
  plan. The origin is a stated survey point (a corner of the ground floor).
  Floors are stacked in this one frame by `elevation` (Z of the top of the
  finished floor). No per-floor frames: stacking is what makes floor loss
  computable.
- **Ids:** short stable strings (`w-12`, `j-3`), unique within a house.
- **Schema:** a single versioned schema (`schema_version` integer) defined as
  Python types (pydantic) in the backend; the JSON Schema and the TypeScript
  types for the front end are generated from it, so there is one source of
  truth. A migration function per version bump.

### 2.2 Provenance on every element

Every element carries:

```json
"prov": {
  "source": "scan | blueprint | photo | manual",
  "ref": "capture-2026-10-21-a#wall/7",
  "confidence": 0.8,
  "edited": false,
  "at": "2026-10-21T10:00:00Z"
}
```

`source` is the brief's four values. `ref` points into the data directory
(a blob hash or an import id), never to a path outside it. An element a human
changed after import keeps its original `source` and gets `edited: true`; a
brand-new element is `manual`. Confidence is advisory (RoomPlan reports a
confidence per surface; elsewhere it is a default) and is shown in the UI,
never silently used by the simulator.

### 2.3 Entities

| Entity | Fields (abridged) | Notes |
|---|---|---|
| `House` | `id`, `name`, `schema_version`, `region`, `levels[]`, `materials[]`, `entry`, `jacks[]`, `outlets[]`, `zones[]`, `measurements[]` | One JSON document per house (see section 8). `region` is the regulatory domain (D13). |
| `Level` | `id`, `name`, `elevation`, `height`, `slab` | A floor. `slab` = `{material, thickness}`: the structure *below* this level's floor (between it and the level under it). The lowest level's slab is the ground and is ignored by propagation. |
| `Room` | `id`, `level`, `name`, `polygon[]` (2D, CCW), `kind` | Derived data for display and zone defaults; the walls, not the rooms, drive propagation. |
| `Wall` | `id`, `level`, `a`, `b` (2D endpoints), `thickness`, `height`, `base_z`, `material`, `openings[]` | A straight prism: the segment `a-b` thickened, extruded from `base_z`. Curved walls are polylines of short walls. Exterior/interior is a derived flag. |
| `Opening` | `kind` (door, window, arch, hole), `offset`, `width`, `height`, `sill`, `material` | Lives on a wall. Material is its own (a closed wooden door, a double-glazed window, an empty arch = `air`). A `state` (`open`/`closed`) lets doors be simulated both ways. |
| `Stair` | `id`, `from_level`, `to_level`, `polygon[]`, `void` | A stairwell is a *hole in the slab* of the upper level: rays through it pay no slab loss. |
| `SlabHole` | `level`, `polygon[]` | Stairwells, atria, open stairs. |
| `Material` | `id`, `name`, `loss[band]`, `ref_thickness`, `source` | Attenuation in dB at a reference thickness, per band (2.4, 5, 6 GHz), with a `prior_sd`. See 3.4. Houses carry their own copy so calibration edits stay with the house. |
| `Entry` | `position`, `level`, `kind` (modem, ONT, coax drop), `wan_down`, `wan_up`, `leads_to` | The internet entry point. WAN rates cap everything downstream. |
| `Jack` | `id`, `position`, `level`, `wall?`, `type`, `state`, `leads_to`, `poe`, `measured_rate?` | `type`: `cat5e`, `cat6`, `cat6a`, `coax_moca`. `state`: `live`, `dead`, `unknown`. `leads_to`: free text plus an optional structured `switch` id (patch panel, switch, the router, another jack, "unknown"). `poe`: whether the far end can supply PoE. |
| `Switch` | `id`, `position`, `ports`, `port_rate` | Optional. Gives the wired network a topology: a jack is usable for backhaul only if the wired graph connects it to the gateway. |
| `Outlet` | `id`, `position`, `level`, `height`, `circuit?` | Only where power matters: a node needs an outlet within reach of its spot, or PoE. |
| `Zone` | `id`, `level`, `polygon[]`, `z_min`, `z_max`, `kind`, `weight`, `need` | See 2.4. |
| `Underlay` | `id`, `level`, `blob`, `width_px`, `height_px`, `scale` (m/px), `rotation`, `origin`, `opacity`, `scaled` | A blueprint page under one level's plan (section 11). The blob is a PNG re-encoded on upload, so no EXIF/GPS survives. Walls traced over it carry `prov.source = blueprint` and `ref = blob`. |
| `Measurement` | `id`, `position`, `level`, `device`, `band`, `bssid?`, `rssi?`, `snr?`, `throughput?`, `at` | Calibration input, section 7. Private data; lives in the data directory like the rest of the house. |
| `Equipment` | catalogue item, see 2.5 | Not part of a house; a shared catalogue. |
| `Arrangement` | `nodes[]` of `{equipment, spot, mount_height, backhaul: auto | wired(jack) | wireless(parent)}` | The planner's output and a user's hand-built what-if; stored with the house. |

### 2.4 The owner's rules are zones

All placement and coverage rules are one entity, `Zone`, with a `kind`:

- `allow`: a node may be placed inside (a room, a shelf, a ceiling strip).
  Optional `requires: outlet | poe | none` and `mount: [floor, shelf,
  ceiling, wall]` with allowed heights.
- `forbid`: no node here, overriding any `allow` it overlaps.
- `demand`: coverage matters here. `weight` (relative importance) and `need`
  = `{min_rssi?, min_throughput, max_latency?, band_pref?}`. The office needs
  300 Mbit/s with low latency, the garage only needs something.

A point is a candidate spot if it is in an `allow` zone, outside every
`forbid` zone, and meets the zone's power requirement. Zones also accept
single points (an allowed spot is a zone with a tiny polygon). Latency is
recorded and shown but is **not simulated in v1**: we do not model it;
`max_latency` is used only to prefer wired-backhaul/low-hop arrangements
(hop count as proxy). That is an honest limitation (see section 9).

### 2.5 Equipment

Data, not code. One entry per model, versioned in a catalogue file in the
repository (public spec-sheet figures only; no house data).

```json
{ "id": "example-tri-band-ax", "kind": "mesh_node", "system": "example",
  "radios": [
    {"band": "2.4", "chains": 2, "max_width": 20, "tx_dbm": 20, "ant_gain_dbi": 3, "standard": "ax"},
    {"band": "5",   "chains": 2, "max_width": 80, "tx_dbm": 23, "ant_gain_dbi": 4, "standard": "ax", "dedicated_backhaul": false},
    {"band": "5b",  "chains": 4, "max_width": 160, "tx_dbm": 23, "ant_gain_dbi": 4, "standard": "ax", "dedicated_backhaul": true}
  ],
  "ports": [{"rate": 2500, "role": "wan_lan"}, {"rate": 1000, "role": "lan"}],
  "poe_in": false, "max_nodes": 5, "max_hops": 3, "price": 150.0, "notes": "..." }
```

The numbers above are placeholders for the schema only. Transmit power is
legally limited per region and channel; vendors often do not publish antenna
gain. The catalogue records what is *published or measured* and flags what
is assumed (D12). A "mesh system" groups models with shared limits
(`max_nodes`, `max_hops`, whether wired backhaul is supported, whether a
dedicated backhaul radio exists). Client devices are catalogued the same way
(`phone-2x2-ax`, `laptop-1x1-ac`): chains, bands, max width, antenna
gain, and a receive-sensitivity offset.

### 2.6 Fixtures

`tests/fixtures/` holds *synthetic* houses only, generated by code or small
hand-written JSON: a one-floor box, a two-floor house with a stairwell, a
long thin house (the case where wireless hops lose), a house with a wired
jack at each end. Each fixture has a header `"synthetic": true`, and a verify
check (M1) fails on any fixture without it, and on any file in the tree with
a forbidden extension (the `.gitignore` list) or larger than a small limit
outside an allowlist. A synthetic fixture is not a simplified copy of the
owner's house; it is invented.

## 3. Propagation model

### 3.1 The choice

**Start with a multi-wall-and-floor model, with the walls counted from real
geometry (COST 231 multi-wall style), per band, calibrated. No ray tracing in
v1.**

The form, for a transmitter at `t` and a receiver at `r`, distance `d`
metres, frequency `f`:

```
PL(dB) = PL0(f) + 10 n log10(d) + Σ_walls L_w(m, f, θ) + Σ_slabs L_s(m, f)
PL0(f) = 20 log10(f_MHz) - 27.56        # free space at 1 m
RSSI   = P_tx + G_tx + G_rx - PL
```

- `Σ_walls`: every wall prism (and opening) the 3D segment `t -> r` crosses,
  each costing the loss of its material.
- `Σ_slabs`: every floor slab the segment crosses (outside slab holes), each
  costing the slab material's loss.
- `n`: the residual distance exponent. With walls counted explicitly it is
  near free space (~2.0) and is a calibration parameter per band.

### 3.2 Why this and not the alternatives

| Candidate | Verdict |
|---|---|
| **COST 231 multi-wall (MWM)** | **Chosen as the structure.** It is the standard answer when you know the walls: loss grows with the *specific* walls between two points, which is exactly what the model of the house provides. Fast (a segment-vs-prism test per wall), explainable ("this room loses 9 dB to the brick wall and 12 dB to the floor"), and every term can be calibrated. Its original floor term is non-linear in the number of floors (`k_f^{((k_f+2)/(k_f+1) - b)} L_f`); we keep that as an option (3.5) rather than the default because we have explicit slab geometry. |
| **ITU-R P.1238 (site-general indoor)** | **Kept as a baseline, not the engine.** It is `20 log f + N log d + L_floor(n) - 28` with tabulated coefficients per environment and band (check the current edition for the tables). It has no walls: it assumes the environment's average clutter. Useful for (a) a sanity check against the MWM result, and (b) a fallback when a house has no geometry yet. Not usable for "which wall is the problem". |
| Log-distance with one wall factor | Rejected. Throws away the data the owner gave us. |
| **Ray tracing / image method** | **Deferred, behind a stated gate (3.6).** It models reflection and diffraction (doorways, corridors, multipath), at the cost of needing accurate geometry and accurate complex permittivity for every material, far more compute, and parameters that cannot be calibrated from a phone walk. With RoomPlan geometry (walls without thickness, unknown materials) its accuracy would be bounded by inputs, not by the method. |
| ML / learned from measurements | Rejected for v1: a single house yields too few measurements, and it would not generalise to arrangements never measured. Calibration (section 7) is the right use of the measurements. |

### 3.3 Geometry handling

- The model is queried at **receiver height** (default 1.0 m above the floor;
  a parameter per `demand` zone: desk 0.75, standing phone 1.2) on a regular
  **grid** per level (default 0.5 m, 0.25 m when displaying a close-up).
  Cells outside the house or inside a wall prism are masked.
- A transmitter is at its mount height above the floor of its level.
- For each (transmitter, cell), count crossings of the 3D segment with wall
  prisms. Wall loss is applied once per wall prism, not per face, and is
  scaled for incidence: effective thickness `t / max(cos θ, cos 70°)`, so a
  grazing ray along a wall does not pay for an infinite wall, and is capped.
  A ray inside the opening's rectangle (door, window, arch) pays the opening's
  material, not the wall's. This is where doors matter: an open doorway is an
  `air` opening.
- Slab crossings: the segment crosses the plane of each level boundary
  between them; if the crossing point lies inside a `SlabHole` it costs
  nothing, else the slab's loss.
- Cost: with ~100 walls per floor, ~5k cells, ~300 candidate positions, that
  is ~1.5·10^8 segment tests: seconds in vectorised numpy with a 2D spatial
  grid to cull walls, no GPU needed. Results are cached per
  (house revision, candidate, band, rx height). The GPU on the PC is not a
  dependency of the simulation.

### 3.4 Material losses

Each material has a loss per band at a reference thickness, and a prior
standard deviation. **These start as literature priors with wide ranges, not as
facts**: order of magnitude for interior drywall 2-5 dB, wooden door 3-5 dB,
glass 2-5 dB, brick 5-10 dB, poured concrete 10-20 dB, a floor slab 8-20 dB
(wood joist low, concrete high), metal-backed insulation or foil far more,
all rising with frequency. In M2 each default is given a citation in the
catalogue and the figures are checked against sources before use; until then
they are marked `unsourced`. Thickness scaling is linear in thickness over the
reference thickness (dB/cm). Unknown material = the owner's chosen default
for that wall class (interior/exterior), shown as such in the UI so the
estimate's weak spots are visible.

### 3.5 From path loss to a rate

1. **Signal.** RSSI as above; the client's gain and the node's gain enter via
   the catalogue. Report **median** RSSI; real signals fade, so the planner
   carries a shadowing margin (3.7) rather than pretending precision.
2. **Noise and SNR.** Thermal noise `-174 dBm/Hz + 10 log10(BW) + NF`
   (default NF 6-8 dB at the client). SNR = RSSI - noise floor. Interference:
   v1 includes *self-interference only*: a co-channel node of the same
   arrangement raises the floor by its received power times an activity factor.
   The planner assigns channels from a simple per-band reuse plan (2.4 GHz:
   1/6/11; 5 GHz: non-overlapping 80 MHz; 6 GHz: 160 MHz where allowed by
   `region`). Neighbours' networks are *not* modelled; the owner can add a
   background noise-floor offset per band if a measurement shows one.
3. **Rate.** SNR maps through a table of minimum SNR per MCS for the
   standard (n/ac/ax), channel width and number of spatial streams, giving a
   PHY rate; throughput = PHY rate x a MAC efficiency (default 0.6, a
   calibration parameter). The table lives in the data catalogue with its
   source.
4. **Which band.** A client uses the band with the best throughput among
   those it supports (a band-steering assumption that is stated, with
   2.4 GHz as the floor). Per cell the map stores per-band RSSI, SNR, rate, and
   the best.

What "throughput" means in the result: *single-client downlink to an
otherwise idle network*. Airtime sharing between simultaneous clients is not
in v1 (the planner may later weigh zones by expected client count).

### 3.6 Gate for ray tracing

Ray tracing earns its place only if, **after calibration on real
measurements** (section 7):

- the MWM residual error is too large to rank arrangements (rule of thumb:
  RMSE above ~6 dB on held-out locations, or ranking flips inside the
  calibrated uncertainty), **and**
- the errors are structured in a way ray effects explain (doorway/corridor
  focusing, 6 GHz behaviour, metal), **and**
- the geometry is good enough to support it (a scan, not a rough trace).

If the gate opens, the first step is a 2D-plus-floors image-method add-on
(LOS, one reflection, door/window diffraction) used as a correction term,
not a replacement. Third-party RT frameworks need checking against the PC's
ROCm GPU before they are counted on (some target CUDA only; verify when the
gate opens). Decision D5 records the owner's agreement with this gate.

### 3.7 Uncertainty

Coverage numbers are shown with a margin. The planner evaluates each
arrangement at the median **and** with a shadowing/uncertainty margin
(default 6 dB in uncalibrated houses, replaced by the calibrated residual SD
after M7). A rank that survives the margin is reported "stable"; one that
does not is reported "within the model's error". The assumptions list (every
parameter, its value, whether prior or calibrated) is generated and shown
with every result. This is the brief's "the model is stated, with its
assumptions".

## 4. Backhaul model

### 4.1 Graph

Nodes: the **gateway** (the router at the `Entry`, or an arrangement node
wired to it), the **mesh nodes**, and the **wired fabric** (switches, jacks).
Edges are of two kinds:

**Wired edge.** A mesh node placed at (or cabled to) a live jack whose
`leads_to` chain reaches the gateway's LAN through the `Switch`/jack graph.
Rate = min of: the jack type's capability, the node's port, the far port, the
upstream link. Defaults, subject to D9: `cat5e` 1 Gbit/s (2.5 possible but
unreliable; stated), `cat6` 1-2.5 Gbit/s, `cat6a` up to 10 Gbit/s (length
limits noted; run length is an optional field), `coax_moca` a configurable
MoCA adapter rate (usually well under its nameplate). A `measured_rate` on the
jack overrides the table. `state: unknown` jacks are treated as dead in a
"safe" plan and live in an "if it works" plan; the report says which jacks an
arrangement depends on, so the owner knows what to test first. Wired edges
have latency and rate that do not depend on position beyond the jack.

**Wireless edge.** Node-to-node link rate from the same propagation engine,
between the child's backhaul radio and the parent's radio, at the nodes'
actual mount heights, using the band chosen for backhaul. For a
*dedicated* backhaul radio the link has its own channel; for a *shared* radio
(the same radio serves clients and backhaul) airtime is shared.

### 4.2 End-to-end rate

Each node picks the parent that maximises its end-to-end rate to the
gateway (a tree; real mesh systems steer differently and proprietarily, which
is an assumption the report states). For a path of wireless hops that share
a collision domain (same band, same channel, within carrier-sense range),
the achievable rate is the harmonic sum

```
R_path = 1 / Σ_i (1 / r_i)
```

and hops on separate radios/channels or beyond mutual range contribute as
`min`. A wired uplink makes the node a new root for its subtree at its wired
rate, capped by the gateway's WAN rate. A system's `max_hops` and `max_nodes`
are hard constraints. A node count or hop limit violation makes the
arrangement invalid, not merely poor.

### 4.3 Client rate

A client associates with the node giving the best end-to-end rate (not
simply strongest RSSI, with a note when a real device would choose the
strongest and get less). The client's rate is

```
min( access_rate(client, node, band), R_backhaul(node) x share )
```

where `share` is the fraction of the node's backhaul airtime left to
clients: 1.0 on a wired or dedicated-backhaul node, otherwise the
harmonic-sum result already includes the shared radio. Everything above the
access is capped by the WAN rate at the entry.

### 4.4 Not modelled (v1)

Roaming behaviour and handoff time, per-vendor steering, DFS/radar
channel moves, MU-MIMO gains, multi-link operation (Wi-Fi 7), real traffic
mix, powerline adapters. They are listed in the report as out of scope so a
reader knows what the numbers do not say.

## 5. Planner

### 5.1 Search space

- **Candidate spots:** the allowed region (2.4) sampled on a grid (default
  0.5 m) at each allowed mount height, filtered by power requirement and
  `forbid`. The owner may instead list discrete spots (then there is no
  grid). A typical house yields a few hundred candidates; merging
  near-duplicates (same room, similar coverage signature) prunes to ~50-100
  *representatives* for the exhaustive step, which are expanded back to full
  grid positions afterwards.
- **Choices per node:** a spot, an equipment model from the catalogue (or a
  shortlist the owner gave), and a backhaul assignment (auto: best of wired
  jack at that spot, or wireless).
- **Budget:** `k` nodes up to `K_max` (owner's setting, typically 1-5), an
  optional price ceiling.

### 5.2 Precomputation makes search cheap

For each candidate and band the propagation engine produces one RSSI map
(cells x bands). For each ordered candidate pair it produces one link rate
(the wireless-backhaul candidate edges). That is `C` maps and `C^2` scalars,
about 300 x 5k x 3 floats plus 90k pair values: megabytes, seconds to
compute. Evaluating an arrangement then needs no new propagation: take the
per-cell best over its nodes, resolve backhaul on the small graph, score. One
evaluation costs milliseconds.

### 5.3 Search method

Staged, because the arrangement score is not a clean linear function (the
backhaul makes it non-linear):

1. **Exhaustive** over the pruned representatives for `k <= 3`
   (C(80,3) = 82k evaluations: well within a minute).
2. **Greedy with swap refinement** for larger `k`: add the node with the best
   marginal gain, then repeatedly try replacing each node by a better
   candidate until no swap helps. For a pure thresholded-coverage objective,
   greedy has the usual `1 - 1/e` guarantee; with backhaul included it is a
   heuristic, and the report says so.
3. **ILP / CP-SAT (OR-Tools) as a check, later.** A set-cover formulation
   (cell covered if any chosen candidate gives >= the zone need, minimise
   cost/nodes subject to coverage) gives a provable bound on the best
   coverage-only arrangement; we use it to tell the owner how far the
   heuristic result is from optimal. It is not the primary engine because
   wireless backhaul and shared airtime do not linearise cleanly. Recommended
   to add in M6, not before (D7).

### 5.4 Ranking

Each arrangement gets a vector, not just a number:

- **Coverage score** `S = Σ_z w_z * u_z`, where `u_z in [0,1]` is the zone's
  area-weighted utility: a saturating function of the cell's rate against the
  zone's `need` (0 below the floor, 1 at or above the target, linear between;
  the shape is a decision, D6).
- **Worst-zone score** `min_z u_z`: the arrangement must not sacrifice the
  office for the hallway.
- **Hard constraints:** `need.min_throughput` flagged `must` zones must be
  met at the margin (3.7); mesh-system limits; the dependency on `unknown`
  jacks (reported, not hidden).
- **Cost** (sum of prices) and **node count**.
- **Robustness**: whether the rank holds under the uncertainty margin.

The default view is a **Pareto front** over (coverage score, worst-zone
score, cost): the arrangements no other arrangement beats on all three,
presented per node count. A scalar ranking with the owner's weights is a
second view of the same data, never the only one: a single hidden weighted
sum would make the "winner" an artefact of weights nobody examined.

### 5.5 Explaining

The explanation is generated from the numbers, deterministically (no
language model in the loop, so it cannot invent a reason):

- Per zone: achieved rate vs need, and the **limiting factor** from a fixed
  list: access SNR on band X; wall/floor loss dominated by material M
  (largest term of the path-loss sum); backhaul hop; WAN cap; mesh limit.
- Per node: **leave-one-out contribution**: how much the score drops if that
  node is removed (and, for wireless nodes, which backhaul hop is weakest).
- **Versus the runner-up**: the zones where it wins, the zones where it loses,
  the cost difference.
- **Sensitivity**: rank stability when each material's loss moves within
  its (calibrated) uncertainty (a small Monte Carlo over the parameters), and
  the jacks the result depends on.
- Plain text plus the data behind it; it never asserts something the numbers
  do not show.

### 5.6 Comparison UI

Side by side (2-4 arrangements): heat map per floor (best-band rate or RSSI,
toggled per band), the table of scores/cost/limits, node positions with their
backhaul (wire or air) drawn on the 3D model, and a diff view (cells where A
beats B by more than the margin).

## 6. Stack

```
 browser (Mac, phone, PC)         PC (runner lane, tailnet only)          outside git
 ┌──────────────────────┐        ┌───────────────────────────┐          ┌──────────────┐
 │ TypeScript + three.js│ HTTPS  │ door (access gate)        │          │ data dir     │
 │ 3D view, 2D editor,  ├───────►│  └ FastAPI (Python)       │ reads/   │ houses/…     │
 │ heat maps, compare   │        │      model, sim, planner  ├─writes──►│ blobs/…      │
 └──────────────────────┘        │      importers, jobs      │          │ index.sqlite │
 iOS capture app ── upload ─────►│                           │          └──────────────┘
                                 └───────────────────────────┘
```

- **Backend:** Python 3.12+, FastAPI, pydantic (the schema), numpy/scipy
  for the simulation, Shapely for 2D geometry, OR-Tools later. Heavy work
  (a plan, a calibration fit, an import) runs as a **job** with progress,
  in a worker process, so the UI never blocks. No database server.
- **Front end:** TypeScript, three.js, Vite, and a small UI layer (Preact
  recommended: tiny, no build surprises; D4). It renders the model (walls
  from extruded footprints, slabs, jacks, nodes), a 2D top-down editor per
  level (the main editing surface: tracing is far easier in 2D than in 3D),
  and heat maps as textured planes per level, coloured on the client from a
  compact float grid sent by the server. Orbit/walk controls; works on a
  phone for viewing, with editing designed for a desktop/tablet.
- **API:** JSON for documents, binary for grids and meshes. One document
  per house is edited with optimistic concurrency (revision number); every
  save writes a new revision.
- **GPU:** not needed by anything in M1-M7. The RX 6900 XT (ROCm) is for
  later reconstruction from photos/video and possibly ray tracing; tying the
  deployment to it before then would only add failure modes.
- **Tests and CI:** the existing standard-library `unittest` verify stays
  the entry point; heavier dependencies come with a lock file in M1 and the
  `scripts/verify` update that goes with them. CI (public repo) runs it on a
  GitHub-hosted runner.

## 7. Calibration from measurements

### 7.1 What is measured

The owner walks the house with a device and records readings at known
positions: **RSSI, BSSID (which node), band, channel**, and optionally a
throughput test (iperf3 or a speed test against a LAN server). The unknown
parameters: `n` per band, the loss of each material per band, the floor loss
per band, and an offset (the unknown transmit power/antenna gain of the
existing router and the client's antenna).

The tool must be told where the *existing* router is, and its band/channel;
calibration uses the house as it is now. The same fitted materials then
predict every other arrangement.

### 7.2 Getting readings (platform reality)

This is the main practical constraint, and it is the owner's choice (D8):

- **iPhone:** iOS gives apps almost nothing: no Wi-Fi scan, and for the
  connected network a normalised 0-1 signal strength (via
  `NEHotspotNetwork`, which needs an entitlement); the old Airport utility
  mode is gone. An iPhone is therefore usable for position and for
  *throughput* tests, but weak for dBm. (Verify the current API at M7.)
- **Mac:** CoreWLAN gives RSSI, noise, BSSID, channel and tx rate for the
  connected network; a laptop walk is a good dBm source. The Mac needs the
  position from the owner tapping the plan.
- **Android phone / a cheap Android loaner:** full scan results with RSSI per
  BSSID; the best dBm source if the owner has one or borrows one.
- The capture app (section 10) can additionally log ARKit position with each
  reading, so the position is not typed by hand. A Mac/Android reading with a
  tap-to-place position is enough to start.

Import format: a CSV/JSON (`position` or `tap`, `device`, `band`, `bssid`,
`rssi`, `snr`, `throughput`, `time`), validated, stored in the data
directory.

### 7.3 Fit

Regularised, robust least squares: minimise
`Σ ρ((RSSI_obs - RSSI_model)/σ) + Σ ((θ - θ_prior)/σ_prior)²` with `ρ` Huber,
parameters bounded to physical ranges, `θ_prior` the literature value.
Consequences:

- A material crossed by too few measurements stays at its prior with its
  prior uncertainty (the tool says "not identified"), instead of fitting noise.
- **Cross-validation by area** (hold out a room or a path, not random
  points) gives the honest error; that held-out RMSE is the number shown and
  the one the ray-tracing gate (3.6) uses.
- The posterior (Laplace approximation or bootstrap) provides the parameter
  covariance that feeds the planner's sensitivity analysis (5.5).
- Suggested walk: a path through each room, one reading on each side of each
  wall type you care about, one per floor above and below the router.
  The tool shows which materials are poorly identified and suggests where to
  measure next.
- Throughput readings calibrate the MAC efficiency and the MCS mapping
  separately from the path loss.

### 7.4 As built (M7)

- The existing access point is an `AccessPoint` in the house (position, height,
  EIRP, BSSIDs); a reading belongs to it by BSSID, or by default when it is the
  only one. Its EIRP error is absorbed by the fitted `extra loss`.
- Readings come in by tap-to-place (Reading tool, you type the dBm) or CSV
  (`x, y, band, rssi`, optional `level, device, snr, throughput, bssid, time`).
- The fit is per band: unknowns are `extra loss`, the exponent `n` and the loss
  of each material the readings cross; path loss is linear in them, so the fit
  is a Huber-reweighted ridge regression toward the priors (bounded). At least
  8 matched readings per band. "Area" for cross-validation is a 4 m block of one
  level; below three areas there is no held-out figure and the planner's margin
  stays at 6 dB. With one, the margin becomes the held-out RMSE, clamped to 3-10 dB.
- Accepting a fit updates only the *identified* materials (posterior sd below
  80% of the prior sd), stores `Calibration` (n, extra loss, held-out error) and
  is an ordinary undoable edit. The throughput readings do not yet calibrate the
  MAC efficiency; that stays at 0.6.
- Measure-next hints are the cells with the largest exposure to still
  unidentified materials, at least 3 m from existing readings.

## 8. Storage outside git

```
$HOMEMESH_DATA/                    # an absolute path, never inside the checkout
  houses/<house-id>/
    house.json                     # current revision (the model)
    revisions/<n>.json             # history; pruned by an explicit command
    blobs/<sha256>                 # blueprints, photos, video, USDZ, exports
    measurements/<n>.json
    runs/<run-id>/                 # planner results, heat map grids (cache)
  index.sqlite                     # run index and caches only; rebuildable
  catalogue/                       # owner's private equipment overrides
```

- Documents are plain JSON (diffable, easy to back up, easy to restore);
  blobs are content-addressed and immutable. SQLite holds only derived,
  rebuildable data.
- The path comes from `HOMEMESH_DATA`. In development with no variable set,
  the app refuses to start rather than default to a directory inside the
  repository; tests set it to a temporary directory and use only synthetic
  fixtures. `data/` stays in `.gitignore` as a second line of defence.
- **Logging rule:** logs never contain coordinates, file names from imports,
  blueprint text, or measurement values; they carry ids, counts and
  durations. The same applies to error messages in tracebacks that reach CI.
- Backups are the owner's (D2). Recommended: a periodic copy of the data
  directory to a second disk, encrypted; the tool provides `export` and
  `verify` commands.
- Screenshots and exported reports contain the house layout. Nothing in the
  tool uploads them anywhere.

## 9. Known limits of the model

Stated up front so the results are read correctly: single-client throughput,
no neighbours' interference, no latency model (hop count as proxy), idealised
mesh steering, stationary geometry (a closed door, a new bookcase, a
refrigerator change the answer), geometry only as accurate as the import,
unknown materials behind finished walls, 6 GHz behaviour less well supported
by literature than 2.4/5. The calibration residual is the honest summary of
all of them.

## 10. Capture: RoomPlan and the iOS app

### 10.1 Import path (backend)

RoomPlan is an Apple framework (ARKit/LiDAR, iPhone/iPad Pro with LiDAR).
A scan yields a `CapturedRoom` (walls, doors, windows, openings, and
furniture-like objects, each with dimensions, a 4x4 transform, a category
and a confidence); several rooms can be combined into a `CapturedStructure`
(iOS 17+). `CapturedRoom` is `Codable` (JSON) and exports a USDZ model. The
exact API surface must be verified against current Apple documentation when
M8 starts; this section states the intent.

The importer reads the **JSON** (the geometry we need); the USDZ is stored as
a blob for display and for the owner's reference but is not parsed for
walls.

1. Parse surfaces: each wall is a rectangle with a transform; project to the
   plan, derive `a`, `b`, `height`, `base_z`.
2. **RoomPlan walls have no usable thickness and no material.** The importer
   assigns the default thickness/material by the owner's class defaults
   (interior/exterior) and marks the walls `source: scan` with those fields
   flagged as defaulted. Exterior walls are detected as the hull of the
   plan. Blueprints and manual edit supply the truth.
3. Doors, windows, openings become `Opening`s on the nearest wall.
4. **Merge** rooms: collinear/overlapping walls from adjacent rooms are
   snapped together within a tolerance (default 10 cm) and paired surfaces
   collapsed to one wall with thickness = their separation when plausible.
5. Floors: one capture session = one level unless the owner splits it; level
   elevation from the owner or from the stair. Aligning separate scans (and
   floors) to one frame is a **manual two-or-three point registration** in the
   2D editor (a similarity transform solved by least squares), optionally
   against a blueprint underlay.
6. The importer is deterministic and unit-tested against *synthetic*
   RoomPlan-shaped JSON written for the tests; no real scan enters the
   repository.

### 10.2 iOS capture app scope

Deliberately small:

- Scan one room or several (`RoomCaptureSession` / structure builder), choose
  a house and level label, review, export JSON + USDZ.
- Upload to the backend over the tailnet (HTTPS through the door, signed in with
  Pocket ID, see 10.5), with retry; keep nothing after a successful upload.
- Optional later: log an ARKit position with Wi-Fi/throughput readings for
  calibration (7.2).
- Out of scope: any editing, viewing of the house, simulation, accounts,
  analytics, App Store distribution.
- Needs an iPhone/iPad with LiDAR and a recent iOS. **It must be built and
  signed on a Mac with Xcode**: this agent works on Linux and cannot compile
  or run Swift, so the app's code can be written and reviewed here but not
  built or tested. The owner builds and installs it (D10), and the app lives
  in the same repository under `ios/` (recommended) so the export format and
  the importer are versioned together. A format contract test on the backend
  side keeps both honest.

### 10.3 As built (M8)

- Backend: `homemesh/roomplan.py` (importer, registration), `captures.py`
  (stored scans). Surfaces become walls in plan
  coordinates (ARKit X, -Z; Z up), two faces 3 cm to 60 cm apart merge into one
  wall whose thickness is their separation, everything else gets the class
  default flagged `thickness_defaulted` / `material_defaulted`. Doors, windows
  and openings land on the nearest wall (the same door seen from two rooms is
  kept once). Importing a scan again replaces what it added before (provenance
  `ref` starts with the capture id); other walls are untouched.
- Registration is an `Umeyama` fit of rotation and translation from two or more
  picked point pairs (scale fixed at 1: scans are metric); the worst pick error
  is reported. The scan is first imported in its own frame, then aligned once.
- The app uploads through the door like any other caller (10.5); the backend
  has one kind of caller and no upload token.
- Not done: exterior detection (all unpaired walls get the interior default),
  rooms from the scan, objects, floors and sections are ignored.
- The Swift code in `ios/` is written but not compiled (no Mac here).

### 10.5 iOS sign-in (owner decision 2026-10-20)

No route skips the door and there is no upload token (the earlier M8 token
design is dropped). The app is a public OIDC client of Pocket ID: authorization
code with PKCE (S256) in `ASWebAuthenticationSession`, callback
`homemesh-capture://oauth`, scopes `openid profile email`, id token kept in the
Keychain and sent as `Authorization: Bearer <id token>`. The door accepts
Pocket ID-issued JWTs as bearer tokens (issuer and audience pinned) and sets
`X-Forwarded-User`, so the backend is unchanged apart from deleting its token
path. Why the id token and not an access token: it is what the door can verify
with the settings it already has, and the audience is the capture client alone.
Body limits (30 MB JSON, 200 MB USDZ), token expiry and the exact list of
door and Pocket ID changes are in `deploy.md`.

### 10.4 Equipment catalogue as built (M9)

`homemesh/catalogue.py` layers three sources, later wins: the built-in generic
entries (invented round numbers, always `assumed`), `catalogue/*.json` in the
repository (public spec-sheet figures; an entry without `sources` is refused),
and the owner's `$HOMEMESH_DATA/catalogue/*.json` (private, no source required).
Each radio carries `assumed`; the planner form shows the origin and the flag.
**No real models are seeded yet:** that waits for the owner's shortlist (D12),
because vendors rarely publish antenna gain or per-band power and an unrequested
broad catalogue would be mostly guesses.

## 11. Blueprint import

Image (PNG/JPEG) or PDF, held as a blob in the data directory.

1. **Rasterise** PDFs server-side (a PDF library, one page per level).
   Vector PDFs *could* be mined for line geometry; that is an optimisation
   for later, not v1.
2. **Scale** from one known dimension: the owner clicks two points and types
   the distance; pixels-per-metre is set. A second dimension checks the
   result (the tool shows the disagreement as a percentage). **Rotation** by
   marking a line that should be horizontal.
3. **Trace** in the 2D editor over the underlay: click polylines for walls,
   pick a material per wall (or a class), place doors/windows; snapping and
   a grid help. Nothing is assumed from the pixels in v1.
4. Optional **assist**: line detection (Hough/skeleton) proposes walls the
   owner accepts or rejects; always human-confirmed; M-late.
5. **Registration** with a scan (10.1.5) and a **level** assignment for
   floors the scan did not reach.
6. Blueprints are often wrong about as-built conditions (renovations) and
   unreliable about materials; the tool shows `source: blueprint` so they can
   be reconciled with the scan, which wins on geometry; the blueprint wins on
   materials and unscanned floors.

Photos and video are **reference material** in v1: attached to a room or a
position, shown beside the 3D view, used by the owner to decide a wall's
material. Reconstruction from them (photogrammetry, learned depth) is a
later option that would use the PC's GPU and is not designed here (D14).

## 12. Deployment

- **Lane:** `runner` (dev.toml `[deploy]`): a deploy workflow on a
  self-hosted runner on the Arch PC, the project's own file, reviewed by hand.
  It builds the image on the runner (a container with the backend and the
  built front end; no registry needed), and restarts the service. The
  data directory is a **bind mount** from a host path outside the checkout
  and outside the image; it is never baked in.
- **Public repository, private runner:** the deploy workflow triggers only on
  push to `main`; no self-hosted job ever runs for `pull_request` events
  (otherwise a pull request from outside could run code on the PC). CI for
  pull requests runs `./scripts/verify` on GitHub-hosted runners. The owner
  session confirms the repository settings (approval for outside
  contributors' workflows, no self-hosted runner for forks) (D11).
- **Tailnet only, with a door.** The service binds to loopback or a private
  interface, never to a public one. It is exposed on the tailnet by the
  owner's usual mechanism (for example `tailscale serve` for HTTPS under the
  node's tailnet name, `<tailnet>`), reachable only by the owner's devices
  through the tailnet ACL. Because it holds private house data, an
  **access gate** (the "door") sits in front of the application: the
  application itself trusts the gate's identity and refuses requests without
  it, instead of relying on "it's on the tailnet". What the door is (the
  platform's standard door, an identity-header check, a password) is D1.
  Uploads from the iOS app go through the same door with a Pocket ID bearer
  token (10.5).
- **Secrets:** none in the repository or image; the token and any door
  secrets are provided by the owner session at deploy time. The agent does
  not hold and cannot reach them.
- **Who does what:** this agent writes the `Dockerfile`, the workflow and the
  documentation in a PR. Registering the runner, creating the host
  directory, the tailnet exposure and the first deploy are the owner
  session's. The PR states exactly what is needed.
- **Observability:** a health endpoint and structured logs without house data
  (8). No telemetry leaves the PC.
- The backend is stateless apart from the data directory, so a redeploy
  loses nothing; job state is rebuilt from the data directory.

## 13. Milestones

Each milestone ends with `./scripts/verify` and `dev check .` green, and each
is a PR (or a few). Nothing past M0 starts before the owner accepts this
design.

| # | Milestone | Done when |
|---|---|---|
| M0 | Skeleton (exists) | verify and `dev check .` pass; brief, licence, ignore rules. |
| M1 | Data model | Pydantic schema, JSON Schema export, load/save with revisions in `$HOMEMESH_DATA`, validation, synthetic fixtures, the "no house data in the tree" verify check, dependency lock. |
| M2 | Propagation engine | MWM per band on the fixtures; analytic tests (free space; one wall = the stated loss; one slab; stairwell hole; opening beats wall); material priors with citations; heat-map grids; a CLI that writes a map to a temporary directory. |
| M3 | Viewer + first deploy | Read-only browser 3D view with per-level heat map for a synthetic house; Dockerfile, deploy workflow, the door; the owner can open it from the Mac and the phone. (Deploying early is the point: the data-handling path is proven before real data exists.) |
| M4 | Editor | 2D level editor and 3D view: walls, openings, materials, jacks, outlets, switches, zones, entry, nodes; undo; revisions. |
| M5 | Blueprint import | Upload, rasterise, scale, rotate, trace, level registration. |
| M6 | Backhaul + planner | Backhaul graph, MCS/rate tables, candidate generation, exhaustive + greedy search, Pareto ranking, explanation, comparison UI; the ILP bound. |
| M7 | Calibration | Measurement import, fit with priors and area cross-validation, posterior into the sensitivity analysis, "measure here next" hints. |
| M8 | RoomPlan | Importer (JSON), registration, merge; the iOS app in `ios/` (written here, built by the owner); format contract test. |
| M9 | Equipment catalogue | Seed from public spec sheets with sources and "assumed" flags; client device profiles; owner's overrides. |
| M10 | Later options | Photo/video attach; blueprint line assist; reconstruction from video/photos; ray-tracing gate review; Wi-Fi 7; client load. |

Order argued: the engine (M2) and a deployed viewer (M3) come before capture,
because they can be tested entirely on synthetic houses on Linux, and
because the tool is worth having with a hand-traced blueprint alone. The
brief puts the iPhone scan first for real houses; that is satisfied by M8
being the importer the editor then refines. If the owner wants a scan sooner,
M8 can move ahead of M5/M6 (D9b).

## Owner decisions

Status 2026-10-20: the owner accepted the design as recommended, with the
answers below. The options and recommendations that follow are kept as the
record of what was weighed.

| Decision | Answer |
|---|---|
| D1 door | The platform's standard door: Pocket ID plus the door container in front of the app, as other stacks do. Provisioned with the agent at M3. |
| D2 data and backups | Under the stack's `/srv` volume, covered by the standard stack-backup timer. The owner session sets the path at M3. |
| D3 units | Configurable per user; the default follows the browser locale's convention. |
| D4 front end | Preact. |
| D5 propagation | As written (MWM from geometry, P.1238 baseline, ray-tracing gate). |
| D7 search | Exhaustive + greedy first, ILP bound later; `K_max` 5; the owner's shortlist plus an all-catalogue mode. |
| D8 calibration | Mac laptop (CoreWLAN, tap-to-place) now; the iPhone capture app later. |
| D9 wired defaults | Conservative table; unknown jacks dead in the base plan with an "if it works" variant; a measured speed overrides. |
| D9b order | As in section 13. |
| D11 runner policy | Deploy only on push to `main`; no self-hosted jobs for PRs; fork workflows need approval (already the repository setting). `[deploy]` is set when M3 adds the stack. |
| D14 photos/video | Deferred. |
| D15 storage | JSON documents + content-addressed blobs + rebuildable SQLite index. |
| D16 latency | Not simulated in v1. |
| **Open, needed later (not blocking M1-M5)** | D6 the owner's main client devices and zone needs; D12 equipment shortlist, budget, WAN rate; D13 region. Until answered: the strictest common region and the designer's defaults. |

Original text of each decision:

**D1. The door (access gate).** What sits in front of the app?
(a) The platform's standard door, if one exists for tailnet services;
(b) `tailscale serve` with identity headers and an ACL limited to the
owner's devices, the app checks the header; (c) an application password.
*Recommended: (a) if it exists, else (b)*; (c) only on top of either. The
owner session must tell me which, as I can't see the infrastructure.

**D2. Data directory path and backups.** A host path (for example under
`/srv`) outside any checkout, plus how it is backed up. Options: encrypted
copy to a second disk (recommended); none; a private off-site backup (more
exposure of the data). *Recommended: the encrypted second copy, path chosen
by the owner.*

**D3. Units in the UI.** Metric internally either way. Display metres or
feet/inches? *Recommended: a per-user setting, default as the owner prefers;
tell me which default.*

**D4. Front-end stack.** three.js + TypeScript + Vite is assumed. UI layer:
Preact (small; recommended), Svelte, React, or none (plain TS). Low
stakes; *recommended Preact.*

**D5. Propagation model and the ray-tracing gate.** Accept: MWM from real
geometry per band, calibrated, ITU-R P.1238 as baseline only, ray tracing
only through the gate in 3.6 (held-out RMSE above ~6 dB and structured
errors). Alternatives: P.1238 only (simpler, cannot explain walls); ray
tracing from the start (heavy, depends on geometry quality we will not have).
*Recommended: as written.*

**D6. What "good coverage" means.** (a) The utility shape per zone
(linear ramp between a floor and the target; step at the target; smooth
saturating curve); (b) the default thresholds (for example 25 Mbit/s floor,
the zone's `min_throughput` as target); (c) the reference client (a 2x2 ax
phone, a 1x1 ac laptop, both); (d) whether the worst-zone score is a hard
constraint or just reported. *Recommended: linear ramp, the client profile of
the owner's actual main devices, worst-zone reported and shown in the Pareto
front, `must` zones are hard.* The owner supplies the devices and the zones'
needs.

**D7. Search method.** Exhaustive + greedy/swap first, ILP bound later
(recommended); ILP first (provable for coverage, poor for backhaul); greedy
only (fastest, no guarantees). Also the maximum node count `K_max` to
search (*recommended 5*) and whether to optimise the model/mix of
equipment or take a shortlist (*recommended: the owner's shortlist, plus an
all-catalogue mode*).

**D8. Calibration device.** Which device does the owner walk with?
(a) Mac laptop (CoreWLAN: good RSSI; recommended with tap-to-place
position); (b) an Android phone (best scan data); (c) iPhone (coarse signal
only, but with the capture app's ARKit position: good for throughput). Also:
is there a tolerable time to take a walk of ~50-100 readings, and may the
existing router be used as the reference source? *Recommended: (a) now,
(c) later in the capture app.*

**D9. Wired capability defaults.** The rate table per jack type (cat5e 1G,
cat6 up to 2.5G, cat6a up to 10G, MoCA via an adapter rate the owner
states), run lengths if known, and whether to trust `unknown` jacks in the
base plan. *Recommended: the conservative table, unknown = dead in the base
plan with an "if it works" variant, the owner's measured speed overrides.*

**D9b. Milestone order.** Engine and viewer first, then editor, blueprint,
planner, calibration, RoomPlan (as in 13); or RoomPlan import and iOS app
ahead of the planner. *Recommended: as in 13; swap if the owner will have the
scan ready first.*

**D10. The iOS app: building and distribution.** The agent cannot compile
Swift. (a) Code in `ios/` in this repo, written by the agent, built and
installed by the owner from Xcode on a Mac with the owner's own signing
(recommended); (b) a separate repository; (c) the owner writes it. Also:
the iPhone model (LiDAR needed) and iOS version, and an Apple developer
account only if the owner wants TestFlight rather than a cable install.
*Recommended: (a), personal install, no App Store.*
*Answered 2026-10-21: (a), built and installed from Xcode on the owner's MacBook Air with the paid team (cable install, no TestFlight). The iPhone is an iPhone 17 Pro Max, which has LiDAR, so RoomPlan scanning works. iOS version: whatever the phone runs (the app targets iOS 17 and later).*

**D11. Public repository and self-hosted runner policy.** Deploy workflow
only on push to `main`; no self-hosted jobs for pull requests; outside
contributors' workflows need approval; confirm the lane is `runner` and set
`[deploy]` stack/host in `dev.toml`. *Recommended: exactly that; the owner
session sets it.*

**D12. Equipment catalogue seeding.** Which mesh systems/routers is the
owner considering, a budget, and the ISP/WAN rate? Vendors rarely publish
antenna gain or per-band EIRP, so entries will carry "assumed" flags.
Options: the agent seeds from public spec sheets of the owner's shortlist
(recommended), seeds a broad catalogue, or the owner supplies the numbers.
(The household's own equipment and WAN rate are private data and go in the
data directory, not the repository.)

**D13. Regulatory domain.** Channels and power limits differ (US FCC,
EU...). 6 GHz availability and the DFS rules follow. *Recommended: the owner
states the region; default to the strictest of the common ones if unstated.*

**D14. Photos and video reconstruction.** Confirm they stay reference-only
until after M9, and then decide whether to build a reconstruction path
(uses the GPU) or not at all. *Recommended: defer; revisit when the planner
works.*

**D15. Storage format.** JSON documents + content-addressed blobs +
rebuildable SQLite index (recommended); SQLite as the primary store (easier
queries, harder to inspect and back up); a database server (not
recommended: unnecessary operations).

**D16. Latency.** Accept that latency is not simulated in v1 (hop count and
wired-versus-wireless as proxy), or require a latency model before the
planner is useful. *Recommended: accept for v1.*
