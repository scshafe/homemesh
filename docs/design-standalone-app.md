# homemesh as a standalone iPhone app (design, for the owner's decision)

Status: **accepted by the owner on 2026-11-03**, with every recommendation in section 13 accepted. Q6 (blueprints) was
answered the same day: **blueprints are dropped from the standalone app**, and the app expects an iPhone with LiDAR (section 9). The
answers are recorded in section 13. Phase 0 starts now and the phases follow under the standing order (planned-work PRs are auto-approved;
only real design questions go to the owner). The UI work in flight (the five style changes, the VoiceOver route, the move to the
`scshafe-ios` package) continues unchanged. The server, web editor and current iOS client stay the product until each phase's gate is met (section 7).

Inputs: the owner's direction of 2026-11-02 (below) and the evaluation notes of the same day (an inventory of the server's functions,
porting cost per function, what goes away, App Store needs, risks). Facts in the notes carry file references there; numbers
labelled *estimate* are the notes' or mine and are not measured on a phone. No house data is used or implied; every example
is a synthetic fixture.

## 1. What is being decided

**Owner direction (2026-11-02):**

1. homemesh becomes a **standalone, serverless iPhone app**. Everything runs on the phone: no homemesh server, no Pocket ID sign-in,
   no tailnet, no Docker deployment.
2. The **editing experience works fully on the phone** and replaces the browser editor: wall drawing and fixing, doors, zones,
   stairs and floors (blueprints were dropped, section 13 Q6). A first-class touch editor; iPad is natural too.
3. **The map does not need high accuracy.** Doorways are the stitching mechanism between rooms: rooms join where their labelled
   doors match (building on the both-sides door-labelling decision), not by precise geometric registration.
4. **On hold, and kept out of the design:** monetization (ads or a one-time Pro unlock) and licence or repository visibility. The
   architecture only has to stay neutral to either (section 12).

**Non-goals** of this document: choosing a business model, an App Store listing, an Android or web version, a cloud service, or
accounts of any kind.

**Recommendation in one paragraph.** Build a Foundation-only Swift package (`HomemeshCore`: model, store, scan-to-walls, door
stitching, propagation, backhaul, planner, calibration, editor operations) and keep the SwiftUI app thin on top of it. Prove the
package against the existing Python engine with golden vectors, and try compiling it on the agent's Linux host so most work needs
no macOS CI round trip. Stitch rooms with a door graph and a least-squares layout, show the residual, and treat 0.5 m as the
"good" line (why, in section 3). Build the editor as operations on the document with a thin gesture layer. Keep the Python server
and web app frozen and running until the phone app reproduces them, migrate the owner's houses with a one-time export, then
retire the deployment and keep the Python engine in the repository as the test oracle.

## 2. Architecture

```
HomemeshCore  (Swift package, Foundation only; no UIKit, SwiftUI, RoomPlan, SceneKit, simd)
  Model        typed Codable House, Level, Wall, Opening, Room, Zone, Stair, Furniture, Equipment, Material...
  Store        one document per house, revisions, blobs (section 6)
  ScanImport   CapturedRoom JSON -> walls, openings, stairs, furniture (port of roomplan.py)
  Layout       door graph and stitching (section 3), floor stack, stair anchoring
  Sim          propagation + rates (port of propagation.py, rates.py)
  Net          backhaul graph, per-cell client rate, zone scoring (port of network.py)
  Planner      candidates, search, explanation, Pareto (port of planner.py, explain.py), cancellable, with progress
  Calibrate    ridge/Huber fit, cross-validation, suggestions (port of calibration.py)
  EditOps      the editor's operations, hit testing, snapping, undo (section 4)
HomemeshApp   (SwiftUI, RoomPlan, SceneKit/RealityKit, PDFKit, VisionKit)
  screens, canvas, gesture layer, scan capture, share/export, Sui components
```

Rules that keep it testable and neutral:

- **The Core has no Apple UI or sensor frameworks and no network.** It takes plain values (RoomPlan's `CapturedRoom` is read as the
  same JSON wrapper `homemesh-capture-1` the server reads today) and returns plain values. Geometry uses a small `Vec2`/`Seg`
  type of its own, not `simd`, so the package also builds on Linux (section 10).
- **Pure functions plus value types.** `Document` is a struct; an edit is a value applied to it; results are deterministic. The
  planner's random draws (stability under material draws) use a small seeded generator written for this (PCG64 itself is
  not in Swift), so a run is repeatable. Rank-stability percentages will differ slightly from Python's; the tests compare
  rankings and scores, not those percentages exactly.
- **Concurrency.** Long work (planning, calibration fit, rate maps) runs as Swift Concurrency tasks that report progress and can
  be cancelled; the planner parallelises over candidates (`concurrentPerform` or a task group) and watches
  `ProcessInfo.thermalState`. Design target: under 10 s per plan at the 1 m grid in the foreground (*estimate*, 1-10 s in
  the notes); a progress screen, no background execution. If a 0.5 m plan on a large house runs long, iOS 26's continued
  processing is the fallback, not the design.
- **No third-party SDKs** in either target. The Core never imports anything that identifies a user or a purchase.

## 3. The map: doorways, and how accurate is accurate enough

### 3.1 What accuracy the plan needs

The thing being decided is where to put 1 to 6 mesh nodes, then rank arrangements. Three facts bound the useful accuracy:

1. **The model's own error is several dB.** The material losses are priors (marked "unsourced"), the planner adds a margin of
   6 dB uncalibrated, or the held-out RMSE clamped to 3-10 dB when calibrated (`design.md` sections 3 and 7). Geometry error is
   only worth removing if it is small next to that.
2. **Candidate positions are 1.0 m apart** (the default grid and candidate step), and the owner can only put a node where there is an
   outlet or a jack, to within perhaps half a metre.
3. **A position error moves the distance term only slightly**: the change in path loss is about `10 n log10((d + e) / d)` dB. With the
   model's `n` near 3 (*estimate*):

   | distance d | error e = 0.25 m | 0.5 m | 1 m |
   |---|---|---|---|
   | 6 m | 0.5 dB | 1.0 dB | 2.0 dB |
   | 3 m | 1.0 dB | 2.0 dB | 3.75 dB |

   So half a metre of error anywhere costs about 1 to 2 dB, well inside the margin and below one rate step (about 3 dB per MCS).

What a plan can **not** tolerate is a **topology error**, because each wall crossed is a 3 to 20 dB step: a room placed on the wrong
side of a wall, a missing or doubled wall, a door that is not where the sight line passes (open doors and arches cost nothing, so
a door misplaced by more than half its width, about 0.4 m, turns a free path into a wall), rooms overlapping, rooms in the wrong
order along a corridor, or a missing floor slab.

**Proposed acceptance levels** (to be checked against the owner's tape readings, which are still pending):

| Level | Meaning | Shown as |
|---|---|---|
| Good | Door-joined rooms line up within 0.3 m; loop residual (below) within 0.5 m; overall size within about 1 m | success chip |
| Check | Residual 0.5 to 1 m, or a connection that disagrees with another | warning chip with the rooms named |
| Fix first | Rooms overlap, a labelled door has no partner, or residual over 1 m | blocks "Plan a mesh" only with a "plan anyway" choice |

LiDAR scans are far better than that inside a room (the owner's reading is "better than expected"), so the budget is spent
**between** rooms, not within them. The app never claims survey accuracy, and the listing and the UI say "estimates".

### 3.2 Doorway stitching as the whole method

The decision already taken on 2026-10-22 (labelled pairs are *the* placement method) becomes the only layout mechanism; the geometric
search ("Guess for me") is dropped from the standalone app, or kept as a clearly secondary action if the owner wants it
(question Q4).

**Door graph.** Nodes are scans (a session's rooms share one frame, so a session is one node). An edge is a **connection**: a
door, opening or arch of scan A labelled "leads to B" and one of scan B labelled "leads to A" (arches count). Outside is a label, not
a node. Staircases are edges between floors, as now.

**Layout.** 1. Pick the anchor scan per floor (first scan, or the one the owner marks). 2. Walk a spanning tree: each new scan is
rotated so its door wall is parallel to the partner's and the rooms are on opposite sides, then translated so the door centres
coincide, offset by the wall thickness. This is exact up to the label match, with no search and no orientation ambiguity. 3. Edges
that close a loop are **not** discarded: a small least-squares fit over all connections (translation and a small rotation per
scan, door-centre and parallelism residuals, anchor fixed) spreads the disagreement, and each loop's residual in centimetres is
kept. The Python version already does the fit for several connections (`register`, Umeyama); the loop spreading is the addition
(estimate: small, a few hundred lines). 4. Report per connection and per scan: residual, and whether rooms overlap.

**Drift** is bounded by the structure: rooms are rigid scans, joins are wall-parallel, so only door-centre error accumulates
along a chain. With 0.1 to 0.15 m per join and a degree of heading error (14 cm over 8 m), a chain of eight rooms sits near
0.4 m (*estimate*, root-sum-square), and any loop tightens it. That fits the "Good" line, which is why high-accuracy registration
(ICP on walls, loop closure over meshes, anchors) is **not** built.

**Gaps.** Unscanned space between rooms (a hall, a stairwell, a cupboard) is a real source of error: two rooms joined by a labelled
door are right, but the space beyond is unknown. The editor can draw it (section 4: "fill the gap" draws a room from the doors
and walls around it, or an `air` region), and the checklist says which doors lead to unscanned space ("Hall: leads to Study,
which is not scanned").

**Fixing by hand** stays the escape hatch: drag and turn a scan on the plan (exists), nudge by 5 cm or 1°, and "lock this room"
so later fits do not move it.

**What the labelling UI must make easy** (it is the user's whole accuracy lever now): label while scanning each door (the
save sheet exists), a per-floor checklist (exists), and, new here, a "doors not labelled yet" counter on the plan before
planning, with a one-tap suggestion from room names ("Kitchen has a door near Pantry's; label it Pantry?") that never applies
itself.

**Floors** connect by staircases (elevation from the rise, as now) and by a barometer suggestion, not by anything geometric across
floors; a floor's anchor is placed over the one below by the staircase footprints.

## 4. The touch editor (replaces the browser editor)

The web editor's tools are wall, door, window, switch, slab hole, jack, outlet, entry, zone, access point, measure,
blueprint scale/rotate/move/check and delete. The phone already has the second half (jacks, outlets, access points, zones,
stairs, entry, measurements; PRs #84, #86). This section is the first half, designed for fingers, with iPad and Pencil in mind.
The blueprint tools are **not** carried over (Q6). The editor is for **fixing scans and filling gaps**, not for drawing a whole house.

### 4.1 Principles

- **Fingers are fat and hide what they touch.** Handles have a 44 pt hit area; while dragging a point a loupe (a magnified
  offset view) shows the point and what it snaps to; the editor snaps by default and says what it snapped to (a small label:
  "end of wall w12", "90 degrees", "5 cm grid").
- **Numbers beat precision.** Anywhere a length or angle matters, typing it is one tap away (the segment's length chip is a text
  field); a tape measure is the source of truth where a scan is wrong or missing.
- **Every edit is an operation** on the document: undoable, redoable, listed in "Edit history", saved at once (autosave) and a
  revision written on a sensible boundary (a gesture ends, a form is saved).
- **One selection model, two routes.** Everything is reachable by touching the plan and by lists and forms (the VoiceOver route
  of PR #86 is the template and stays); a drawing tool is never the only way.
- **Same editor on iPhone and iPad.** iPhone: the toolbar and the inspector sheet with detents (as now). iPad: a sidebar of floors and
  layers, the plan large, the inspector as a trailing panel, Pencil for drawing, hardware-keyboard shortcuts (undo, delete,
  numbers, arrows to nudge), pointer hover for snap labels, and multitasking sizes.

### 4.2 Operations and where they live

`EditOps` (in the Core) holds: the `Edit` value (add, remove, replace, group, with the ids it touched), `apply` and its inverse,
the history (bounded, coalescing a drag into one edit), **hit testing** (given a point and a tolerance in metres derived from
screen scale: nearest vertex, wall, opening, zone edge, stair, furniture), **snapping** (candidates and their priority) and the
**repair commands** below. The gesture layer in the app only turns touches into `(point, tolerance, phase)` and draws the
result. This is what makes the editor testable on Linux and in plain unit tests: the geometry and the history are in the
package, the touch handling is a thin UIKit recognizer set (already the pattern in `PlanGestures`).

### 4.3 Tools

**Walls: drawing.**

- *Trace*: tap points to make a polyline; each segment shows its length; double-tap or "Done" ends; a closed loop makes a room.
  Snapping: endpoints, wall midpoints, a point on a wall (making a T junction and splitting it), 0/90 degrees (within 3
  degrees) and parallel or perpendicular to a neighbouring wall, and a 5 cm grid (10 cm at small zoom).
- *Draw by numbers*: pick a start, then for each segment choose a direction (the four axes, "continue", or an angle) and type the
  length on a strip above the keyboard; "close" finishes the loop. This is the tape-measure route for **fixing a scanned wall and for filling a gap** (below), not for drawing a house.
- *Fill the gap*: select the doors and walls around an unscanned space (a hall, a stairwell, a cupboard, a room RoomPlan could not
  finish) and the editor proposes the room outline from them; typed lengths adjust it. It makes a room with walls and the doors
  already labelled, or an `air` region where there are no walls.
- *Room templates* (rectangle, L, U): **dropped**. They only suited drawing a whole house; a gap is drawn with the fill-the-gap tool or
  four typed segments, which already gives a rectangle.
- *Pencil sketch* (iPad): freehand strokes are straightened and snapped as above.
- A new wall takes the current thickness and material (shown in the toolbar, one tap to change).

**Walls: fixing.** Drag an endpoint (the loupe shows the snap) or a whole wall (joined ends follow, with a "detach" toggle); split at a
point; merge collinear walls; **straighten** (snap a skewed wall to the nearest axis or to parallel with a neighbour);
**close gaps** (the editor finds endpoints within 15 cm of each other and offers to join them, which matters for scanned
walls); **square corners**; set thickness, material and height for one or many; delete. Multi-select by lasso or "select all on
this floor", and move or rotate a selection (a scanned room moves as one). Curves are chords, as the scan import makes them.

**Doors, windows and openings.** A tray of door, window, arch and open doorway: drag onto a wall (a ghost shows where it will
land, snapping to centre or an end), slide along the wall, drag the end handles for width, flip the swing, set height and
material. Each door has the **"leads to"** label inline (the same field as the save sheet, with the checklist's state chip),
which is where doorway stitching is edited after the scan. Openings are clamped into their wall as the importer does.

**Zones.** Draw a polygon (tap corners, drag vertices, double-tap an edge to add one), or make one from chosen rooms or walls or typed corners
(exists); kind (allow, forbid, demand), name, requirement. Drag a whole zone; duplicate to another floor.

**Stairs.** Draw the flight as two taps (bottom, top) or place from the form (exists); step count, width, turn it round, floors it joins
(elevation from the rise), and the slab hole above it (the "void"). The slab-hole tool of the web editor is the stair void plus a
"floor opening" polygon for other holes (a well, a double-height room).

**Floors.** The stack screen exists (order, ground, below-ground, heights from stairs). Added: copy a floor's walls as a starting point for
the next (common in houses), per-floor height and slab thickness, and show the floor below as a faint underlay while drawing.

**Blueprints: dropped** (owner decision 2026-11-03, Q6): no import, no fitting, no blueprint tools and no blueprint blobs on the phone. Two sources of
truth would have to be reconciled, and few people have a usable blueprint.

**Also from the web editor:** switch (a network switch on the wired path: a point tool like a jack), entry (modem), outlet, jack, access point
and measurement tools exist; CSV measurement import becomes a Files picker (the parser is small).

### 4.4 Accessibility and testing of the editor

Every tool has a list or form route; handles have labels and VoiceOver adjustable actions (move by 5 cm); toasts and banners
as in the Sui library. Tests: the Core's hit-test, snap and repair functions are unit-tested on synthetic plans (snap priority, gap
closing, straightening, splitting, merging, undo/redo round trips, "apply then inverse equals the original document").
Gesture handling is tested by a small set of simulator UI tests and by the owner on the phone.

## 5. The on-device engine

A direct port, function by function. The notes measure the Python as interpreter-bound (23 to 170 s for synthetic houses of 22 to
70 walls) and project 1 to 10 s on an iPhone 17 Pro Max in Swift (*estimate*; to be measured in phase 0).

| Python | Swift module | Approach | Parity test |
|---|---|---|---|
| `model.py`, `equipment.py`, `materials.py` | `Model` | typed Codable with validation, `schema_version` and a migration table; unknown fields preserved on a round trip | decode all `tests/fixtures/*.json`, encode, compare |
| `roomplan.py` (667 lines) | `ScanImport` | surfaces to walls, face-pair merge (3 to 60 cm), chords, jog folding, openings clamped, stairs, furniture, retire on re-scan | the same synthetic scans (`tests/roomplan_synth.py`) exported to JSON, results compared |
| `place.py`, `stack.py`, `connections.py` | `Layout` | labelled connections, spanning tree plus least squares (section 3), floor stack, checklist | place tests ported; loop-residual tests new |
| `propagation.py`, `rates.py` | `Sim` | multi-wall-and-floor model; the geometry (crossings, angle factors) computed once per (candidate, cell) and the per-band dB applied after (about 3 times less work than Python); MCS table built once; per-level wall culling | golden grids from Python on fixtures, tolerance 0.1 dB |
| `network.py` | `Net` | wired and wireless backhaul, airtime sharing, per-cell client rate, zone scores; cached zone masks and link rates | golden arrangement scores |
| `planner.py`, `explain.py`, `jobs.py` | `Planner` | candidates, representatives (farthest-point sampling), exhaustive for k up to 3 and greedy plus swaps beyond, margin re-score, Pareto; explanation by limiter, leave-one-out, runner-up, stability draws | golden rankings: same top arrangements and scores within tolerance |
| `calibration.py` | `Calibrate` | the ridge/Huber normal-equation solve (at most about 10 to 15 unknowns), hand-written Cholesky or Accelerate | golden fits on synthetic readings |
| catalogue JSON | bundled resource | owner entries are user-added; real models are a content job (open since D12) | decode test |

What is cut from v1: the `guess` placement search (section 3), the web-only CSV import UI (a Files picker later), the ILP bound (not in
Python either), and Metal (optional later; the CPU numbers fit the foreground budget).

## 6. Storage: one document per house

**Layout** (one folder per house, shown as a document package; the same shape as `design.md` section 4's data layout and the server's store):

```
<House>.homemesh/
  house.json              the House (schema_version, revision)
  revisions/<n>.json      the last N revisions (undo, history), pruned
  captures/<id>/          scan.json (the wrapper), doors.json (labels), meta.json
  blobs/<sha256>          USDZ scans (content addressed, deduplicated)
  runs/<id>.json          planner results worth keeping (optional)
```

- **Atomic and crash-safe:** write to a temp file and replace; the revision number increases on every commit; a half-written
  edit never replaces `house.json`.
- **Autosave** on every committed edit (an edit is a gesture end or a form save); revisions are coalesced so a drag is one.
- **Schema versioning:** `schema_version` plus a migration function per step, tested on committed fixtures of every version.
- **Where it lives:** the app's container (Application Support) by default, which the iPhone's own backup already covers. Large blobs
  (USDZ 10 to 200 MB each) are excluded from backup or kept in a Caches-like place only if the owner prefers (question Q8).
- **Settings and the shortlist** move from UserDefaults into the document where they are about the house (shortlist, margin), and stay in
  UserDefaults where they are about the app (units, appearance).

**Backup and multi-device, later, without committing.** Because a house is one self-contained folder, each of these is additive:

| Option | What it gives | Cost and caveat |
|---|---|---|
| **A. Export and import** of a `.homemesh` package (Files, AirDrop, share sheet) | a manual backup; moving to a new phone; handing a house to a helper | simplest; v1 ships with it |
| **B. iCloud Drive document** (the package in the app's iCloud container, `UIDocument`/`FileWrapper`) | automatic copies across the owner's devices; iPad and iPhone | the system's file-version conflict UI is the only merge; two devices editing at once is not supported, only last-writer with versions; moderate work |
| **C. CloudKit** (record-level sync) | real concurrent edit | a per-entity merge design; the most work; not recommended unless two people edit one house |

The document layout above is the same for all three, so choosing A now closes no door. Under Advanced Data Protection both iCloud options
are end-to-end encrypted (verify against Apple's documentation before stating it in any listing).

## 7. What happens to the existing server and web editor

**Recommendation: freeze, then retire in two steps, keeping the Python engine as a test oracle.**

1. **Now to parity: frozen, not removed.** Take no new features in `homemesh/` (server), `web/` or the deployment, except fixes the owner
   asks for and the one-time export in section 8. The deployment stays up so the owner's houses remain editable on the PC until the
   phone app can do the same. (The current iOS work keeps using it.)
2. **At parity** (the phase-5 gate below: every owner house migrated and the phone reproduces its plan results): stop the deployment through the
   owner session (it is owner work), keep one final data export, and archive the web app. The `deploy/`
   directory, the Pocket ID door arrangements and the runner lane are removed in a PR the owner asks for.
3. **Kept for good:** the Python engine (`homemesh/` without the FastAPI layer) and its tests, under `tests/` or a `reference/` folder, as
   the **oracle** that generates the golden vectors. A change to the Swift engine that disagrees with Python is a bug in one of them,
   found by a diff, not by a house. The brief and `design.md` stay as the model's description.

Alternatives considered: *keep the server running as an optional companion* (rejected: doubles the engine to maintain and breaks the
promise of nothing to host), and *retire the Python engine too* (rejected: loses the cross-check that the evaluation names as the
main defence against drift).

## 8. Migrating the existing houses

House data never goes into git or CI; the migration runs on the owner's devices.

1. **Transitional build.** One build keeps the existing client and sign-in and adds "Import this house to the phone": it reads the
   house JSON, the captures (wrapper JSON, door labels, metadata) and the blobs (USDZ) through the endpoints the
   app already uses, writes a local package, and shows a checklist (counts and sizes). No server change is needed except, if
   wanted, a single "export house as one archive" endpoint to make it one request (owner decision).
2. **Verify before trusting it.** The import re-opens the package, decodes it with the typed model, and compares: counts of walls,
   openings, rooms, zones, stairs, labels; the plan of the first arrangement computed on the phone against the server's stored
   result for the same inputs (a tolerance, not equality). Differences are listed, not hidden.
3. **Revisions.** The last N revisions come across (default 20); older history stays in the server's final archive.
4. **Cut-over.** After the owner has used the phone copy for a while, the next build drops the server, sign-in and upload code. The old
   data directory and its backups stay where they are as the archive.
5. **Calibration, measurements and the catalogue shortlist** are part of the house document and come with it.
6. **Blueprints.** Walls that were traced from a blueprint migrate as ordinary walls (their `prov` source is kept as data and nothing reads
   it). The underlays and their images are **not** imported; they stay only in the server's final export archive.

## 9. Phones without LiDAR

**The app expects an iPhone with LiDAR** (owner decision 2026-11-03). There is no install-time gate for LiDAR (the notes), so a phone
without it can still install the app. The design is one honest screen, not a second product:

- When `RoomCaptureSession.isSupported` is false the app shows a single clear screen, **"homemesh needs an iPhone with LiDAR"**, naming
  the supported models (iPhone Pro and Pro Max from the 12 Pro, and LiDAR iPad Pros), and the bundled **demo house** to explore:
  the plan, the 3D view, the planner and its results, read-only. Nothing pretends to work: no Scan, no new house, no import.
- The demo house is the committed synthetic fixtures (all `"synthetic": true`), opened from the bundle and never written to.
- The App Store listing says LiDAR is required, and App Review uses the demo house (review notes explain it).
- Typed-measurement drawing (section 4) stays an editor tool for **fixing scans and filling gaps**; it is not a whole-house route, and
  nothing in the app is built to make a no-LiDAR phone useful beyond the demo.
- An iPad without LiDAR is treated the same way. A LiDAR iPad is a full device.

## 10. Testing, given Swift builds in public macOS CI

The constraint: the agent works on Linux and cannot build Swift; every change goes through the macOS CI job (about 4 to 6
minutes per round) and the owner's phone for anything visual. A Swift-heavy port multiplies that cost, so the strategy is to
**move as much as possible out of the macOS loop**:

1. **Linux-first Core.** `HomemeshCore` is Foundation-only (no `simd`, no Apple frameworks), so it is intended to build and test with the
   open-source Swift toolchain on Linux, locally, in seconds. The Swift download site answers from the agent's host; installing a
   toolchain there is **not tried yet** and is phase 0's first task. If it works, nearly all engine, store and editor-operation
   work gets a local compile-and-test loop and macOS CI is only for the app target. If it does not (a policy or platform problem),
   fall back to macOS CI only and plan the schedule at the multiplier the notes warn of. A Linux CI job for the package is cheap to add either way.
2. **Golden vectors from the Python oracle.** A script (run on Linux, from the synthetic fixtures only) writes JSON files: placement
   transforms, wall imports, loss grids, rates, arrangement scores and rankings, calibration fits. They are committed (synthetic
   data), and Swift tests compare within stated tolerances. A single command regenerates them when the model intentionally changes;
   a diff in review shows what moved.
3. **Port the 2,627 lines of Python tests**, test for test, with the fixture builders (`tests/roomplan_synth.py`) re-implemented in the
   test target so new scenarios do not need Python.
4. **Property and round-trip tests** for geometry and edits: snapping idempotence, apply-then-inverse equals the original, hull and
   clamp invariants, stitching of random room layouts recovers the layout within tolerance, document encode-decode-encode is stable.
5. **App target:** view-models hold logic and are unit-tested; a handful of simulator UI tests cover launch, open the demo house, draw a
   wall, add a door, run a plan. Visual quality and gestures are the owner's checks, listed in each PR as today ("could not check
   without a device").
6. **Performance tests** (`XCTClockMetric`) on the planner and map, with generous thresholds, so a regression of 10 times fails
   CI without flaking on runner speed.
7. **Real-device checks** stay a short, written list per phase (scan, stitching on a real house, thermal behaviour during a long plan).

Risk to say plainly: if the repository ever goes private, Actions stops and the macOS runner goes with it; with a Mac exit as well there
would be no Swift build for the agent at all. Visibility is on hold (section 12), but this is the one technical fact that depends on it.

## 11. Phased plan

Effort figures are the notes' estimates for one experienced Swift developer in developer-weeks and are **not** calendar time for an
agent working through CI; they show relative size. The notes put the MVP at 12 to 16 weeks and the fuller product (manual drawing,
iCloud, iPad, catalogue content) at 20 to 30; this plan makes the editor first-class but without blueprints, room templates or a no-LiDAR route (P3 is 4 to 6 weeks, down from 6 to 8), so it sits in the middle of that range.

| Phase | Content | Exit criteria | Size |
|---|---|---|---|
| **P0 Spikes** | (a) Linux Swift toolchain and a Foundation-only package building in CI; (b) golden-vector generator from Python; (c) a Swift propagation spike timed on the phone against the notes' 1 to 10 s; (d) door-graph layout with loop residual on synthetic houses; (e) one editor interaction (draw a wall with snap and loupe) | each question answered in writing with numbers; the plan below adjusted | 1 to 2 |
| **P1 Core, store, import** | Model, Store (package, revisions, migration), ScanImport; the app opens a migrated or demo house read-only (plan and 3D) from local files | golden parity for import and model; round-trip of every fixture; owner opens a copy of a real house on the phone | 4 to 5 |
| **P2 Stitching and scan flow, local** | Layout (spanning tree, least squares, residuals), the scan, label, place flow against local storage; checklist; accuracy chips | placing the owner's rooms by labels matches the server's result within tolerance; loop residual shown | 2 to 3 |
| **P3 Editor** | EditOps, walls (trace, typed lengths, fill the gap, fixing), doors and windows, zones, stairs, floors; undo; iPad layout | owner fixes a scanned house and fills a gap on the phone; every tool has a list route; unit tests for the operations | 4 to 6 |
| **P4 Simulation and planning** | Sim, Net, Planner, Calibrate, catalogue; progress and cancel; results screens on local results | golden parity on grids, scores and rankings; plan times measured on the phone; thermal check | 4 to 5 |
| **P5 Migration and retire** | transitional import build, verification, cut-over build without server code; archive and retire the deployment (owner session) | all owner houses migrated and verified; server stopped; Python engine kept as oracle | 1 to 2 |
| **P6 Release readiness** | export/import package UI, demo house, onboarding, privacy manifest, diagnostics by share sheet, TestFlight, listing | what a store submission needs; none of it depends on the business model | 2 to 3 |

Order and overlap: P1 before everything; P3's operations (Core) can run alongside P4's engine if work is split, since they only meet in the document; P2
needs P1's import; the phone app shows P4 results only after P1 and P3's document exist. **Throughout**, the current server and web
app stay usable (section 7), so the owner is never without a working tool while the app is rebuilt.

## 12. Neutrality to monetization and licence

Nothing in the design depends on either, and the seams are cheap:

- A single `Entitlements` value (a struct with the features that could be gated, all on by default) is read by the UI, never by the Core. A
  one-time unlock, or ads, or neither, changes only how that value is produced and where a banner could go.
- The Core has no network and no identifiers, so an ad SDK or StoreKit, if ever added, sits in the app target and does not touch the engine, the
  document, or the tests. App Review's privacy statement ("data not collected") is true until the owner chooses otherwise.
- Licence and visibility: the Core is a separate package with its own tests, so it can move or be licensed on its own terms later. The one
  technical dependency is CI (section 10): a public repository keeps macOS Actions free. No code here assumes either choice.

## 13. Open questions for the owner, and the answers (2026-11-03)

Every recommendation was accepted except Q6. The question text is kept; **Decision** lines are the owner's.

1. **Accept the shape?** Core package plus thin app, server frozen then retired, Python kept as oracle. **Decision: yes.**
2. **Accuracy lines:** Good within 0.5 m loop residual, Check to 1 m, Fix first above. **Decision: adopted provisionally; tighten or loosen after the tape readings.**
3. **Is 0.5 m the right line?** A model judgement, not a measurement. **Decision: stands provisionally with Q2.**
4. **Keep "Guess for me"?** **Decision: dropped in the standalone app; labelled doors only, plus drag.**
5. **Floor-to-floor alignment** by staircase footprints only. **Decision: yes.**
6. **Blueprints:** keep as an aid and a no-LiDAR route, or drop? **Decision: DROPPED (2026-11-03).** No import, no fitting, no blueprint tools, no blueprint blobs on the phone. Walls already traced from a blueprint migrate as ordinary walls; the images stay only in the server's final export. Reason: two sources of truth to reconcile, and few users have a usable blueprint. This also changes section 9: the app expects LiDAR, the non-LiDAR route is not a primary path.
7. **iPad:** first-class layout in P3. **Decision: yes.**
8. **Backup:** export/import only in v1 (option A), iCloud Drive (B) after; USDZ blobs included in the phone backup, revisited if size hurts. **Decision: yes.**
9. **Equipment models and material priors:** placeholders, flagged "assumed" as today. **Decision: yes.**
10. **Speed readings without a server:** typed figures only. **Decision: yes.**
11. **Diagnostics:** local event log and MetricKit with a share button, no upload. **Decision: yes.**
12. **Linux Swift spike:** may phase 0 install the open-source Swift toolchain on the agent's host? **Decision: yes, under the agent's own home directory; no sudo, nothing system-wide.**
13. **Mac exit:** **Decision: the Air stays** (the accepted Mac exit plan retires only the Pro and the Mini), so it remains available for device builds and installs; the build loop is still CI first.
14. **Name and bundle id:** **Decision: keep `homemesh` and `com.scshafe.homemesh-capture` for now.**
15. **Migration timing:** transitional import build after P1. **Decision: yes.**

## 14. What this design does not change

This file is the reference for the standalone work. The server, the web editor and the iOS client remain the product until each phase's
gate is met; sections above are copied into `design-ios-app.md` (or a new design file for the package) as they are built, in the
repository's usual "As built" style.
