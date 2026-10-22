# homemesh capture (iOS)

A small app that scans rooms with Apple RoomPlan and uploads the result to the
homemesh backend. Scope (design section 10.2): scan, combine, upload. Nothing
else: no editing, no house viewer, no accounts, no analytics, no App Store.

## Status

CI (`.github/workflows/ci.yml`, job `ios`, macos-26 / Xcode 26) generates the
project with XcodeGen, builds the app for an iPhone simulator against the
current SDK and runs the unit tests in `HomemeshCaptureTests` (PKCE challenge
against the RFC 7636 vector, token expiry). CI cannot scan: RoomPlan needs a
LiDAR sensor, so the scan itself, the sign-in against the live Pocket ID and
an upload are checked by hand on a phone. The backend half is tested with
synthetic RoomPlan-shaped JSON (`tests/test_roomplan.py`, `tests/test_captures.py`).

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
6. In the app enter the server (`https://homemesh.<tailnet>`), the house id,
   Pocket ID's address and the client id (`homemesh-capture`). Upload signs you
   in with your passkey.

**Needs a LiDAR iPhone** (Pro models and some iPads). On a device without LiDAR
the app installs and opens, but "Start scanning" is disabled and it says "This
device has no LiDAR scanner."; nothing can be scanned or uploaded from it.

## Use

1. Settings (the gear): server (`https://homemesh.<tailnet>`), Pocket ID's address and the client id (`homemesh-capture`).
   Sign-in happens on first use (passkey in a system browser sheet); Sign out clears it.
2. Houses: pull to refresh; **+** creates a house. Opening a house shows its floors, each with its rooms
   (name, description, on the plan or not), and **Add room scan** at the top.
3. Add room scan: pick the floor, scan a room, Done, and give the room its name in the field that appears
   (one field per room, required before Upload; suggestions are in a room's details). Scan more rooms of the
   same floor, then Upload. Rooms of one scan share a frame; a copy stays in Files (homemesh, Scans) until the
   server has accepted it. Messages appear under the camera view if tracking is limited or no walls are
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
   Still later: placing scans is in the room details; planning and calibration follow in later milestones
   (docs/design-ios-app.md); until then use the web app for them. Placing scans on the plan, walls and materials, planning and calibration follow in later milestones
   (docs/design-ios-app.md); until then use the web app for them: Plan editor, Scans, Import to this level.
   A scan gives no wall thickness or material: set them in the editor.

## Debugging a scan

- Xcode's Run turns on Metal API validation and GPU frame capture by default. The scheme in `project.yml`
  switches both off (`enableGPUValidationMode: false`, `enableGPUFrameCaptureMode: disabled`) so a Run behaves
  like a launch from the home screen; an earlier freeze at the start of the second room was a pause on the
  renderer thread (`Render`, `__pthread_kill`, console line about `tonemapLUT`) under validation. If it still
  freezes, launch the app from the home screen after installing, and send the console text.
- One scan view and one AR session live for the whole multi-room scan; between rooms the session stops with
  `pauseARSession: false`, so rooms share one frame. Building the upload (combine, encode, USDZ) runs off the
  main thread.
- Console.app (iPhone selected), filter `subsystem:homemesh.capture`: every phase change (idle, running,
  stopping), session start and end, processing results and errors are logged, and `run`, `stop and process` and
  `build payload` are signposts (Instruments, os_signpost) so a stall shows which step it was in.

## Contract with the backend

- `POST /api/houses/<house>/captures?name=...` with the encoded `CapturedRoom`
  (one room) or `CapturedStructure` (several) as the JSON body, then
  `POST .../captures/<id>/usdz` with the exported USDZ. Both carry
  `Authorization: Bearer <id token>`; the door verifies it and sets the identity header.
- The backend reads `walls`, `doors`, `windows`, `openings` (or the same under
  `rooms: [...]`), each surface's `dimensions`, `transform` (4x4, column-major,
  ARKit world frame), `category`, `confidence`, `parentIdentifier`.
- Fields: the app trims whitespace in every field (a trailing space in the house
  id gave a 404 once), can list the server's houses (a picker instead of typing),
  and names an unnamed scan "Scan <date time>". The house must already exist in
  homemesh; a 404 says so.
- Refresh tokens: Pocket ID issues them to this client, so the app asks for
  `offline_access` and renews the id token silently; if a refresh fails it
  signs in again (one tap through Pocket ID).
- Client id `homemesh-capture` (the default in the app), callback
  `homemesh-capture://oauth`. The door replaces `Authorization` with its own
  value before the backend, so nothing downstream reads it.
- A door that is not accepting the token answers 401, or redirects to its login
  page (which the app sees as an unexpected answer). A 401 clears the stored token; sign
  out and in again if an upload keeps failing that way.
- Sign-in, token expiry and the door settings: `docs/deploy.md`, "The capture app's sign-in".
