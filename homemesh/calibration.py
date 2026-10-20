"""Calibration from the owner's measurements (design section 7).

Path loss is linear in the unknowns once the geometry is fixed:

    EIRP - PL0 - RSSI = extra + n * 10 log10(d) + sum_m exposure_m * L_m

(`extra` absorbs clutter, body/device loss and an error in the access point's
EIRP; `exposure_m` counts reference-thickness units of material m on the segment,
from `propagation.exposures`). So the fit is a regularised, robust (Huber, by
reweighting) linear regression with the literature values as Gaussian priors:
a material the walk never crossed keeps its prior and is reported as not
identified instead of fitting noise. Errors are honest: leave-one-area-out
cross-validation gives the held-out RMSE the planner's margin uses.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from datetime import UTC, datetime

import numpy as np

from .model import AccessPoint, Calibration, House, Measurement
from .propagation import BAND_MHZ, Params, exposures, free_space_1m, level_z

MIN_MEASUREMENTS = 8
RX_HEIGHT = 1.0  # a phone or laptop held at about this height
N_PRIOR, N_PRIOR_SD, N_BOUNDS = 2.0, 0.7, (1.2, 5.0)
EXTRA_PRIOR_SD, EXTRA_BOUNDS = 8.0, (-10.0, 40.0)
AREA_BLOCK = 4.0  # metres: measurements within one block of one level are one area for cross-validation
MIN_SIGMA = 2.0  # dB: below this the data are not that good


@dataclass
class ParamFit:
    mean: float
    sd: float
    prior_mean: float
    prior_sd: float
    identified: bool


@dataclass
class BandFit:
    band: str
    n_meas: int
    n: ParamFit
    extra_loss: ParamFit
    materials: dict[str, ParamFit]
    sigma: float
    rmse_train: float
    rmse_cv: float | None
    bias_cv: float | None
    residuals: dict[str, float] = field(default_factory=dict)  # measurement id -> observed - predicted, dB
    note: str = ""


def ap_for(house: House, m: Measurement) -> AccessPoint | None:
    if m.bssid:
        key = m.bssid.lower()
        for a in house.access_points:
            if key in (b.lower() for b in a.bssids):
                return a
        return None
    return house.access_points[0] if len(house.access_points) == 1 else None


def _rows(house: House, ms: list[Measurement], band: str):
    """Design matrix pieces for the usable measurements of one band."""
    elev = level_z(house)
    used, ys, logd, expo, areas = [], [], [], [], []
    for m in ms:
        if m.band != band or m.rssi is None:
            continue
        ap = ap_for(house, m)
        if ap is None or m.level not in elev:
            continue
        tx = (ap.position[0], ap.position[1], elev[ap.level] + ap.height)
        rx = np.array([[m.position[0], m.position[1], elev[m.level] + RX_HEIGHT]])
        d = max(1.0, float(np.linalg.norm(rx[0] - np.array(tx))))
        ex = exposures(house, tx, rx, band)  # type: ignore[arg-type]
        used.append(m)
        ys.append(ap.eirp_dbm - free_space_1m(band) - m.rssi)  # type: ignore[arg-type]
        logd.append(10.0 * math.log10(d))
        expo.append({k: float(v[0]) for k, v in ex.items()})
        areas.append((m.level, math.floor(m.position[0] / AREA_BLOCK), math.floor(m.position[1] / AREA_BLOCK)))
    return used, np.array(ys), np.array(logd), expo, areas


def _solve(X: np.ndarray, y: np.ndarray, mu: np.ndarray, sd: np.ndarray, lo: np.ndarray, hi: np.ndarray, sigma0: float):
    """MAP with a Gaussian prior, Huber reweighting, box bounds by clamping. Returns (theta, cov, sigma)."""
    p = X.shape[1]
    w = np.ones(len(y))
    theta = mu.copy()
    sigma = sigma0
    lam = np.diag(1.0 / sd**2)
    free = np.ones(p, dtype=bool)
    for _ in range(30):
        A = (X.T * w) @ X / sigma**2 + lam
        b = (X.T * w) @ y / sigma**2 + lam @ mu
        idx, fx = np.flatnonzero(free), np.flatnonzero(~free)
        new = theta.copy()
        if len(idx):
            new[idx] = np.linalg.solve(A[np.ix_(idx, idx)], b[idx] - A[np.ix_(idx, fx)] @ theta[fx])
        clamped = np.clip(new, lo, hi)
        changed_free = (clamped != new) & free
        if changed_free.any():
            free &= ~changed_free
            new = np.where(changed_free, clamped, new)
        r = y - X @ new
        sigma = max(MIN_SIGMA, 1.4826 * float(np.median(np.abs(r - np.median(r)))) if len(r) > 3 else sigma0)
        k = 1.345 * sigma
        w = np.where(np.abs(r) <= k, 1.0, k / np.maximum(np.abs(r), 1e-9))
        if np.allclose(new, theta, atol=1e-7) and not changed_free.any():
            theta = new
            break
        theta = new
    A = (X.T * w) @ X / sigma**2 + lam
    idx = np.flatnonzero(free)
    cov = np.zeros((p, p))
    if len(idx):
        cov[np.ix_(idx, idx)] = np.linalg.inv(A[np.ix_(idx, idx)])
    return theta, cov, sigma


def fit_band(house: House, band: str, ms: list[Measurement] | None = None) -> BandFit | None:
    ms = house.measurements if ms is None else ms
    used, y, logd, expo, areas = _rows(house, ms, band)
    if len(used) < MIN_MEASUREMENTS:
        return None
    mats = {m.id: m for m in house.materials}
    crossed = sorted({k for e in expo for k, v in e.items() if v > 1e-9 and k in mats})
    names = ["extra", "n", *crossed]
    X = np.column_stack([np.ones(len(y)), logd, *[[e.get(k, 0.0) for e in expo] for k in crossed]])
    mu = np.array([0.0, N_PRIOR, *[mats[k].loss[band] for k in crossed]])
    sd = np.array([EXTRA_PRIOR_SD, N_PRIOR_SD, *[max(mats[k].prior_sd, 0.25) for k in crossed]])
    lo = np.array([EXTRA_BOUNDS[0], N_BOUNDS[0], *[0.0] * len(crossed)])
    hi = np.array([EXTRA_BOUNDS[1], N_BOUNDS[1], *[60.0] * len(crossed)])
    theta, cov, sigma = _solve(X, y, mu, sd, lo, hi, 4.0)
    resid = y - X @ theta  # observed loss minus modelled loss = predicted RSSI minus observed
    post = np.sqrt(np.maximum(np.diag(cov), 0.0))

    def pf(i: int) -> ParamFit:
        return ParamFit(float(theta[i]), float(post[i]), float(mu[i]), float(sd[i]), bool(post[i] < 0.8 * sd[i]))

    fits = {k: pf(2 + i) for i, k in enumerate(crossed)}
    for k, m in mats.items():  # never crossed: prior stays, not identified
        fits.setdefault(k, ParamFit(m.loss[band], m.prior_sd, m.loss[band], m.prior_sd, False))

    # leave-one-area-out
    groups = sorted(set(areas))
    cv_err: list[float] = []
    if len(groups) >= 3:
        for g in groups:
            test = np.array([a == g for a in areas])
            if test.all() or (~test).sum() < MIN_MEASUREMENTS // 2:
                continue
            th, _, _ = _solve(X[~test], y[~test], mu, sd, lo, hi, 4.0)
            cv_err.extend((y[test] - X[test] @ th).tolist())
    note = "" if cv_err else "too few separate areas for cross-validation: the margin stays at its default"
    return BandFit(
        band, len(y), pf(1), pf(0), fits, float(sigma), float(np.sqrt(np.mean(resid**2))),
        float(np.sqrt(np.mean(np.square(cv_err)))) if cv_err else None,
        float(-np.mean(cv_err)) if cv_err else None,  # mean observed minus predicted RSSI, dB
        {m.id: float(-r) for m, r in zip(used, resid)},  # observed minus predicted RSSI
        note,
    )


def fit(house: House) -> dict[str, BandFit]:
    out = {}
    for band in BAND_MHZ:
        f = fit_band(house, band)
        if f is not None:
            out[band] = f
    return out


def apply(house: House, fits: dict[str, BandFit], now: datetime | None = None) -> House:
    """A copy of the house with the fitted materials and parameters (the owner accepts or discards it)."""
    mats = {m.id: m.model_copy(deep=True) for m in house.materials}
    n, extra, cv, cnt = dict(house.calibration.n) if house.calibration else {}, {}, {}, {}
    if house.calibration:
        extra, cv, cnt = dict(house.calibration.extra_loss_db), dict(house.calibration.rmse_cv), dict(house.calibration.n_measurements)
    for band, f in fits.items():
        n[band], extra[band], cv[band], cnt[band] = f.n.mean, f.extra_loss.mean, f.rmse_cv, f.n_meas
        for mid, p in f.materials.items():
            if p.identified:
                m = mats[mid]
                m.loss = {**m.loss, band: p.mean}
                m.prior_sd = max(0.5, p.sd)
                m.source = "calibrated from the owner's measurements"
    cal = Calibration(at=now or datetime.now(UTC), n=n, extra_loss_db=extra, rmse_cv=cv, n_measurements=cnt)
    return house.model_copy(update={"materials": list(mats.values()), "calibration": cal})


def params_for(house: House) -> Params:
    p = Params()
    if house.calibration:
        return Params(n={**p.n, **house.calibration.n}, extra_loss={**p.extra_loss, **house.calibration.extra_loss_db})
    return p


def margin_for(house: House, default: float = 6.0) -> float:
    """The planner's shadowing margin: the held-out error when calibrated (3 to 10 dB), else the default."""
    if house.calibration:
        errs = [v for v in house.calibration.rmse_cv.values() if v is not None]
        if errs:
            return float(min(10.0, max(3.0, max(errs))))
    return default


def suggest(house: House, band: str, k: int = 5, step: float = 1.0) -> list[dict]:
    """Where to measure next: cells of heavy exposure to materials the walk has not pinned down."""
    from .network import Context  # grid helpers
    from .equipment import generic_catalogue, generic_clients

    if not house.access_points:
        return []
    f = fit_band(house, band)
    unidentified = ([m for m, p in f.materials.items() if not p.identified] if f
                    else [m.id for m in house.materials])
    if not unidentified:
        return []
    ap = house.access_points[0]
    ctx = Context(house, generic_catalogue(), next(iter(generic_clients().values())), step=step, rx_height=RX_HEIGHT)
    tx = (ap.position[0], ap.position[1], level_z(house)[ap.level] + ap.height)
    ex = exposures(house, tx, ctx.cells, band)  # type: ignore[arg-type]
    have = np.array([[m.position[0], m.position[1]] for m in house.measurements if m.band == band]).reshape(-1, 2)
    out: list[dict] = []
    for mid in unidentified:
        e = ex.get(mid)
        if e is None or not (e > 0).any():
            continue
        e = np.where(ctx.cell_ok, e, 0.0)
        for i in np.argsort(-e)[: 200]:
            if e[i] <= 0:
                break
            x, y = float(ctx.cells[i][0]), float(ctx.cells[i][1])
            spots = [(o["x"], o["y"]) for o in out] + [tuple(h) for h in have]
            if all(math.hypot(x - sx, y - sy) >= 3.0 for sx, sy in spots):
                out.append({"material": mid, "level": ctx.grids[ctx.cell_level[i]].level, "x": x, "y": y, "units": float(e[i])})
                break
        if len(out) >= k:
            break
    return out


# --- import ------------------------------------------------------------------------

class MeasurementParseError(ValueError):
    pass


_BANDS = {"2.4": "2.4", "2.4ghz": "2.4", "2g": "2.4", "5": "5", "5ghz": "5", "5g": "5", "6": "6", "6ghz": "6", "6g": "6"}
_ALIASES = {"x": "x", "y": "y", "level": "level", "floor": "level", "device": "device", "band": "band", "rssi": "rssi",
            "snr": "snr", "throughput": "throughput", "mbps": "throughput", "bssid": "bssid", "time": "time", "at": "time"}
MAX_CSV_BYTES = 1_000_000
MAX_ROWS = 5000


def parse_csv(text: str, house: House, default_level: str | None = None, default_device: str = "unknown") -> list[Measurement]:
    """Measurements from CSV with a header row (x, y, band, rssi required; level, device, snr,
    throughput, bssid, time optional). Positions are plan metres. Errors name the line."""
    import csv
    import io

    if len(text.encode()) > MAX_CSV_BYTES:
        raise MeasurementParseError("file too large")
    rows = list(csv.reader(io.StringIO(text)))
    if len(rows) < 2:
        raise MeasurementParseError("need a header row and at least one reading")
    head = [_ALIASES.get(h.strip().lower()) for h in rows[0]]
    for need in ("x", "y", "band", "rssi"):
        if need not in head:
            raise MeasurementParseError(f"missing column {need}")
    if len(rows) - 1 > MAX_ROWS:
        raise MeasurementParseError(f"more than {MAX_ROWS} readings")
    levels = {lv.id for lv in house.levels}
    level0 = default_level or house.levels[0].id
    taken = {m.id for m in house.measurements}
    out: list[Measurement] = []
    n = 0
    for ln, row in enumerate(rows[1:], start=2):
        if not any(c.strip() for c in row):
            continue
        rec = {h: row[i].strip() for i, h in enumerate(head) if h and i < len(row) and row[i].strip()}
        try:
            band = _BANDS[rec["band"].lower().replace(" ", "")]
            level = rec.get("level", level0)
            if level not in levels:
                raise ValueError(f"unknown level {level}")
            while f"m{n + 1}" in taken:
                n += 1
            n += 1
            m = Measurement(
                id=f"m{n}", position=(float(rec["x"]), float(rec["y"])), level=level, device=rec.get("device", default_device)[:60],
                band=band, rssi=float(rec["rssi"]) if "rssi" in rec else None,  # type: ignore[arg-type]
                snr=float(rec["snr"]) if "snr" in rec else None, throughput=float(rec["throughput"]) if "throughput" in rec else None,
                bssid=rec.get("bssid", "").lower()[:40] or None, at=datetime.fromisoformat(rec["time"]) if "time" in rec else None)
            if m.rssi is not None and not -120 <= m.rssi <= 0:
                raise ValueError("rssi must be between -120 and 0 dBm")
            taken.add(m.id)
            out.append(m)
        except (KeyError, ValueError) as e:
            raise MeasurementParseError(f"line {ln}: {e}") from None
    return out
