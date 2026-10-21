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

1. Sign-in goes through Pocket ID (docs/deploy.md, "The capture app's
   sign-in"): the owner session first creates the public "homemesh capture"
   client and changes the door. Needs the client id and Pocket ID's address.
2. In the app: server address (`https://homemesh.<tailnet>`), the house id (the
   name in the house list), Pocket ID's address and the capture client id
   (`homemesh-capture`; none of these is a secret). Upload signs you in (passkey, in a system browser
   sheet) and keeps the id token in the Keychain; Sign out clears it.
3. Start scanning a room, walk it, Done; repeat for more rooms (several rooms
   are combined with `StructureBuilder` so they share one frame). Upload.
4. In homemesh: Plan editor, Scans, Import to this level; then Align scan
   with two or three point pairs if it should sit somewhere else on the plan.
   A scan gives no wall thickness or material: set them in the editor.

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
