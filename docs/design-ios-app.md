# The homemesh iPhone app (amendment to design section 10.2)

Status: amendment of 2026-10-21, on the owner's decisions below. It supersedes
section 10.2's "scan, combine, upload, nothing else": the iPhone app becomes a
full client. `design.md` stays the design of the model, the propagation, the
backend and the deployment; this file covers the phone only. Nothing here puts
house data in git: the app talks to the live backend and keeps scans on the
phone until the server confirms them.

## Owner decisions

| | Decision |
|---|---|
| **D-A** | Scope is everything, from the phone alone: create and pick a house and level; scan; name rooms; upload; place and align scans on the plan; wall thickness and materials; and the mesh planning (equipment catalogue, placement rules, calibration, plan jobs, comparisons, results). |
| **D-B** | All native SwiftUI, no web views. The backend API stays the single source of truth and the web app stays. |
| **D-C** | The owner names every room in the app after scanning it. No auto-guessed labels in the UI. RoomPlan's section labels may still be stored as data. |
| **D-D** | Stitching is automatic and deterministic (no LLM): rooms of one session share the frame; separate sessions are lined up by shared doorways and room names; the owner fixes placement by dragging on the phone. |

| **Q1-Q9** | **Accepted as recommended (2026-10-21):** hand-written `Codable` models with raw-JSON passthrough plus the fixture decode test; whole-house `PUT` with the revision conflict; scanning and the upload queue work offline, everything else needs the server; 2D canvas first, 3D later; typed dBm or speed-test readings (the 0 to 1 `NEHotspotNetwork` figure optional, off by default); display name "homemesh" with the bundle id kept; room names as free text with suggestions; iOS 17 minimum. |
| **Blueprints** | The owner finds the LiDAR better than expected. LiDAR scans are the primary source of the plan. No phone blueprint import and no new blueprint work; the web app's blueprint underlay stays as an optional aid, untouched. Revisit, and possibly drop blueprints entirely, after the whole house is scanned and an accuracy check (below) is done. |

The first real scan worked on 2026-10-21 (one capture of two rooms), so the
capture, sign-in and upload path of section 10.5 is proven; this amendment
builds on it.

## 1. Shape of the app

A thin client. Geometry that needs care (alignment, import, simulation, the
planner, calibration) stays in the Python backend, where it is unit-tested on
synthetic houses and shared with the web app. The phone owns the screens, the
scanning, and editing gestures. Rules:

- The phone never holds an authority the server lacks: scans waiting for
  upload are the only local state of value, and they are removed only after the
  server answers 2xx for both the capture and its USDZ.
- Edits are made against the house's `revision` (`PUT ... ?expect_revision=`),
  exactly like the web editor; a 409 shows "changed elsewhere" and offers to
  reload.
- Swift types mirror the JSON of `homemesh/model.py` and keep unknown fields on
  a round trip (so a newer backend field is not dropped by an older app).
  A contract test decodes the committed synthetic fixtures in `tests/fixtures/`
  in the app's unit tests, so model drift fails CI on the macOS job.

## 2. API additions

Existing and enough: `GET /api/houses`, `GET/PUT /api/houses/<id>`,
`POST /api/houses` (id, name), captures upload/list/import, `catalogue`,
`plans` + `jobs`, `ratemap`, `heatmap`, `calibrate`, `measurements/parse`,
`revisions`, blueprints. New (all behind the door, all with tests):

| Endpoint | Purpose |
|---|---|
| `GET /api/houses/summary` | `[{id, name, revision, levels: [{id, name}], captures, access_points}]` for the house list, one call instead of one per house. `GET /api/houses` is unchanged for the web. |
| `POST /api/houses/<id>/levels` `{name, elevation?, height?}` | Adds a level (id generated, default elevation above the previous level's top, 2.5 m high); returns the house. Level rename/delete stay a PUT. |
| `PUT /api/houses/<id>/captures/<blob>/rooms` `{rooms: [{ref, name}]}` | Stores the owner's room names for a capture (in the capture's metadata, rebuildable). `ref` is the room's index in the capture. Also accepted at upload as `rooms[i].name` in the app's wrapper. |
| Import creates `Room` records | `import` now also adds a `Room` (floor polygon from the scan's floor surfaces or the wall loop, name from the capture) per scanned room; today only walls and openings are imported (section 10.3, "not done"). Re-importing replaces what it added. |
| `POST /api/houses/<id>/captures/<blob>/place?level=<id>` | Auto-placement (section 4): returns the proposed registration (rotation, translation), a confidence class, the evidence (matched doorways and room names), up to two alternatives, and a preview of the walls after placement. Stores nothing. |
| `POST .../import` | Already takes `registration`; the app sends the accepted or dragged transform. |
| `GET /api/schema/house` | JSON Schema of `House` (from pydantic), for the contract test and for reading, not for runtime validation. |

Audit of "what the web uses that is not API yet": none known. The web editor,
planner, calibration and scans panels use only the endpoints above. Step 2 of
the milestones re-checks this against `web/src/api.ts` and lists any gap before
building on it. Wi-Fi measurements from the phone are covered by `calibrate`
(the measurements are part of the house), not by a new endpoint.

## 3. Screen map

```
Houses ─┬─ new house ─ levels
        └─ House
           ├─ Plan (2D canvas; level switcher; the working surface)
           │    ├─ walls: tap to select, thickness, material, openings
           │    ├─ rooms: names
           │    ├─ rules: draw allow / forbid / demand zones, outlets, jacks
           │    └─ equipment: access points on the plan
           ├─ Scans
           │    ├─ Scan a room / several rooms (RoomPlan)
           │    ├─ Name the rooms (a sheet right after the scan)
           │    ├─ Waiting to upload (kept until confirmed)
           │    └─ Place: auto-proposal ghost on the plan, drag/rotate, Accept
           ├─ Plan a mesh
           │    ├─ choose catalogue shortlist (or all), budget, K_max
           │    ├─ job progress, Pareto list of arrangements, explanation
           │    └─ compare two arrangements; rate map overlay on the Plan
           └─ Calibrate
                ├─ add measurements at tapped positions (dBm, speed)
                ├─ fits, held-out error, which materials are identified
                └─ apply (previews the new margin)
Settings: server, Pocket ID, sign out
```

The Plan canvas is SwiftUI `Canvas` in 2D at first (walls, openings, rooms,
zones, heat map from the `heatmap`/`ratemap` grids). A 3D view (SceneKit) is
optional and last; the web app remains the place for the full 3D view.

## 4. Auto-alignment

Goal: given a new capture C (its own session frame) and the plan P already on
a level (walls, openings and rooms from earlier imports), propose the 2D rigid
transform (yaw and translation; scale is 1 since scans are metric) that puts C
where it belongs. Deterministic; no randomness, no learned model.

**Within a session** nothing is computed: rooms captured together share a frame
(`StructureBuilder`), so their relative placement is already right.

**Between sessions**, in order:

1. **Empty plan.** If P has no walls on the level, C is placed as is, rotated
   about its centre so its dominant wall direction is axis-aligned. Confidence
   "auto".
2. **Candidate transforms.**
   - *Doorway pairs.* For each opening `a` in C and `b` in P of compatible kind
     (door/arch/opening; windows only with windows) and width within 15 cm:
     the transform that makes their wall directions parallel and their midpoints
     coincide, in both orientations (180 degrees apart). A doorway seen from
     both sides gives two midpoints up to a wall thickness; the normal-direction
     tolerance is 0.30 m.
   - *Named rooms.* If a room in C has the same (case- and space-folded) name as
     a room in P, the transform that best overlays their wall loops (centroid
     alignment, then the dominant edge direction in both orientations) is a
     candidate. This catches a room scanned again from another doorway.
3. **Scoring** of each candidate T (C transformed by T against P), higher is
   better: (+) length of C's walls lying within 8 cm of a parallel P wall
   (shared walls coincide); (+) coincident openings; (+) a named-room match;
   (-) area of C's room polygons overlapping P's room polygons (rooms cannot
   overlap); (-) length of C walls crossing P walls transversally. Weights are
   constants in one place and are covered by tests.
4. **Refinement** of the best few: a handful of point-to-line iterations on
   wall segments, with the rotation snapped to the dominant direction of P if it
   is within 3 degrees (houses are mostly rectilinear).
5. **Result.** The best candidate, a confidence class and the evidence.
   Confidence compares the best score with the best *distinct* alternative
   (differing by more than 0.5 m or 10 degrees): "auto" (clear winner with at
   least one doorway or name match and no overlap), "confirm" (a plausible
   winner, or a close second), "manual" (no candidate). Ties break on a stable
   order (capture order, then opening ids), so the same inputs always give the
   same answer.

**Failure modes, and what the phone does:**

| Case | What happens |
|---|---|
| No shared doorway and no shared name (rooms scanned in isolation) | No candidates: confidence "manual"; the capture is shown next to the plan for dragging. |
| Repeated layouts (identical bedrooms, symmetrical halls) | Several close candidates: "confirm" with the alternatives listed to cycle through; never silently chosen. |
| Doors moved, closed or occluded between scans | Fewer matches; the name or wall overlay candidates may still win; otherwise "manual". |
| Drift inside a long single session | Not corrected; the owner splits the scan or nudges the placement. Rooms in one session move together. |
| Different levels | The owner picks the level; no vertical stitching is attempted. Stair alignment is a later milestone. |
| Wrong match accepted | The import is a preview and an ordinary edit with a revision: undo is "load the previous revision". |

**Tests** (backend, synthetic): slice each fixture house into captures, give each
a random yaw and offset and small noise, and require recovery within 5 cm and
1 degree for the unambiguous cases and the right confidence class for the
symmetrical and no-overlap cases.

## 5. Milestones

Each is a PR with verify and CI; the iOS job (Xcode 26, strict concurrency,
warnings as errors) must pass; a real-device check by the owner closes each
screen milestone.

| | Milestone | Content |
|---|---|---|
| **P1** | Field fixes (merged, #27) | Trim whitespace, default scan name, house picker. |
| **P2** | API and contract | The endpoints of section 2, room records on import, `GET /api/schema/house`, the audit of web/API gaps, fixture decode tests in the app. |
| **P3** | App shell | Houses list from `summary`, create a house and levels, the room-naming sheet after a scan, uploads with names, a navigation shell with Settings. |
| **P4** | Placement | The `place` endpoint with its tests, the Plan canvas (walls, rooms), the placement view with the ghost, drag/rotate, Accept to import. |
| **P5** | Walls and materials | Select walls, thickness, material (from the house's materials), openings; saving through `PUT` with the revision. |
| **P6** | Rules and equipment | Draw zones (allow/forbid/demand with needs), outlets, jacks, existing access points; the catalogue browser and shortlist. |
| **P7** | Planning | Start a plan job, progress, the Pareto list, the explanation, compare two, the rate map over the Plan. |
| **P8** | Calibration | Add measurements at tapped plan positions, fits and held-out error, apply. |
| **P9** | Polish | Offline scan queue hardening, undo, an optional SceneKit 3D view, accessibility. |

### As built (P2, backend half)

`GET /api/houses/summary`, `POST /api/houses/<id>/levels`, `PUT .../captures/<blob>/rooms`
(body `{"names": [...]}`, one per room of the capture, order kept; names carried in the
wrapper's `rooms[i].name` are used when none were set), `GET /api/schema/house`, and
`import` now creates a `Room` per scanned room (the convex hull of its wall ends, named
from the owner's names, else the wrapper, else "Room N"; re-importing replaces them) and
accepts a ready `transform` `{rotation, tx, ty}` besides point-pair `registration`.
The hull is a stand-in for an L-shaped room's true outline. Not yet: the `place`
endpoint (P4), and the app-side fixture decode test (it needs the Swift models, P3).

### Accuracy check (before deciding about blueprints)

After the whole house is scanned: choose five to eight walls of different lengths
(a short one, a long one, across a doorway, across a room), measure each with a tape,
and compare with the length the app shows for the same wall once P5's wall
inspector exists (until then, the web editor shows wall lengths too). Record the
differences; scan error below about 2 percent or 3 cm is better than a hand-traced
blueprint. Door and window widths and ceiling height are checked the same way. If it
passes, blueprints are dropped from the plan; if not, they stay as the underlay and
the failing walls are corrected by hand. A "measure check" screen in P5 (pick a wall,
type the tape reading, see the difference and the running mean) is cheap and is added
there.

## 6. Open questions (answered; kept for the record, recommendation first)

1. **Swift model strategy.** Hand-written `Codable` structs for the parts the
   app edits, with a raw-JSON passthrough for the rest, checked by the fixture
   decode test (recommended); or generate Swift from the JSON Schema (more
   machinery, more drift protection). Recommend the former.
2. **Concurrent edits from phone and web.** Whole-house `PUT` with the revision
   conflict (recommended; the same rule as the web editor), or operation-based
   patches. Recommend `PUT` now and patches only if conflicts prove annoying.
3. **Offline.** Scanning and the waiting-to-upload queue work offline; everything
   else needs the server (recommended). Offline editing needs a merge story.
4. **Plan view.** 2D canvas first, 3D later (recommended).
5. **Wi-Fi readings.** iOS gives apps no per-AP RSSI; `NEHotspotNetwork` offers a
   0 to 1 signal figure for the connected network and needs an entitlement and
   location permission. Recommend: type a dBm reading or a speed test result at
   a tapped position (a download from the server measures throughput), and
   treat the 0 to 1 figure as an optional relative reading, off by default.
6. **App identity.** Rename the display name to "homemesh" but keep the bundle
   id `com.scshafe.homemesh-capture` so the installed app updates in place
   (recommended).
7. **Room names.** Free text with suggestions ("Kitchen", "Bedroom 1", the names
   already used in the house), as D-C asks that the owner names every room.
8. **Blueprint import on the phone** (photo or file into the underlay): not in
   the milestones above. Recommend later, after P7, since blueprints are already
   handled by the web app and the owner's rooms come from scans.
9. **Deployment target.** Keep iOS 17 as the minimum until a feature needs more
   (the owner's phone runs a newer iOS).
