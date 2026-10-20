# homemesh capture (iOS)

A small app that scans rooms with Apple RoomPlan and uploads the result to the
homemesh backend. Scope (design section 10.2): scan, combine, upload. Nothing
else: no editing, no house viewer, no accounts, no analytics, no App Store.

## Status: written, not built

The agent that wrote this works on Linux and **cannot compile or run Swift**.
Nothing here has been built or tested on a device. Expect to fix small compile
errors on the first build (RoomPlan's API surface moves between iOS releases;
check `RoomCaptureView`, `RoomCaptureViewDelegate`, `StructureBuilder` and
`export(to:)` against the current documentation). The backend half is tested:
`tests/test_roomplan.py` and `tests/test_captures.py` run synthetic
RoomPlan-shaped JSON through the real importer and endpoints.

## Build and install (owner, on a Mac)

1. Xcode 15+; an iPhone or iPad **with LiDAR** on iOS 17+.
2. `brew install xcodegen && cd ios && xcodegen generate && open HomemeshCapture.xcodeproj`
3. In Signing, pick your personal team and a bundle id of your own; run on the device.

## Use

1. Planned sign-in (docs/deploy.md): the app signs in through Pocket ID and
   sends the id token as a bearer token. **The Swift code still uses the old
   upload token and is replaced in the next PR**; do not build it for real use
   before the owner session has made the door and Pocket ID changes.
2. In the app: server address (`https://homemesh.<tailnet>`) and the house id
   (the name in the house list).
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
- Sign-in, token expiry and the door settings: `docs/deploy.md`, "The capture app's sign-in".
