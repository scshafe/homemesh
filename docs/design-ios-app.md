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

| **UX 2026-10-21** | (1) One name field per room: asked once, prefilled, the same control everywhere; any room can be renamed at any time. (2) A distinct "Add room scan" button, not a list row. (3) A **room** is the first-class item: name (required), description (optional), floor, scan; "Re-scan this room" replaces its geometry and keeps the earlier capture as history. (4) Tapping a scanned room shows its 3D model (the uploaded USDZ) and its details. (5) **Floors** are explicit: a scan belongs to a floor chosen when the scan starts (default: the floor being viewed), lists are grouped by floor, and the floor can be changed later. (6) **Staircases** link two floors: the house model's `Stair` (footprint on the lower floor, `void` opening on the upper floor, already an open path in the Wi-Fi model). When a scan contains a stairs object the app asks which floor it leads to and whether up or down; one can also be added by tapping the plan; the stair anchors the floors to each other in XY as doorways do within a floor. BUG B (restarting the scanner) comes first. |

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

## 4b. Rooms, floors and staircases (P4b)

**Rooms as items.** The app's unit is a room, not a scan. Without changing the stored house, the server
derives a room list: every room of every capture (`captures/<blob>` meta `rooms[i]`) joined with the house
`Room` the import made for it (`prov.ref = <blob>#room/<i>`). A room that no import made yet is *unplaced*
(shown, with its 3D model, and placeable). Attributes live where they are rebuildable: the name and the
description in the capture's meta (`rooms` and `details`), copied onto the house `Room` on import
(`Room` gains `description`). So the existing captures need no migration: their rooms appear as unplaced
rooms; only the names, still empty, are typed once.

`GET /api/houses/<id>/rooms` returns `[{key: "<blob>:<i>", name, description, level, scan: <capture name>,
placed: <room id or null>, usdz: <blob or null>, walls, replaced_by: <key or null>}]`. `PUT
.../captures/<blob>/rooms` takes `names` and optionally `descriptions`. The USDZ is already served by
`GET .../blobs/<digest>`.

**Floors.** One scan is one RoomPlan session on one floor, and a session's rooms share a frame, so the floor
belongs to the scan and its rooms inherit it. `PUT .../captures/<blob>/level` changes it; if the scan is
already imported, its walls, openings and rooms move to the new level in one revision (the import is
replayed on the new level at the same placement). Moving a single room of a multi-room scan to another
floor is not offered: rescan it on that floor.

**Re-scan.** "Re-scan this room" starts a normal scan on the room's floor with `replaces=<key>` recorded in
the new capture's meta. Placement is proposed by name and shape (P4 already treats an equal owner-given name as
the same room, not an overlap). On accept, the old room's *own* walls (those whose source surfaces all belong
to that room of the old capture) and its `Room` are removed, the new geometry is imported, and the old capture
stays stored as history (`replaced_by` on its room). A wall shared with a neighbouring room's scan is kept.

**Staircases.** The model already has `Stair(from_level, to_level, polygon, void)`; a void stair is a slab hole
on the upper level, so the Wi-Fi model already treats it as an open path between floors (propagation.py).
Needed: (a) on import, a RoomPlan `stairs` object becomes a *suggested* stair (not saved) with its footprint;
the app asks "which floor does it lead to, up or down" and saves it through the house `PUT`; (b) a stair can
also be drawn on the plan (P5/P6 editor); (c) **floor-to-floor alignment**: the footprint of a stair on the
lower floor and the matching opening on the upper floor fix the XY offset between floors, as doorways do
within one; `place.py` gains a candidate source "stair" for a scan on a level whose neighbouring level has the
same stair. Rotation between floors is taken from the stair's long axis.

**As built (P4b-1):** `Room.description`; capture meta `descriptions` and `level`; `PUT .../captures/<blob>/rooms` takes `names` and optional `descriptions`; `PUT .../captures/<blob>/level` (moves an imported scan's walls and rooms in one revision); `GET /api/houses/<id>/rooms` as above (without `walls` and `replaced_by`, which arrive with re-scan). The USDZ is `GET .../blobs/<capture meta usdz>`.

**As built (P4b-3):** `POST captures?replaces=<capture>:<room index>`; `place` leaves the replaced room's own walls out of the plan (falls back to the whole plan when nothing else is on the level); `import` removes the replaced room and the walls whose source surfaces all belong to it (`roomplan.retire_room`; a wall paired with another room's face stays, and the new scan brings its own copy of it, so a doorway shared with a neighbour may appear twice until P5's editor); the room list has `replaced_by` and the app hides replaced rooms; the new room's description is copied from the old.

**As built (P4b-4):** `roomplan.stair_footprints` reads RoomPlan `stairs` objects as plan rectangles; the `import` report lists them as `stairs` (suggestions in the placed coordinates, nothing saved); `POST /api/houses/<id>/stairs` `{from_level, to_level, polygon, void}` saves one (levels must exist and differ; `void` makes the opening on the upper floor, which the Wi-Fi model already treats as open); `place` lines the first scan of a floor up by a stair that already joins that floor (candidate source "stair", confidence "confirm", rotation from the stair's long axis, both directions offered), and scores a staircase that coincides with one on the floor like an opening. The app asks, after a placed scan is saved, which floor a found staircase leads to.

Sub-milestones (small PRs): **P4b-1** server room list, descriptions, floor change, scan `level`
(backend); **P4b-2** app: one name field, "Add room scan" button, rooms grouped by floor, room detail with the
3D model (QuickLook) and rename/description/floor; **P4b-3** re-scan (`replaces`); **P4b-4** stairs
(suggestion on import, app question, floor alignment candidate in `place.py`). P5 follows.

Questions raised with these decisions: (1) *a floor belongs to a scan, so one room of a multi-room scan
cannot move floors alone* (recommended: accept, rescan instead); (2) *old captures stay stored as history
forever* (recommended: yes; a "delete this scan" command later); (3) *a stairs object that RoomPlan misses*: the
owner draws it on the plan (P5/P6).

## 4c. Floor picking and the floor stack (2026-10-22)

Owner feedback from the phone, decided by the oversight session (the owner can override).

**Evidence.** "Basement storage" went to L2 Guest (the owner has since confirmed it is in the basement and moved it to
L1, the basement level, in the store; the Library and the 17:48 scan too), and the
house's Basement level sits +2.8 m *above* Ground, because levels were always created on top of the stack.
(Pantry and Wine Cellar were confirmed on Ground and placed correctly: ceiling height is not a floor signal here,
so nothing below uses it to *choose* a floor.) The old rule, a Floor picker shown before the scan and defaulting to
the first floor, asks the owner to remember and gives no help.

**(a) Choose the floor when saving.** The floor is a segmented picker in the save sheet, beside the room's name and
description, not before the scan. It starts on a suggestion and says why ("same height as Library"; "last floor you
scanned"; "first floor").

**(b) Barometer suggestion.** At scan start the app records `CMAltimeter` relative altitude and pressure together
with a session id (the altimeter runs from the first scan screen of an app launch; relative altitude is only
comparable inside one launch) and the time. The scan wrapper carries `"baro": {session, rel_m, kpa, at}`, the
capture meta keeps it, and the room list returns it. Suggestion, computed in the app from the room list: among
rooms with a `baro` and a floor from the last 12 hours, take the nearest in height: inside the same session by
relative altitude; across sessions by pressure (1 kPa is about 84 m) only when less than an hour apart, since weather
drifts the pressure. Nearest within 1 m wins and its floor is suggested; otherwise the last floor used in this
house; otherwise the lowest above-ground floor. Nothing is moved automatically; the owner sees and can change it.

**(c) Floors are an ordered stack.** `House.levels` order is the stack, bottom to top. `Level.below_ground`
(default false) marks basements; the ground floor is the first level that is not below ground. Elevations are
*derived*, not entered: ground is 0; each level above is the one below plus its height plus the slab (0.3 m); each
basement is the one above minus the slab minus its own height. `Level.height` is taken from the scans on the level
(median wall height, to 0.01 m) when there are any, else kept. `PUT /api/houses/<id>/levels/order`
`{order: [ids bottom..top], below_ground: [ids]}` reorders, re-derives elevations and stores one revision; ids do
not change, so walls, rooms and stairs stay attached. The app gets a Floors screen (drag to reorder, "below
ground" switch, add a floor above or below). This house's Basement is fixed through that screen, by the owner's
confirmation (its data is not touched from here).

**(d) Stories inside one scan.** RoomPlan reports a `story` per room (iOS 17). When the rooms of one session carry
different stories, the save sheet shows one floor picker per story, the lowest story taking the suggestion and the
others the floors above it in the stack (changeable). The capture keeps `room_levels` (one level per room), the
rooms of a session still share one frame, so the one placement transform applies to all of them, and import groups
the rooms by level (walls are merged per level; each level's floor is its own lowest wall). `PUT
.../captures/<blob>/level` keeps working for a single-story scan; the whole-scan-floor rule of 4b is relaxed to
"one floor per story". The measured vertical offset between stories of a session is a better elevation than a
guess; it is reported and not applied automatically.

Pieces (PR each): this note; (a) the picker in the save sheet; (c) backend order/derivation, then the Floors
screen; (b) the barometer; (d) stories.

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
The hull is a stand-in for an L-shaped room's true outline.
`POST .../captures/<blob>/place?level=<id>` (`homemesh/place.py`) implements section 4 with
two differences from the sketch: there is no point-to-line refinement (two scans of the two
sides of one wall see opposite faces, so pulling walls onto each other would collapse a wall's
thickness; the doorway match leaves the scans one wall thickness apart across the wall, which
the import's face-pair merge absorbs), and a room scanned again (equal owner-given name) is not
penalised for lying on its earlier self. Names the importer invented ("Room N") never count as
names. Confidence: `auto`, `confirm` (overlap or a close second place), `manual`. The app-side fixture decode test landed with the Swift models (P3).

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

### As built (P5)

`PlanScreen` (tap a wall; `PlanCanvas` hit-tests the nearest wall) and `WallInspector`: thickness, material, openings (kind,
width, delete), "use for every wall on this floor still on the defaults". The app edits the server's house JSON in
place (`HouseDoc`, Q1's passthrough: only the edited fields change, unknown fields go back untouched, provenance gets
`edited`), then `PUT` with the revision. `House.measure_checks` holds tape readings; the **measure check** in the
inspector and the **Accuracy** screen (mean error, bias, worst, and the bar: at least five readings and a mean within
2 % or 3 cm) implement the accuracy check above. Staircase drawing and zones are P6.

### As built (P6a)

The plan has a tool bar (Select, Outlet, Jack, Access point, Stair). Each tool puts its thing at the tapped spot and saves
the house (a revision per placement); Select edits (a jack's type, state, PoE, height; an access point's name, height,
EIRP; an outlet's height; a staircase's other floor) or deletes. A stair is drawn as its centre line, bottom then top,
as a 1 m wide flight; the floor it leads to decides `from_level`/`to_level` by elevation. Zones and the catalogue
shortlist are P6b and P6c.

### As built (P6b)

Zone tool: pick the kind (where it may go / where it must not / needs signal), tap the corners (one tap is a single spot),
Finish. The zone inspector edits the name; for a demand zone the weight, minimum signal (dBm), optional minimum speed,
receiver height and "must be met"; for an allow zone what it needs (nothing, an outlet, PoE), the mount types and the
allowed heights. Changing the kind clears the fields of the old kind (a demand's `need` is removed, as the model
requires). The catalogue shortlist is P6c.

### As built (P6c)

The **Internet** tool places the one `entry` (modem, fibre ONT or coax drop, with the provider's download and upload
speeds); a plan needs it. **Equipment to plan with** (`CatalogueView`) lists `GET /api/catalogue` (mesh systems and APs; routers
as the gateway choice), with a detail page per item (radios, ports, price, notes, and "numbers assumed" where the catalogue
says so). The shortlist, gateway, client device, K max and the "every system" switch are kept per house on the phone
(`Shortlist`, UserDefaults) and become the plan request in P7 (`equipment`, `gateway_equipment`, `client`, `k_max`).

### As built (P7a)

`PlanRunView` checks what a plan needs, posts `plans` with the shortlist (`equipment`, `gateway_equipment`, `client`, `k_max`), polls the
job every 1.5 s and lists the ranked arrangements (badges from `pareto`, `valid`, `must_ok`, `stable`). `ArrangementView` shows the
explanation lines and stability note, node placements, per-zone utility, rate and limiter, and the backhaul per node;
`RateMapView` draws the `ratemap` grids per floor under the walls with the nodes and the router marked (log colour scale as in the web
app). `ratemap` now returns null for cells with no service (NaN is not JSON). Comparing two arrangements is P7b.

### As built (P7b)

Tap the circle on two ranked rows, then "Compare": `CompareView` loads both `ratemap`s and shows A, B or the difference (blue where B is faster, red where A is, as in the web app) per floor, with a table of score, cost, worst zone, node count and each zone's utility.

### As built (P8)

The **Measure** tool puts a reading on the plan (position, band, dBm, optional speed, device) into the house's `measurements`; the
**Calibrate** screen shows what is there, runs `POST .../calibrate` (the saved house), and shows per band the held-out error,
the exponent, the materials the walks identified with their moved values, readings more than 6 dB off, the suggested next spots (drawn
dashed on the plan) and the planning margin before and after (3 to 10 dB from the worst held-out error, 6 dB when never calibrated).
Apply saves the returned house as a new revision. A regression test pins that `ratemap` stays valid JSON where a thick wall puts cells
out of service (it was already null on the wire; the explicit conversion is kept). CSV import of measurements stays a web feature.

### As built (P9a)

Offline scan queue: `UploadQueue` writes the scan (JSON, USDZ, house, floor, name, `replaces`) to `Documents/Uploads/<id>/` before any
network call and removes it only after 2xx for both parts; `HouseView` lists and retries the house's queued scans (in order, stopping at the
first failure) on open and on refresh. Everything else still needs the server (Q3).

### As built (P9b)

Undo: `POST /api/houses/<id>/revisions/<n>/restore?expect_revision=` saves revision `n` as the next revision (history kept, 409 if the house
moved on). The plan screen's Undo restores the revision before the current one, and again before that on a second press; an ordinary edit
resets the chain.

### As built (P9c)

`House3D` builds a SceneKit scene from the plan data (a box per wall at elevation + base + half its height, a thin translucent slab per
floor, a block per staircase; plan (x, y) to scene (x, -y) with Y up), `House3DView` lets the owner orbit it and hide floors. Openings,
furniture and the scanned meshes are not drawn (a room's own USDZ opens in Quick Look from the room details).

### As built (P9d)

Accessibility: the shortlist and comparison tick-circles are real buttons with labels (they were tap gestures VoiceOver could not
find); the plan canvas has a spoken summary and the Select tool a "Choose a wall from a list" menu as an alternative to tapping;
fixed widths in the comparison table became minimum widths that scale with the text size. Not done: drawing zones or stairs without
touching the canvas (the tap targets there have no list alternative yet).

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

## Later (owner direction, not built)

The ideal scan is **one continuous session that still captures one room at a time**, with on-device speech
recognition labelling each room as the owner walks into it ("this is the pantry") and switching floors by voice
("going downstairs", "now on the basement"). Recorded here so nothing built now closes it off; no work is scheduled.

What it would need:
- **Session and segmentation.** One RoomPlan session spanning rooms and floors, cut into rooms: either a
  `CapturedStructure` built from per-room `CapturedRoom`s as today (stop/start between rooms inside one running
  ARSession, which the app already does), or segmenting one long capture by room boundary. The former reuses what
  exists; the latter needs RoomPlan to expose a per-room split mid-session, which it does not today.
- **Speech.** `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true` (no audio leaves the phone),
  microphone and speech permissions, a small grammar of intents (room label, floor change), kept on a rolling
  transcript with timestamps.
- **Mapping utterances to boundaries.** A label applies to the room being entered: its timestamp is matched to the
  nearest room boundary (a stop/start, or a doorway crossing in the camera track). A floor phrase sets the current
  floor from that moment until the next one. Ambiguous or unheard phrases leave the room unnamed for the save sheet.
- **Barometer to confirm.** A spoken floor change is checked against the altimeter (a drop or rise of about a
  storey since the last room); a mismatch is shown, not silently applied.

Compatibility: the one-room-per-scan flow stays the manual path and the fallback when speech is off or unclear.
The save sheet's per-room name fields, per-story floor pickers (4c) and barometer suggestion are exactly where
voice results would land as *prefilled suggestions* (a name, a floor and "heard: 'going downstairs'" as the
reason), and the owner still confirms before saving. Captures already carry per-room names, `room_levels` and
`baro`, so a voice session needs no new storage.
