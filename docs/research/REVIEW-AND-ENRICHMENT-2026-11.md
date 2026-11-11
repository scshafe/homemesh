# homemesh: project review and enrichment ideas (2026-11)

Status: **proposed; do not merge.** Written for the owner to pick from, on the owner's request of 2026-11-09. Nothing here is decided and no
code was changed. Reviewed at commit `1884dbe` (main, "Merge #99"); every `path:line` below is at that commit.

Reviewer: agent-homemesh, running on Claude Fable 5.2 as asked. Method: I read the brief, the three design documents, the engine's planning
path and the configuration myself; two delegated read-only passes covered the iOS app and the engine with its oracle line by line, and I
checked their main citations against the files before using them. No house data was read or used; every example is a synthetic fixture.

## 0. Summary

homemesh did the hard part of its pivot well. In the two weeks after the standalone design was accepted, the Python engine was ported to a
Foundation-only Swift package that agrees with it to 1e-6 dB, the server was retired, and the phone app scans, stitches, edits, plans,
calibrates and exports with no server. The engine and its Linux test loop are the project's strongest asset.

What stands between the owner and a plan worth acting on is not more engine. It is four things:

1. **The plan ranks invented equipment.** The catalogue is three generic devices with made-up numbers; there are no real products, no way
   to add the owner's own, and no Wi-Fi 7 or usable 6 GHz (section 2.3). Three owner questions from 2026-10-20 are still open (D6 devices
   and needs, D12 shortlist and WAN rate, D13 region).
2. **Nothing checks the plan against reality.** Calibration needs dBm readings an iPhone cannot take, the Mac route's CSV import was not
   ported, and the tape-measure accuracy check that sets the stitching thresholds is still pending (section 2.4).
3. **A few sharp edges can lose work or crash on first real use**: the planner traps when a house has fewer allowed spots than nodes asked
   for; unsaved scans live only in memory; a plan's results vanish when the screen is left; a future model change would make every stored
   house disappear from the list (sections 2.2, 2.5, 2.6).
4. **The last phase (P6, release readiness) is not started**, and parts of P2 and P3 exist in the engine but are not reachable from a
   screen (section 2.1).

Grades (A = solid, C = works with real gaps, D = largely missing):

| Area | Grade | One line |
|---|---|---|
| Engine fidelity to the oracle | A- | 1e-6 dB parity; gaps in what the vectors exercise |
| Engine robustness | C+ | one reproduced crash, force casts on stored data, no schema migration |
| Model usefulness for a real decision | C | invented equipment, no interference, calibration impractical on a phone |
| App architecture | C+ | works, but three untyped JSON layers and no view models |
| Data safety | C+ | atomic store and checked export; scans in memory, silent disappearance on decode failure |
| Tests and verify | B- | fast and green in CI; one load-sensitive test, app flows untested, perf tests not in CI |
| Developer experience | A- | Linux loop for the core in about 10 s; macOS CI only for the app |
| Docs | B- | honest "as built" sections; stale server wording and several wrong counts |
| Owner-facing UX | C+ | complete flows; raw ids on screen, nothing can be deleted, metres only |
| Release readiness (P6) | D | export/import and diagnostics exist; nothing else |

## 1. What I ran, and what I could not verify

| Check | Result |
|---|---|
| `./scripts/verify` (168 Python tests) | **Failed once, then passed.** First run, while other sessions loaded the host (load average about 4): 1 failure, `tests/test_place_speed.py:35`, "propose took 1.07 s" against a 1.0 s limit. The same test alone ran in 0.21 to 0.25 s five times. The final run before pushing is reported in the PR. |
| `swift build -Xswiftc -warnings-as-errors`, `swift test` in `core/` (Swift 6.4.2, Linux) | Pass: 45 tests, about 10 s. |
| `swift test -c release` (timing tests) | Pass: loss maps 2.2 s, full plan on `long_thin` 0.85 s. |
| `dev check .` | Clean (exit 0). |
| CI on main | Last run green on 2026-11-06 (all three jobs). A GitHub-side "Dependabot Updates" run for `/web` failed the same day; the directory no longer exists and there is no dependabot file in the repository. |

**Not verified, because it cannot be here:** anything that needs Xcode or a device. I did not build the app, run its tests, or see a
screen. Statements about the app come from reading its source. Specifically unverified: scan behaviour, touch handling and the loupe, the
iPad layout, the Files picker, plan time and heat on a phone, whether the missing icon files warn or fail a local build, and whether the
empty banner in section 2.5 is visible in practice.

## 2. Review

### 2.1 Where the project stands against its plans

Against the brief (`docs/brief.md`):

| Brief point | State |
|---|---|
| Model of the home, several floors, provenance | Done. Scan and manual sources; blueprint and photo sources dropped by decision. |
| Ethernet jacks with type, state and where they lead; entry; outlets | Done in the model and the plan tools. The **switch** has no tool in the app, so "where it leads" through a switch cannot be entered on the phone. |
| Placement rules and coverage needs (zones) | Done. |
| Equipment as data, a catalogue of real models that can grow | **Not done.** Three invented devices in code (`core/Sources/HomemeshCore/Equipment.swift:86-108`); `catalogue/` holds only a README. |
| Simulation per band, walls and floors by material, backhaul, stated assumptions | Done, with limits: no interference of any kind (`Network.swift:6`), 6 GHz capped at 80 MHz (`Network.swift:9`), Wi-Fi 6 at most (`Rates.swift:5`). The "assumptions list shown with every result" of `design.md` 3.7 is not in the app. |
| Calibration against real measurements | Engine done; impractical to feed (section 2.4). |
| Planning: search, rank, explain, compare | Done. Compare is one map with an A / B / difference switch, not side by side (`ios/HomemeshCapture/CompareView.swift:25-46`). |
| iOS capture app | Done and grown into the whole product. |
| Blueprint import; web app on the tailnet | Dropped and retired by owner decisions (2026-11-03, 2026-11-05). |

Against the standalone design's phases (`docs/design-standalone-app.md` section 11):

| Phase | State | Evidence |
|---|---|---|
| P0 spikes | Done | section 15 of the design; the numbers reproduce (`LAYOUT`, `DRIFT`, `BENCH` lines in the test output). |
| P1 core, store, import | Done, minus schema migration | `schema_version` is written and never read (`Model.swift:283-284`, `Normalize.swift:20`); no migration code. |
| P2 stitching | **Half built** | Per-scan placement by labelled doors works. The whole-floor solve (`Layout.swift:64`) has no caller in the app or the API. Accuracy chips, the "doors not labelled yet" counter before planning, name-based label suggestions and "lock this room" are absent; the API already returns `residual_cm` (`LocalAPICaptures.swift:158`) and the app does not read it (`ios/HomemeshCapture/PlanModels.swift:225-227`). |
| P3 editor ("complete") | **Mostly built, less than the design lists** | In the engine but not reachable from a screen: merge, split, move a whole wall (`WallOps.swift:87,60,32`), copy a floor's walls, floor height and slab thickness (`AreaOps.swift:131,148,156`). Absent: multi-select, the edit history list, the floor-below underlay, a floor-opening tool, the switch tool, CSV measurement import, Pencil stroke straightening, VoiceOver moves on handles. iPad has the side panel but the app is portrait only (`ios/project.yml:48`). |
| P4 engine | Done for parity; **not done for the promised runtime shape** | The planner is serial, with no thermal watch; cancel is checked once per (equipment, node count) (`Planner.swift:180`) and no screen can cancel. Phone timings were never measured. |
| P5 migrate and retire | Done (2026-11-05) | |
| P6 release readiness | **Not started**, apart from export/import and the diagnostics file | No privacy manifest, no LiDAR-required screen with a read-only demo (demo houses are copied in editable, `ios/HomemeshCapture/LocalLibrary.swift:19-30`), no onboarding, no `Entitlements` value, no simulator UI tests. |

The design document marks P3 "complete" and its sections 17 and 18 say cancel "is a wrapper in the app". Both overstate; see 2.8.

### 2.2 The engine (`core/`). Fidelity A-, robustness C+

Strengths: propagation and rates match Python to 1e-6 dB; scan import, placement, planner scores and calibration fits all have golden
vectors; the caches are correctly locked (`Network.swift:77-81,115-157`); the package builds with warnings as errors on two compilers.

Findings, most serious first:

1. **The planner crashes when there are fewer candidate spots than nodes asked for.** With one single-point allow zone and `k_max` 2,
   `Planner.search` indexes `final[0]` on an empty list (`Planner.swift:183-190`) and the process traps. The engine reviewer reproduced it
   with a probe test in a scratch copy. The API's default `k_max` is 5 (`LocalAPIPlans.swift:25`) and it only checks that an allow zone
   exists (`:51`), so an owner who marks one shelf as the only allowed spot can hit it. Python has the same defect
   (`homemesh/planner.py:205`): **the oracle and the port agree on a bug**, which is the failure mode the oracle cannot catch.
2. **Wired backhaul has no parity coverage.** In `Golden/plans.json` every backhaul entry is `gateway` or `wireless` (36 and 79; I
   counted), `jacks_used` is always empty, and the "unknown jack trusted" run equals the untrusted one. `Backhaul.wiredAt` and the switch
   chain (`Network.swift:181-201`) are the brief's "wired where a jack allows" and are untested against the oracle. The 20 Python tests in
   `tests/test_network.py` have no Swift counterpart. The greedy search, multi-floor plans, invalid arrangements, a price ceiling and any
   6 GHz radio are likewise never exercised by a Swift test.
3. **No schema migration, and a decode failure hides the house.** `HouseStore.load` uses the strict decoder (`Store.swift:43-47`); the API
   turns any load failure into "404 no such house" (`LocalAPI.swift:41-45`) and the summary skips it (`:119`). Adding one non-optional
   field to the model would make every stored house vanish from the list. Unknown fields are dropped on save, the opposite of the design's
   "unknown fields preserved" (section 5). This matters now: the owner's real house is on the phone and its only other copy is a manual export.
4. **Stored data is force-cast.** `as! String` and `as! Int` on the scan index (`LocalAPICaptures.swift:80-83,110,122,152`), unchecked
   pair indexing (`LocalAPI.swift:177`, `LocalAPICaptures.swift:182,188`). A malformed imported package passes import (only `blob` is
   validated, `LocalAPI.swift:226`) and traps later in the doors checklist.
5. **Quiet differences from Python that no vector sees.** A zone target of 0 Mbit/s: Python treats it as unset, Swift divides by zero
   width (`Network.swift:325` against `homemesh/network.py:376`), and `Explain.swift:50-51` disagrees with `Network.swift` inside the Swift
   code. Staircase candidates are scored in Python and not in Swift (`Placement.swift:199-202` against `homemesh/place.py:523-530`). The
   arch-label fix exists only in Swift, so neither side tests it.
6. **Runtime shape promised in design section 2 is absent.** No parallelism or thermal watch anywhere in `core/Sources`; the explanation
   phase (5 results, 12 perturbed contexts each) cannot be cancelled; finished jobs are never removed and never written to disk
   (`LocalAPIPlans.swift:58`; the design's `runs/<id>.json` does not exist); one lock is held for a whole request including rate maps and
   calibration (`LocalAPI.swift:78`). The promised geometry reuse across bands and wall culling are not done (`Propagation.swift:117-151`).
   Desktop times are fine (0.85 s for a plan); nobody knows the phone's.
7. Small: a dead ternary (`Network.swift:187`, a switch's port count is never used); two enums for the same thing (`Standard` in
   `Equipment.swift:6`, `WifiStandard` in `Rates.swift:5`); `House.region` is stored and read by nothing.

### 2.3 Usefulness of the model for a real decision. Grade C

The physics is a defensible multi-wall model and says what it leaves out. Three gaps limit what a ranking means today:

- **Equipment.** Every plan compares `generic-mesh-ax` with `generic-mesh-tri`, at invented prices. The Swift side has no catalogue
  loader at all (`LocalAPI.swift:205-213`; plans always use `Catalogue.generic()`, `LocalAPIPlans.swift:35,54,101`), so even hand-written
  entries cannot be used. The client is one of two generic profiles.
- **Wi-Fi generation.** Standards stop at `ax`; MCS stops at 11; no 320 MHz, no multi-link. No generic radio uses 6 GHz. Systems on sale
  now are largely Wi-Fi 7 tri-band, which the model cannot describe.
- **Interference.** `design.md` 3.5 specified self-interference and a channel reuse plan. The code models neither
  (`Network.swift:6`, `homemesh/network.py:18`). For "how many nodes" this biases toward more nodes, since an extra node never costs anything
  but price. The explanation also names the largest obstruction on 5 GHz whatever band serves the zone (`Explain.swift:77`).

### 2.4 Calibration and accuracy: the loop that is not closed. Grade C

- The fit works and matches Python. Its input is a typed dBm figure at a tapped spot. iOS gives an app no RSSI, so the owner needs another
  instrument. The decision of 2026-10-20 (D8) was a Mac laptop walk; the CSV import that carried those readings was web-only and is "not
  ported" (design section 17). Until readings exist the margin stays at 6 dB and every material is a prior marked unsourced.
- Stitching thresholds (0.5 m good, 1 m check) were adopted "provisionally; tighten or loosen after the tape readings" (section 13, Q2 and
  Q3). The measure-check screen exists (`ios/HomemeshCapture/MeasureCheck.swift`); the readings are owner work and still pending. One
  string there still advises keeping "the blueprint as the underlay" (`MeasureCheck.swift:63`).

### 2.5 The app (`ios/`). Architecture C+, UX C+

Architecture:

1. **Three untyped representations of one house.** The engine has a typed `House`. The app reaches it through path strings and
   `[String: Any]` JSON (`LocalAPI.swift:77-112`), decodes the answers into hand-kept structs (`Models.swift`, `PlanModels.swift`,
   `PlanRun.swift:4-84`), and edits a third form, `HouseDoc.root: [String: Any]` (`HouseDoc.swift:11,100-136`). About 25 call sites build
   paths by interpolation. This was the right bridge while the server lived; now it is an in-process HTTP imitation whose contracts the
   compiler cannot see. The only check that the app's structs match the API's real output is three calls in `LocalLibraryTests.swift`; a
   renamed key in `LocalAPIPlans.serialise` would pass CI and fail on the phone as "Unexpected answer from the server".
2. **No view models.** `PlanScreen.swift` is 1,031 lines with 28 `@State` values (`:36-63`); each screen refetches and decodes the whole
   house. Almost none of the app's flows can be unit-tested as a result (section 2.6).
3. **Async that is not.** `Client.call` is `async` around a synchronous `api.handle` (`Client.swift:11-12`), so the 10-second placement
   timeout cancels a task that cannot notice (`PlaceView.swift:199-205`); the "took too long" path is dead.

Things that lose work:

4. **Unsaved scans exist only in memory** (`ScanScreen.swift:23-24`). A crash, a RoomPlan hang (the README documents them) or memory
   pressure loses every room since the last Save. Back dismisses with no confirmation (`:170`).
5. **Plan results are `@State`** (`PlanRun.swift:105`): leaving the screen discards a finished plan, and the polling task keeps running.
   There is no Cancel.
6. **Edit race.** Each edit saves from the document captured at tap time and reloads afterwards (`PlanScreen.swift:653-660`). A second
   edit before the reload gets a revision conflict and is dropped with "Could not save".
7. **Undo restores the whole house one revision back** (`PlanScreen.swift:633-650`), so it can revert a calibration or a placement made on
   another screen; only 20 revisions are kept; there is no redo.

Rough edges the owner will meet:

8. **An empty banner after each load**: `note = .info("")` (`HouseView.swift:185`, `DoorLabels.swift:296`) and any non-success message
   renders a banner (`Sui/SuiFeedback.swift:80-81`). Probably meant to be `nil`.
9. **"Guess for me" does nothing.** The button sends `guess=true` (`PlaceView.swift:145,200`); the route ignores it (`LocalAPI.swift:108`).
   The design dropped the search; the button and the README line stayed.
10. **Nothing can be deleted or renamed**: no delete for a house, scan, room, floor or reading; no rename for a house or floor. The API
    has no delete route.
11. **Raw identifiers on screen**: `cat5e`, `coax_moca`, "Wall w12", "Router: generic-router-ax", material ids
    (`PlanScreen.swift:256,261,699-700`, `PlanRun.swift:166`, `Calibrate.swift:134`).
12. **Metres and dollars only**, though the default region is "US" and decision D3 was "configurable per user". No localisation; a house
    name without ASCII letters is refused (`Models.swift:125`).
13. **Endless spinners** when a load fails on the plan, 3D and placement screens (`PlanScreen.swift:130`, `House3D.swift:128`, `PlaceView.swift:154`).
14. **A `.homemesh` file cannot be opened into the app** from Files or AirDrop: no file type is declared, and import accepts any file (`HousesView.swift:46`).
15. **The shortlist is in UserDefaults** (`Catalogue.swift:46-54`), so it is not in an export, against design section 6.
16. **The icon files are git-ignored** (`*.png`) and neither CI nor the README's install steps run `ios/icon/build`.

Leftovers from the server (cosmetic, but they mislead a reader): `AuthTests.swift` is 796 lines of about 40 unrelated test classes and no
auth test; `Uploader` is a local save whose `Failure` type is the app's general error; user-visible "server", "uploaded" and "Downloading"
strings (`HouseDoc.swift:15`, `HouseView.swift:232,290`); `LeftoverScans` migration runs at every launch; the target, scheme and module are
still `HomemeshCapture`. The `scshafe-ios` package is not a dependency: `Sui/` is still local code (348 lines) though the package now has a
`v0.1.0-rc.1` tag with the same components.

### 2.6 Tests and verify. Grade B-

- **Good:** one command, 168 Python tests in about 7 s when the host is idle, 45 Swift tests in about 10 s, golden vectors guarded against
  staleness, a replay of 62 recorded API calls.
- **A test that fails under load guards a dropped feature.** `tests/test_place_speed.py` asserts wall-clock under 1.0 s on the `guess`
  search, which the app no longer has. It failed once in this review (section 1). A verify that can fail for an unrelated reason teaches
  everyone to re-run it.
- **The Swift suite is a quarter of the promised port.** Design section 10 promised the Python tests ported test for test with the fixture
  builders in Swift, property tests, and `XCTClockMetric` performance tests. There are 45 tests against 168, no port of
  `tests/roomplan_synth.py`, one property-style test (layout stitching), and two timing tests that run only in release builds, which CI
  never does (`.github/workflows/ci.yml:57,83`); their limits are about 30 times the measured times (`PerformanceTests.swift:48,62`).
- **The API replay is frozen and unguarded.** `Golden/api_session.json` is one 200 kB line that nothing can regenerate and
  `tests/test_golden.py` does not check. Any intended change to an API answer means editing it by hand or widening the ignore list
  (`LocalAPITests.swift:34`), which already skips every score and message text.
- **Swift-only code has no oracle and thin tests**: the editor operations (15 example tests), `Layout`, `HousePackage` (2), the store (5).
  This share grows with every feature, while the Python oracle covers a shrinking part of the product.
- **The app target tests logic helpers only.** Untested: plan edit, save, undo and conflict; the plan run; placement; scan save across
  sessions; export and import; calibration apply. There are no UI tests.
- **Dead oracle code**: `homemesh/captures.py`, `seed.py`, `plan.py` and most of `jobs.py` have no importer; the `guess` search in
  `place.py:543-575` lives only for its own tests.

### 2.7 Developer experience. Grade A-

The Linux toolchain decision paid off: engine work has a 10-second loop and macOS CI is needed only for the app. Remaining friction: the
app can only be judged by the owner on a phone, one PR at a time; nothing produces a picture of a screen for the agent or the owner to
look at; `dev.toml` still calls the project a `service` with `docker = true` (`dev.toml:45`) though nothing is deployed; the CI header is
service template text.

### 2.8 Docs. Grade B-

The "as built" habit is good and mostly honest. Drift found:

- `design-standalone-app.md`: "P3 status: complete" (line 383) against 2.1; "61 requests" (line 519; there are 62 records); "Seventeen
  scenarios" (lines 486-487; there are 15, 20 steps); "Not ported yet: ... suggestions, rate-map serialisation" (line 512; both exist);
  parity on "backhaul chains" with "a wired and an untrusted jack" (lines 503-504) against 2.2 item 2; storage layout
  `captures/<id>/` (line 261) against the flat files in `Captures.swift:4-5`.
- `ios/README.md`: "the server imports", "while the server works", "Guess for me runs the old search" (lines 122-126); the tool list
  omits Walls, Doors and windows, Measure and Fix; it prints a development team id (line 25), stated there as not secret, which the owner
  may still prefer out of a public file.
- `core/README.md` lists 5 of 29 source files. `catalogue/README.md` describes a loader, a test and a data directory that exist only in
  Python. `LocalAPI.swift:3-5` cites `homemesh/api.py`, which is gone.
- There is no single page that says what is built, half-built and not built. The three design documents are layered history, and
  `AGENTS.md` rightly says to read two of them as such.

### 2.9 What blocks the owner from getting value today

In order:

1. No real equipment to plan with, and open answers on devices, WAN rate and region (2.3).
2. No practical way to calibrate, so results carry a 6 dB margin and unsourced materials (2.4).
3. The planner crash on a small allowed area, and no way to cancel or keep a result (2.2, 2.5).
4. Scan work at risk until Save; no delete or rename to clean up after trial scans (2.5).
5. Every app change waits on the owner's phone for any visual check (2.7).

## 3. Enrichment ideas

Effort: **S** about one PR, **M** two to four PRs, **L** a phase. "Owner decision" marks a real design question; everything else is
planned work under the standing order. Ideas are numbered for reference and ranked in 3.3.

### 3.1 Quick wins

| # | Idea | Value | Effort | Risks and dependencies |
|---|---|---|---|---|
| Q1 | **Guard the planner**: skip node counts above the number of spots, validate zero targets and unknown gateway, in both engines, with golden cases | removes the one reproduced crash before the owner finds it | S | both engines change together; vectors regenerate |
| Q2 | **Never hide a house**: read stored houses leniently, show an unreadable one as a row with "cannot be read, export it", add a `schema_version` check and an empty migration table with a version-1 fixture | protects the only copy of real data from the next model change | S | none; do before any model field is added |
| Q3 | **Keep and cancel a plan**: write the last result to `runs/`, reopen it on the Plan screen, add Cancel, check the flag inside the search loops, evict finished jobs | a finished plan survives leaving the screen | S-M | device check for the feel |
| Q4 | **Scan safety**: write each finished room to disk as it is captured, restore after a crash, confirm on Back and Discard | no lost scanning sessions | M | needs a device run; touches the scan controller |
| Q5 | **Fill the vector gaps**: wired backhaul through a switch, greedy search, two floors, an invalid arrangement, a 6 GHz radio, the arch label (fixing Python) | parity where the brief's backhaul claim lives | S-M | may reveal real differences; that is the point |
| Q6 | **Make verify trustworthy**: remove the `guess` search and its timing test from the oracle (or mark the timing loose), run the release timing tests in CI with limits near 5 times measured | no false failures; a real regression alarm | S | deleting oracle code is easy to reverse |
| Q7 | **Small fixes sweep**: empty banner, dead "Guess for me", dead timeout, endless spinners, save-race (queue saves), force casts to validated reads | removes daily irritations | S | none |
| Q8 | **Show what the engine already knows**: accuracy chips from `residual_cm`, an unlabelled-doors count on the house and before planning, the assumptions list with each result | finishes P2's visible half cheaply | S-M | thresholds are provisional until the tape readings |
| Q9 | **Delete and rename** houses, floors, scans, readings (with confirmation; export offered first for a house) | basic housekeeping | M | deletion needs a recoverable path (revisions cover the document, not blobs) |
| Q10 | **Declare the `.homemesh` file type**, open from Files and AirDrop, move the shortlist and plan settings into the document | export becomes a real backup and hand-over | S | none |
| Q11 | **Readable names and units**: labels for jack types, materials and equipment; a feet-and-inches setting; local currency | the app reads as a product; matches decision D3 | M | wording is the owner's to approve |
| Q12 | **Contract test for the app's structs**: decode the API's real answers (plans, rate maps, calibration, placement) in the app tests | catches a renamed key in CI, not on the phone | S | superseded by B3 if that is taken |
| Q13 | **Docs truth pass**: one status page (built, half-built, not built), fix the counts and server wording, rename `AuthTests.swift` and `Uploader`, refresh the two READMEs | a reader can trust the docs again | S | none |
| Q14 | **Adopt `scshafe-ios`** in place of the local `Sui/` folder now that it has a release candidate | one design system, less code here | S-M | its tag is a release candidate; macOS CI only; gaps would need an ask to that project, which is not among this agent's request targets (owner to route) |
| Q15 | **Housekeeping for the owner session**: switch off the GitHub-side dependency updates for `/web`; review `dev.toml` kind `service` and `docker = true` now that nothing is deployed | quiet CI page, accurate fleet records | S | fleet files are owner-session work |

### 3.2 Bigger bets

**B1. A real equipment catalogue, on the phone.** Bundle `catalogue/*.json` as a resource with a Swift loader; let the owner add and
edit their own devices in the app (stored with the house or the app, exported with the house); extend the model to Wi-Fi 7 (wider
channels, higher MCS, a first-order multi-link rule), real 6 GHz, and region limits read from `House.region`. Value: the ranking starts
to mean "buy this". Effort: L (loader and UI M, Wi-Fi 7 rate model M, content ongoing). Risks: vendors rarely publish antenna gain or
power per band, so entries stay "assumed"; a wrong spec misleads more than a generic one. **Owner decisions:** the shortlist, budget and
WAN rate (D12), region (D13), main client devices (D6), and how simple the multi-link rule may be.

**B2. A calibration route that works with what the owner has.** Options, not exclusive: (a) port the CSV import as a Files picker so a
Mac laptop walk feeds the fit, as decided in D8; (b) accept readings from the Shortcuts app, whose network-details action reports signal
strength on recent iOS versions (**to verify on the owner's phone before any design**), through an App Intent that attaches a reading to
the spot last tapped; (c) calibrate from typed speed-test results, which needs the MAC-efficiency fit that `design.md` 7.4 left undone;
(d) a guided walk that says where to stand next from the existing suggestions. Value: replaces the 6 dB blanket margin with the house's
own error, the single biggest gain in trust. Effort: M for (a) and (d), M for (b), M for (c). Risks: (b) may not exist or may be coarse;
position by tapping is slow. **Owner decision:** which instrument, and how many readings are tolerable.

**B3. A typed engine interface.** Replace path strings and `[String: Any]` with a typed `HouseService` in the core (methods that take and
return model values), move the app's screens to it one at a time, and keep the JSON router only as a test adapter for the recorded
session until that file can retire. Value: the compiler checks every screen's contract; `HouseDoc`'s dictionary layer and the duplicate
structs go away; view models become natural. Effort: L, in slices, each compilable on Linux for the core half. Risks: wide churn in the
app that only macOS CI and the phone can check; do it screen by screen. **Owner decision** only on priority: it adds no feature.

**B4. Pictures of the app without a phone.** Add view models for the main flows and a small simulator UI-test set on the demo houses
(open, plan screen, run a plan, results, compare, 3D), saving screenshots as CI artifacts in light and dark, iPhone and iPad. The agent
can read those images and review its own UI changes before asking the owner; the owner can glance at a PR instead of installing a
build. Value: shortens the slowest loop in the project and finally tests the flows in 2.6. Effort: M. Risks: simulator flakiness and CI
minutes (the macOS job is already about 4 to 10 minutes); RoomPlan screens stay device-only. Demo houses are synthetic, so no house data
reaches CI.

**B5. "What I have now" against the best plan, and a plan to act on.** Use the existing access point as a baseline arrangement in every
result ("today: office 40 Mbit/s; best plan: 310"), and add a one-page shareable summary of a chosen arrangement: where each node goes on
the plan, which jack each uses, which unverified jacks to test first, what was assumed. Value: this is the product's deliverable, and the
baseline makes every number relative to something the owner can feel. Effort: M. Risks: the summary contains the house layout, so it is
shared only by the owner's own action; a PDF renderer is app-side and needs device checks.

**B6. Finish the stitching story.** Wire `Layout.solve` in as "re-solve this floor" with loop residuals, "lock this room", nudge by
5 cm, and block "Plan a mesh" behind "plan anyway" on a Fix-first floor, as section 3 of the design describes. Value: the map's accuracy
becomes visible and fixable instead of assumed. Effort: M. Depends on the tape readings to set the lines. Risk: re-solving moves rooms
the owner placed by hand, so locks and undo must come first.

**B7. Model fidelity where it changes the answer.** In order of likely effect: self-interference and a channel plan (already specified
in `design.md` 3.5), doors open against closed as two scored scenarios, large metal furniture as obstacles (RoomPlan already reports
refrigerators and the app keeps them as a layer), expected client count per zone. Value: stops "more nodes is never worse". Effort: M
each. Risks: each adds parameters nobody has measured; take them only after B2 shows where the residuals are. **Owner decision:** which,
if any, and whether Python stays the oracle for them.

**B8. The planner's promised runtime shape.** Parallel scoring, geometry reuse across bands, fine-grained cancel, a progress fraction, a
thermal check, and an in-app benchmark that writes plan time and thermal state to the diagnostics file. Value: known, bounded plan time
on the phone, which matters once B1 multiplies the equipment list. Effort: M. Risk: parallel code against shared caches; the caches are
already locked. Needs one device run to produce the first real numbers.

**B9. Release readiness (P6).** Privacy manifest, the LiDAR-required screen with a read-only demo, onboarding, the `Entitlements` seam,
TestFlight. Value: needed only if the app goes beyond the owner's phone. Effort: M. **Owner decision:** whether and when; monetization and
licence are still on hold by the owner's direction.

**B10. iCloud Drive document (option B of design section 6).** Automatic second copy and iPad use. Effort: M. Risk: conflicts are
last-writer; needs entitlements and the paid team. **Owner decision** (already deferred to "after v1").

**B11. Voice-labelled continuous scan** (recorded under "Later" in `design-ios-app.md`). Fewer taps per room. Effort: L, device-heavy.
Not before the scan-safety work (Q4).

**B12. The oracle's future.** Python covers physics, import and placement; the editor, layout, package and API are Swift-only and
growing. Choices: (a) keep Python as the oracle for physics only, delete the rest, and invest in property tests and a Swift port of the
synthetic-scan builders for everything else; (b) keep extending Python for each new model feature; (c) freeze the vectors and retire
Python once B2 gives a real-world check. Value: clarity on where a new feature's test comes from. Effort: S to decide, M to carry out
(a). **Owner decision.** My recommendation is (a).

### 3.3 Ranking

Ranked by value to the owner per unit of effort, with safety first:

| Rank | Idea | Why here |
|---|---|---|
| 1 | Q1 + Q2 + Q3 (crash guard, never hide a house, keep and cancel a plan) | cheap; each prevents a loss or a crash on real data |
| 2 | B1 real equipment catalogue (start with the loader and the owner's own devices) | the largest gap between the tool and the brief |
| 3 | B5 baseline and a plan to act on | turns a ranking into a decision |
| 4 | B4 screenshots in CI | speeds up every later app change and adds the missing flow tests |
| 5 | B2 a workable calibration route (CSV first) | replaces assumption with measurement |
| 6 | Q4 scan safety | protects the most laborious input |
| 7 | Q5 + Q6 vector gaps and a trustworthy verify | keeps the oracle meaningful |
| 8 | Q7 + Q8 + Q10 fixes sweep, accuracy chips, file type | visible polish at low cost |
| 9 | B3 typed engine interface | removes the main structural risk; best started before more screens are added |
| 10 | B6 stitching story | after the tape readings |
| 11 | Q9, Q11, Q13, Q14, Q15 | housekeeping, in any order |
| 12 | B8, B7 | after B1 and B2 show the need |
| 13 | B9, B10, B11 | only on the owner's word |

### 3.4 Where a newer model helps

For the agent's own work (no change to the product, nothing leaves the phone):

- **Mechanical ports with a checker.** The 123 Python tests without a Swift twin, the synthetic-scan builders, and the typed interface of
  B3 are large, rule-bound and compile on Linux. This is work a stronger model does in fewer, larger correct steps; the golden vectors
  say immediately when it is wrong.
- **Reading screenshots** (B4): reviewing the app's own screens in light and dark, phone and tablet, before the owner sees them.
- **Catalogue drafting** (B1): turning public spec sheets into entries with their sources and "assumed" flags, for the owner to accept.
  The risk is a confident wrong figure, so each entry needs its source link and a human look.
- **Adversarial synthetic houses**: generating odd but valid plans (zero-area zones, one-spot allow zones, loops of doors, three floors)
  as fixtures. Finding 2.2 item 1 is exactly this kind of case.
- **Differential review** of oracle against port, as in this review's 2.2 item 5, on every engine change.

In the product, each an **owner decision**, because `design.md` 5.5 says explanations are generated from the numbers with no language
model, and the app's promise is that nothing leaves the phone:

- An on-device language model (the system one on recent iPhones; availability to verify) could reword the deterministic explanation into
  plainer prose, with the facts and numbers passed in and shown beside it. Risk: it restates a number wrongly; mitigation is to keep the
  numeric table as the authority.
- Door-label suggestions from room names and geometry need no model; a simple rule does it (design section 3.2 already asks for it).
- I do not recommend any cloud model call from the app.

### 3.5 Decisions this document would put to the owner

1. Pending from before: the tape readings (stitching thresholds), D6 devices and zone needs, D12 shortlist, budget and WAN rate, D13 region.
2. B1: scope of the Wi-Fi 7 model and whether owner-added devices live with the house or the app.
3. B2: which calibration instrument (Mac CSV, Shortcuts if it works, speed tests).
4. B3: whether to spend a phase on the typed interface now.
5. B7: which fidelity terms, if any.
6. B9 to B11: release, iCloud, voice scan: whether and when.
7. B12: the oracle's future.
8. Q14 and Q15: routing an ask to `scshafe-ios`, and the fleet records for this project.
9. Whether the development team id should stay in `ios/README.md`.
