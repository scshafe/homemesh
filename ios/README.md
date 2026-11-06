# homemesh (iOS)

The standalone iPhone app: scan rooms with Apple RoomPlan, fix the plan with the touch editor, plan a Wi-Fi mesh. Houses live
on the phone and nothing is sent anywhere; there is no server, no account and no analytics (the server was retired on
2026-11-05, see `docs/design-standalone-app.md`). The engine is `core/` (HomemeshCore, Swift); the screens talk to it through an
in-process version of the old server's API (`LocalAPI`).

## Status

CI (`.github/workflows/ci.yml`, job `ios`, macos-26 / Xcode 26) generates the project with XcodeGen, builds the app with warnings as
errors for an iPhone simulator and runs the unit tests in `HomemeshCaptureTests` and the core package's tests. CI cannot scan:
RoomPlan needs a LiDAR sensor, so the scan, the touch editor, the Files app and everything else on the screen are checked by hand
on a phone; each PR says what it could not check.

## Build and install on an iPhone (owner, on the MacBook Air)

`ios/project.yml` is unsigned (empty `DEVELOPMENT_TEAM`) so CI can build it. To
run on a phone, sign it with your team in a local spec that Git ignores. Signing
works only from the Air's own GUI session, so you press Run in Xcode there.

1. In a clone on the Air: `git pull`; `brew install xcodegen` if needed.
2. Write the local spec (the team id is not a secret):
   ```sh
   cp ios/project.local.yml.example ios/project.local.yml
   # set DEVELOPMENT_TEAM: FAZW6QRN35
   xcodegen generate --spec ios/project.local.yml
   open ios/HomemeshCapture.xcodeproj
   ```
   Always generate from `project.local.yml`; generating from `project.yml` makes
   an unsigned project again. If another team already holds the bundle id
   `com.scshafe.homemesh-capture`, set `HOMEMESH_BUNDLE_ID` in the local spec.
3. Plug the iPhone in, unlock it, tap **Trust**; turn on Developer Mode
   (Settings, Privacy & Security, Developer Mode) and confirm after the restart.
4. In Xcode choose the iPhone as the run destination and press Run (Cmd-R). The
   first run prepares the phone for development (a few minutes).
5. If the first launch says "Untrusted Developer": Settings, General, VPN &
   Device Management, your team, Trust; then Run again.
6. Open the app. There is nothing to set up: create a house, or look around the demo house (Settings).

**Needs a LiDAR iPhone** (Pro models and some iPads). On a device without LiDAR
the app installs and opens, but "Start scanning" is disabled and it says "This
device has no LiDAR scanner."; nothing can be scanned from it.

## Use

1. Settings (the gear): the demo house, and the diagnostics file to share. The houses list's **+** creates a house or imports one from Files.
2. Houses: pull to refresh; **+** creates a house. Opening a house shows its floors, each with its rooms
   (name, description, on the plan or not), and **Add room scan** at the top.
3. Add room scan: pick the floor, scan a room, Done, and give the room its name in the field that appears
   (one field per room, required before Save; suggestions are in a room's details). Scan more rooms of the
   same floor, then Save. Rooms of one scan share a frame. Messages appear under the camera view if tracking is limited or no walls are
   detected after 15 seconds. Tap a room in the house to rename it, describe it, change its floor (this moves
   every room of that scan), see its 3D model (Quick Look) or place it on the plan.
4. Walls: open a floor's "Plan of <floor>: walls and materials" in the house, tap a wall, and set its thickness and
   material (or use them for every wall on the floor still on the defaults), change or delete its openings. The same
   inspector has the **measure check**: type what a tape says for the wall; the house keeps the difference, and
   "Accuracy" (in the house list) shows the mean error against the 2 % / 3 cm bar from docs/design-ios-app.md.
   The plan has a tool bar: Select, Outlet, Jack, Access point, Internet (where the line comes in, with the provider's speeds), Stair and Zone. Tap the plan with a tool to put the thing
   there and set its details below (a jack's type and whether it works and carries PoE, an access point's height
   and power); Select edits or deletes what you tap. A staircase is two taps (bottom, then top) after choosing the
   floor it leads to; it joins the two floors in the Wi-Fi model as an open path.
   Zones: choose where a node may go, where it must not, or where signal is needed, tap the corners, Finish, and
   set the details (minimum dBm, whether it must be met, mounts and heights). "Equipment to plan with" in the house
   lists the catalogue (tap for radios, ports, price and where the numbers come from); tick the shortlist or use every
   mesh system, pick the router, the client device and how many extra nodes at most. It is kept on the phone.
   **Plan a mesh** (in the house): it tells you what is missing (the internet entry, an allow zone, a demand zone), then
   "Find the best arrangements" runs the plan with your shortlist and shows the progress. Results are ranked best first
   with badges (best trade-off, misses a must-have, unstable ranking); open one for why it ranks there, where its nodes
   go, how each zone fares and how the nodes connect, and "Show the signal on the plan" for the client-speed map by floor.
   Tap the circle on two results to **compare** them: the signal maps (A, B, or where one is faster) and a table of
   score, cost, worst zone and each zone's utility.
   **Calibrate**: put your existing access point on the plan, then walk the house: with the Measure tool tap where you
   stand and type the signal you read (a negative number such as -62, and the speed if you ran a test). "Calibrate to my
   measurements" fits the model, shows the typical error on readings it has not seen, which wall materials the walks pinned
   down (and the values they moved to), readings that look wrong, good places to measure next, and the planning margin
   before and after; Apply saves it so later plans use it.
   **Saving**: Save puts the scan straight into the house on the phone. If that fails the rooms stay on the screen. Scans an earlier
   build left in Files (homemesh, Uploads) are saved into their house the next time the app opens.
   **Export and import**: a house's menu has "Export to Files…" (one `.homemesh` file, read back and checked), and the houses list can
   import one; nothing is overwritten and the counts are compared.
   **Undo** (top right of a floor's plan) goes back to the plan as it was before the last change; press again to go further
   back. Nothing is lost: the earlier versions stay in the house's history.
   **3D view of the house** (SceneKit): walls at their floor's height, a slab per floor and the staircases; drag to turn,
   pinch to zoom, and hide floors with the buttons below. Each room's own scanned model is in the room details.
   **Accessibility**: the controls have VoiceOver labels; the plan drawing is described in words and a wall can be chosen
   from a list as well as by tapping; text follows the system text size.
   A scan gives no wall thickness or material: set them in the editor.

## Look

iOS 26 and later; light and dark follow the system. Colours, status tones (always a symbol and text), banners, toasts
and empty states live in `HomemeshCapture/Sui/` so they can move to the `scshafe-ios` package. The app icon's layers are
in `ios/icon/` (`./icon/build` flattens them into the asset catalog; needs `rsvg-convert`).

## Debugging a scan

- Xcode's Run turns on Metal API validation and GPU frame capture by default. The scheme in `project.yml`
  switches both off (`enableGPUValidationMode: false`, `enableGPUFrameCaptureMode: disabled`) so a Run behaves
  like a launch from the home screen; an earlier freeze at the start of the second room was a pause on the
  renderer thread (`Render`, `__pthread_kill`, console line about `tonemapLUT`) under validation. If it still
  freezes, launch the app from the home screen after installing, and send the console text.
- One scan view and one AR session live for the whole multi-room scan; between rooms the session stops with
  `pauseARSession: false`, so rooms share one frame. Building the upload (combine, encode, USDZ) runs off the
  main thread.
- The screen stays awake while a room is being scanned (idle timer off from start to stop; released on stop, error, leaving the screen and when the app is backgrounded).
- One RoomPlan session cannot grow forever ("Capture scene exceeded limit", then a hang). A session is renewed
  after 2 rooms or 4 minutes of scanning (the app says so); on RoomPlan's size limit the room scanned so far is kept, the screen says the session was full and offers "Start a new session"; on any other session error, or a start/stop that does not
  finish (8 s / 45 s), the session is shut down, the room scanned so far is kept when RoomPlan can still build it,
  and the next room gets a new camera view, session and frame. Each session uploads as its own scan, so the rooms of
  different sessions are placed one by one by the usual placement step.
- The scan screen is the camera, edge to edge; Back, Save, the hint, the room names, the floor picker and
  Start/Done float over it on glass (Liquid Glass). The AR session starts as soon as
  the screen (or a renewed session) is up so the camera is never dark; if frames do not arrive, or camera access is
  off, the screen says why with a Retry, and the event log records it (`preview`, `camera`).
- Staircases: the save sheet says what RoomPlan found ("8 walls, 2 doors… Staircase found: rises 3.3 m") and asks which
  floor the staircase leads to (default: the floor whose height fits the rise); it is stored on the scan and saved with
  the placement. A scan already uploaded whose staircase has no floors yet shows under "Staircases" on the house screen.
  "Scan a staircase" (next to Add room scan) picks the two floors first and uploads a staircase scan, listed under
  Staircases to place on the plan.
- The scan screen shows a one-line tip before the first room (slow at corners, keep the wall-ceiling line in view). Walls with a non-rectangular outline (sloped or vaulted ceilings) are drawn with that outline in the 3D view; curved walls arrive as chords.
- Furniture (what RoomPlan saw in a room: sofas, tables, shelves, appliances) is a layer: orange boxes (movable, dashed) and brown (fixed) on the plan and in the 3D view, listed on each room's screen. Tap one to name it and say if it can be moved; the category sets the start (sinks, toilets, ovens… fixed) and your choice is kept when the room is scanned again. It does not affect the Wi-Fi model yet.
- A session that spans stories (RoomPlan reports each room's story): the save sheet shows a floor picker per story (the lowest on the floor you chose, the others stacked above, changeable); the server imports each room on its floor with the one placement, and the rooms list shows each room on its own floor.
- Stairs are drawn as steps on the plan and in the 3D view (RoomPlan itself only models a staircase as one block): the count is round(rise / 0.18 m) unless you type a number of steps on the staircase; the arrow points up, and "turn the flight round" swaps the ends when the bottom was guessed wrong (it is taken from the end nearer a door in the stairs scan, else unknown). While scanning stairs a banner says "Staircase found: rises X m" as soon as RoomPlan sees them. Steps are visual only; the Wi-Fi model uses the stairwell opening.
- Placing a scan: "Finding where it fits…" shows while the server works; if it fails or takes more than 10 s the scan is put in the middle of the floor's walls as a manual placement, so it can always be dragged, turned and accepted, and the reason is shown. The plan (here and on the floor plan) zooms with a pinch, pans with two fingers (one finger when nothing else uses it) and has a Fit button once moved. Each placement request is logged (capture, floor, ms, outcome).
- Doors: after a scan, "Doors: where do they lead?" (optional) shows a small picture of the scan with its doors numbered and a "leads to" choice for each (rooms of the house and of this session, or Outside); a room's screen has "Doors: where each leads" for scans already uploaded. A door that leads to a room already on the plan is what placement lines the scan up by (the proposal says *labelled*). In the placement view, "Pair doors": tap a door on the red scan, then the same door on the plan; the scan snaps to it (Flip turns it the other way), and accepting saves the pair as labels on both scans.
- Placement is by labelled connections: a door of the scan labelled with the room it leads to, and a door of that room labelled back. With none, the placement view says what is missing, puts the scan in the middle of the floor and opens Pair doors (tap a door on the scan, then its door on the plan: the scan lands on the far side of the wall, a Flip button overrides); "Guess for me" runs the old search. Each floor has a "Doors on <floor>: label before placing" checklist of every scan's doors (○ not said, ✓ both sides agree, ✗ no partner yet, ↗ outside) with the problems in words.
- Every `xcodegen generate` first runs `ios/stamp-build`, which bakes the git commit (`+dirty` when the tree has changes) and the build number (commits so far; it is the CFBundleVersion) into the app; the launch event in the diagnostics carries both, so builds can be told apart.
- Diagnostics: the app keeps a rolling event log (JSON lines, about 2 MB, flushed per event so it survives a crash: scan phases, session
  errors with domain and code, renewals, hang-guard trips, saves, launch with version/device/OS, thermal state, memory warnings, how many
  scan controllers are alive; no names or scan content) and keeps MetricKit crash and hang reports. They stay on the phone; Settings >
  "Prepare a diagnostics file" puts them in one file for the share sheet.
- Console.app (iPhone selected), filter `subsystem:homemesh.capture`: every phase change (idle, running,
  stopping), session start and end, processing results and errors are logged, and `run`, `stop and process` and
  `build payload` are signposts (Instruments, os_signpost) so a stall shows which step it was in.

## The data

- A scan is saved with the encoded `CapturedRoom` (one room) or `CapturedStructure` (several) as the JSON body of
  `POST /api/houses/<house>/captures?name=...`, then `.../captures/<id>/usdz`, both to the in-process `LocalAPI`.
- The engine reads `walls`, `doors`, `windows`, `openings` (or the same under `rooms: [...]`), each surface's `dimensions`,
  `transform` (4x4, column-major, ARKit world frame), `category`, `confidence`, `parentIdentifier`.
- The app trims whitespace in every field and names an unnamed scan "Scan <date time>".
