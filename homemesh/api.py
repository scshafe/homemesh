"""HTTP API (design section 6) and the static front end.

Access: besides the header, /api answers only to the door's own address on the
stack network (HOMEMESH_DOOR_ADDR, comma-separated; default the stack's door;
unset in development with HOMEMESH_DEV=1 means any peer on loopback). A forged
header from any other peer is refused with 403 before the header is looked at.

The door (the platform's Pocket ID + door container) sits in front of
this app and adds an identity header. The app trusts only that header: with
HOMEMESH_AUTH_HEADER set, every /api request without it is refused (401), so
"it is on the tailnet" is never the only protection. With it unset the app
refuses to start unless HOMEMESH_DEV=1 (local development, loopback only).
/api/health carries no house data and is open.
"""

from __future__ import annotations

import base64
import json
import os
from pathlib import Path

import numpy as np
from fastapi import Body, Depends, FastAPI, HTTPException, Request
from fastapi.responses import Response
from fastapi.staticfiles import StaticFiles

from . import blueprint, calibration, captures, jobs, roomplan, store
from . import catalogue as catalogue_mod
from pydantic import BaseModel, ValidationError

from .materials import default_materials
from .model import House, Level
from .propagation import BAND_MHZ, Tx, level_grid, rssi_map

DEV = "HOMEMESH_DEV"
AUTH_HEADER = "HOMEMESH_AUTH_HEADER"
WEB_DIST = "HOMEMESH_WEB_DIST"
DOOR_ADDR = "HOMEMESH_DOOR_ADDR"
DEFAULT_DOOR_ADDR = "10.253.93.10"  # the door on the stack network (deploy/stack/compose.yaml)
MAX_BODY = 8 * 1024 * 1024


class NewHouse(BaseModel):
    id: str
    name: str


def create_app() -> FastAPI:
    header = os.environ.get(AUTH_HEADER)
    dev = os.environ.get(DEV) == "1"
    if not header and not dev:
        raise RuntimeError(f"set {AUTH_HEADER} (the door's identity header) or {DEV}=1 for local development")
    door = {a.strip() for a in os.environ.get(DOOR_ADDR, "" if dev else DEFAULT_DOOR_ADDR).split(",") if a.strip()}
    store.data_dir()  # fail at startup if the data directory is unset or inside the checkout

    app = FastAPI(title="homemesh", docs_url=None, redoc_url=None, openapi_url=None)

    def require_identity(request: Request) -> None:
        if door and (request.client is None or request.client.host not in door):
            raise HTTPException(403, "not the door")
        if header and not request.headers.get(header):
            raise HTTPException(401, "no identity from the door")

    api = Depends(require_identity)

    @app.get("/api/health")
    def health() -> dict:
        return {"ok": True}

    @app.get("/api/houses", dependencies=[api])
    def houses() -> list[str]:
        return store.list_houses()

    def get_house(house_id: str) -> House:
        try:
            return store.load(house_id)
        except store.StoreError:
            raise HTTPException(404, "no such house") from None

    @app.get("/api/houses/{house_id}", dependencies=[api])
    def house(house_id: str) -> dict:
        return get_house(house_id).model_dump(mode="json")

    @app.post("/api/houses", dependencies=[api], status_code=201)
    def create_house(req: NewHouse) -> dict:
        h = House(id=req.id, name=req.name, levels=[Level(id="L0", name="Ground", elevation=0.0, height=2.5)],
                  materials=default_materials())
        try:
            return store.save(h).model_dump(mode="json")
        except store.Conflict:
            raise HTTPException(409, "house exists") from None
        except store.StoreError as e:
            raise HTTPException(422, str(e)) from None

    @app.put("/api/houses/{house_id}", dependencies=[api])
    async def save_house(house_id: str, request: Request, expect_revision: int) -> dict:
        """Save an edited house as the next revision. `expect_revision` is the
        revision the editor started from; a stale one gets 409."""
        raw = await request.body()
        if len(raw) > MAX_BODY:
            raise HTTPException(413, "house too large")
        try:
            h = House.model_validate_json(raw)
        except ValidationError as e:
            raise HTTPException(422, e.errors(include_url=False, include_input=False)) from None
        if h.id != house_id:
            raise HTTPException(422, "id does not match the URL")
        try:
            return store.save(h, expect_revision=expect_revision).model_dump(mode="json")
        except store.Conflict as e:
            raise HTTPException(409, str(e)) from None
        except store.StoreError as e:
            raise HTTPException(422, str(e)) from None

    @app.post("/api/houses/{house_id}/blueprints", dependencies=[api])
    async def upload_blueprint(house_id: str, request: Request) -> list[dict]:
        """Raw image or PDF body. Returns one PNG blob per page: [{blob, width_px, height_px}]."""
        get_house(house_id)
        raw = await request.body()
        try:
            pages = blueprint.pages(raw)
        except blueprint.BlueprintError as e:
            raise HTTPException(422, str(e)) from None
        return [{"blob": store.put_blob(house_id, p.png), "width_px": p.width, "height_px": p.height} for p in pages]

    @app.get("/api/houses/{house_id}/blobs/{digest}", dependencies=[api])
    def blob(house_id: str, digest: str) -> Response:
        try:
            data = store.get_blob(house_id, digest)
        except store.StoreError:
            raise HTTPException(404, "no such blob") from None
        png = data[:8] == b"\x89PNG\r\n\x1a\n"
        return Response(data, media_type="image/png" if png else "application/octet-stream",
                        headers={"X-Content-Type-Options": "nosniff", "Cache-Control": "private, max-age=3600",
                                 **({} if png else {"Content-Disposition": "attachment"})})

    @app.get("/api/catalogue", dependencies=[api])
    def catalogue() -> dict:
        try:
            return catalogue_mod.describe(catalogue_mod.load())
        except catalogue_mod.CatalogueError as e:
            raise HTTPException(500, str(e)) from None

    @app.post("/api/houses/{house_id}/plans", dependencies=[api], status_code=202)
    def start_plan(house_id: str, req: dict = Body(default_factory=dict)) -> dict:
        h = get_house(house_id)
        if h.entry is None:
            raise HTTPException(422, "mark the internet entry first")
        if not any(z.kind == "allow" for z in h.zones):
            raise HTTPException(422, "mark at least one allow zone first")
        if not any(z.kind == "demand" for z in h.zones):
            raise HTTPException(422, "mark at least one demand zone first")
        return {"job": jobs.start(h, req).id}

    @app.get("/api/jobs/{job_id}", dependencies=[api])
    def job(job_id: str) -> dict:
        j = jobs.get(job_id)
        if j is None:
            raise HTTPException(404, "no such job")
        return {"state": j.state, "progress": j.progress[-20:], "error": j.error, "result": j.result}

    @app.post("/api/houses/{house_id}/ratemap", dependencies=[api])
    def ratemap(house_id: str, req: dict = Body(...)) -> dict:
        h = get_house(house_id)
        try:
            return jobs.rate_map(h, req)
        except (ValueError, KeyError, TypeError) as e:
            raise HTTPException(422, str(e)) from None

    @app.post("/api/houses/{house_id}/measurements/parse", dependencies=[api])
    async def parse_measurements(house_id: str, request: Request, level: str | None = None, device: str = "unknown") -> list[dict]:
        """CSV body to validated measurements (not stored: the editor adds them to the house and saves)."""
        h = get_house(house_id)
        try:
            text = (await request.body()).decode("utf-8-sig")
            return [m.model_dump(mode="json") for m in calibration.parse_csv(text, h, level, device)]
        except (calibration.MeasurementParseError, UnicodeDecodeError) as e:
            raise HTTPException(422, str(e)) from None

    @app.post("/api/houses/{house_id}/calibrate", dependencies=[api])
    async def calibrate(house_id: str, request: Request) -> dict:
        """Fit the model to the measurements. Body: the house as the editor has it (unsaved edits
        included); the saved house when the body is empty. Nothing is stored: `calibrated` is the
        house with the fit applied, for the owner to accept (it becomes an ordinary edit) or discard."""
        raw = await request.body()
        if len(raw) > MAX_BODY:
            raise HTTPException(413, "house too large")
        if raw.strip():
            try:
                h = House.model_validate_json(raw)
            except ValidationError as e:
                raise HTTPException(422, e.errors(include_url=False, include_input=False)) from None
            if h.id != house_id:
                raise HTTPException(422, "id does not match the URL")
            if h.validate_refs():
                raise HTTPException(422, "invalid house")
        else:
            h = get_house(house_id)
        fits = calibration.fit(h)
        from dataclasses import asdict
        out = {band: asdict(f) for band, f in fits.items()}
        return {"fits": out, "suggestions": {b: calibration.suggest(h, b) for b in fits} if fits else {},
                "calibrated": calibration.apply(h, fits).model_dump(mode="json") if fits else None,
                "access_points": len(h.access_points), "measurements": len(h.measurements)}

    @app.post("/api/houses/{house_id}/captures", dependencies=[api])
    async def upload_capture(house_id: str, request: Request, name: str = "") -> dict:
        """The capture JSON (CapturedRoom / CapturedStructure, or the app's {"rooms": [...]} wrapper)."""
        get_house(house_id)
        try:
            return captures.save_capture(house_id, await request.body(), name)
        except captures.CaptureError as e:
            raise HTTPException(422, str(e)) from None

    @app.post("/api/houses/{house_id}/captures/{digest}/usdz", dependencies=[api])
    async def upload_usdz(house_id: str, digest: str, request: Request) -> dict:
        get_house(house_id)
        try:
            return captures.attach_usdz(house_id, digest, await request.body())
        except captures.CaptureError as e:
            raise HTTPException(422, str(e)) from None

    @app.get("/api/houses/{house_id}/captures", dependencies=[api])
    def list_captures(house_id: str) -> list[dict]:
        get_house(house_id)
        return captures.list_captures(house_id)

    @app.post("/api/houses/{house_id}/captures/{digest}/import", dependencies=[api])
    async def import_capture(house_id: str, digest: str, level: str, request: Request) -> dict:
        """Scan walls onto `level`. Body (optional JSON): {"house": the editor's house, "registration":
        {"src": [[x, y], ...], "dst": [[x, y], ...]}}. Stores nothing: the result is a preview the
        editor takes as an ordinary edit. Importing a scan again replaces what it added before."""
        raw = await request.body()
        if len(raw) > MAX_BODY:
            raise HTTPException(413, "too large")
        body = {}
        if raw.strip():
            try:
                body = json.loads(raw)
            except ValueError:
                raise HTTPException(422, "body is not JSON") from None
        try:
            h = House.model_validate(body["house"]) if body.get("house") else get_house(house_id)
            if h.id != house_id or h.validate_refs():
                raise HTTPException(422, "invalid house")
            sim = None
            reg = body.get("registration")
            if reg:
                src, dst = [tuple(map(float, p)) for p in reg["src"]], [tuple(map(float, p)) for p in reg["dst"]]
                sim = roomplan.register(src, dst)
            data = captures.load_capture(house_id, digest)
            new, rep = roomplan.import_capture(h, data, level, digest, sim)
        except (captures.CaptureError, roomplan.ImportError_, store.StoreError, KeyError, TypeError, ValueError) as e:
            raise HTTPException(422, str(e)) from None
        out = {"house": new.model_dump(mode="json"), "report": {"walls": rep.walls, "paired_walls": rep.paired_walls, "openings": rep.openings,
               "skipped_openings": rep.skipped_openings, "replaced": rep.replaced, "notes": rep.notes}}
        if sim:
            out["registration"] = {"rotation": sim.rotation, "tx": sim.tx, "ty": sim.ty,
                                   "max_error_m": roomplan.registration_error(src, dst, sim)}
        return out

    @app.get("/api/houses/{house_id}/revisions", dependencies=[api])
    def revisions(house_id: str) -> list[int]:
        return store.list_revisions(house_id)

    @app.get("/api/houses/{house_id}/heatmap", dependencies=[api])
    def heatmap(house_id: str, x: float, y: float, level: str, band: str = "5",
                height: float = 1.8, step: float = 0.5, rx_height: float = 1.0) -> dict:
        h = get_house(house_id)
        if band not in BAND_MHZ:
            raise HTTPException(422, "unknown band")
        if level not in {lv.id for lv in h.levels}:
            raise HTTPException(422, "unknown level")
        if not 0.25 <= step <= 2.0:
            raise HTTPException(422, "step out of range")
        tx = Tx((x, y), level, height=height)
        grids = []
        for lv in h.levels:
            if not any(w.level == lv.id for w in h.walls):
                continue
            g = level_grid(h, lv.id, step, rx_height)
            m = rssi_map(h, tx, band, g)
            grids.append({"level": lv.id, "x0": g.x0, "y0": g.y0, "step": g.step, "nx": g.nx, "ny": g.ny,
                          "rssi_f32_b64": base64.b64encode(m.astype("<f4").tobytes()).decode()})
        return {"band": band, "tx": {"x": x, "y": y, "level": level, "height": height}, "grids": grids}

    dist = Path(os.environ.get(WEB_DIST, Path(__file__).resolve().parent.parent / "web" / "dist"))
    if dist.is_dir():
        app.mount("/", StaticFiles(directory=dist, html=True), name="web")
    return app


def app_factory() -> FastAPI:  # uvicorn --factory homemesh.api:app_factory
    return create_app()
