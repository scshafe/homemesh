"""HTTP API (design section 6) and the static front end.

Access: the door (the platform's Pocket ID + door container) sits in front of
this app and adds an identity header. The app trusts only that header: with
HOMEMESH_AUTH_HEADER set, every /api request without it is refused (401), so
"it is on the tailnet" is never the only protection. With it unset the app
refuses to start unless HOMEMESH_DEV=1 (local development, loopback only).
/api/health carries no house data and is open.
"""

from __future__ import annotations

import base64
import os
from pathlib import Path

import numpy as np
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import Response
from fastapi.staticfiles import StaticFiles

from . import blueprint, store
from pydantic import BaseModel, ValidationError

from .materials import default_materials
from .model import House, Level
from .propagation import BAND_MHZ, Tx, level_grid, rssi_map

DEV = "HOMEMESH_DEV"
AUTH_HEADER = "HOMEMESH_AUTH_HEADER"
WEB_DIST = "HOMEMESH_WEB_DIST"
MAX_BODY = 8 * 1024 * 1024


class NewHouse(BaseModel):
    id: str
    name: str


def create_app() -> FastAPI:
    header = os.environ.get(AUTH_HEADER)
    dev = os.environ.get(DEV) == "1"
    if not header and not dev:
        raise RuntimeError(f"set {AUTH_HEADER} (the door's identity header) or {DEV}=1 for local development")
    store.data_dir()  # fail at startup if the data directory is unset or inside the checkout

    app = FastAPI(title="homemesh", docs_url=None, redoc_url=None, openapi_url=None)

    def require_identity(request: Request) -> None:
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
