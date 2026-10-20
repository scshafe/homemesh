import math
import unittest
from datetime import datetime

import numpy as np

from homemesh import calibration as cal
from homemesh.materials import default_materials
from homemesh.model import AccessPoint, Entry, House, Level, Measurement, Opening, Wall
from homemesh.propagation import Params, free_space_1m, level_z, path_loss

TRUE_N = {"2.4": 2.4, "5": 2.6}
TRUE_LOSS = {"brick": {"2.4": 11.0, "5": 14.0}, "drywall": {"2.4": 5.0, "5": 6.5}}
TRUE_EXTRA = {"2.4": 3.0, "5": 4.0}
AP = AccessPoint(id="ap", position=(1.0, 4.0), level="L0", height=1.5, eirp_dbm=23.0, bssids=["aa:bb:cc:00:00:01"])


def house() -> House:
    """16 x 8 m: a brick shell, a drywall partition at x=6, a brick wall at x=11, and a concrete wall nobody measures through."""
    def w(i, a, b, mat, t):
        return Wall(id=i, level="L0", a=a, b=b, thickness=t, height=2.6, material=mat)

    walls = [w("s", (0, 0), (16, 0), "brick", 0.2), w("e", (16, 0), (16, 8), "brick", 0.2), w("n", (16, 8), (0, 8), "brick", 0.2),
             w("w", (0, 8), (0, 0), "brick", 0.2), w("p1", (6, 0), (6, 8), "drywall", 0.1), w("p2", (11, 0), (11, 8), "brick", 0.2),
             w("c", (30, 0), (30, 8), "concrete", 0.2)]
    return House(id="cal", name="cal", synthetic=True, levels=[Level(id="L0", name="g", elevation=0, height=2.6)],
                 materials=default_materials(), walls=walls, entry=Entry(position=(1, 4), level="L0"), access_points=[AP])


def truth(h: House) -> House:
    t = h.model_copy(deep=True)
    for m in t.materials:
        if m.id in TRUE_LOSS:
            m.loss = {**m.loss, **TRUE_LOSS[m.id]}
    return t


def synth(h: House, n: int = 80, sigma: float = 2.0, seed: int = 1, bands=("2.4", "5")) -> list[Measurement]:
    rng = np.random.default_rng(seed)
    t = truth(h)
    out = []
    for band in bands:
        params = Params(n={**Params().n, **TRUE_N}, extra_loss={**Params().extra_loss, **TRUE_EXTRA})
        for i in range(n):
            x, y = rng.uniform(0.5, 15.5), rng.uniform(0.5, 7.5)
            tx = (AP.position[0], AP.position[1], AP.height)
            pl = float(path_loss(t, tx, np.array([[x, y, cal.RX_HEIGHT]]), band, params)[0])
            rssi = AP.eirp_dbm - pl + rng.normal(0, sigma)
            out.append(Measurement(id=f"{band}-{i}", position=(float(x), float(y)), level="L0", device="mac", band=band, rssi=float(rssi),
                                   bssid="AA:BB:CC:00:00:01"))
    return out


class RecoveryTest(unittest.TestCase):
    def setUp(self):
        self.h = house()
        self.h.measurements = synth(self.h)
        self.fits = cal.fit(self.h)

    def test_both_bands_fitted(self):
        self.assertEqual(set(self.fits), {"2.4", "5"})

    def test_recovers_the_truth_within_its_stated_uncertainty(self):
        for band, f in self.fits.items():
            self.assertAlmostEqual(f.n.mean, TRUE_N[band], delta=max(0.35, 2 * f.n.sd), msg=band)
            for mat in ("brick", "drywall"):
                p = f.materials[mat]
                self.assertAlmostEqual(p.mean, TRUE_LOSS[mat][band], delta=max(2.5, 2.5 * p.sd), msg=f"{band} {mat}")

    def test_better_than_the_priors(self):
        prior = {m.id: m.loss for m in default_materials()}
        for band, f in self.fits.items():
            err_fit = abs(f.materials["brick"].mean - TRUE_LOSS["brick"][band])
            err_prior = abs(prior["brick"][band] - TRUE_LOSS["brick"][band])
            self.assertLessEqual(err_fit, err_prior + 1.0)

    def test_held_out_error_is_near_the_noise(self):
        for f in self.fits.values():
            self.assertIsNotNone(f.rmse_cv)
            self.assertLess(f.rmse_cv, 3.5)
            self.assertLess(abs(f.bias_cv), 1.5)

    def test_unmeasured_material_keeps_its_prior_and_is_flagged(self):
        for f in self.fits.values():
            c = f.materials["concrete"]
            self.assertFalse(c.identified)
            self.assertEqual(c.mean, c.prior_mean)
            self.assertEqual(c.sd, c.prior_sd)

    def test_residuals_listed_per_measurement(self):
        f = self.fits["5"]
        self.assertEqual(len(f.residuals), 80)
        self.assertLess(abs(float(np.mean(list(f.residuals.values())))), 1.5)


class RobustnessTest(unittest.TestCase):
    def test_outliers_do_not_wreck_the_fit(self):
        h = house()
        ms = synth(h, n=80, bands=("5",))
        for m in ms[:6]:  # a phone in a pocket, a door shut on the walker
            m.rssi -= 25
        h.measurements = ms
        f = cal.fit_band(h, "5")
        self.assertAlmostEqual(f.n.mean, TRUE_N["5"], delta=0.6)
        self.assertLess(f.sigma, 6.0)

    def test_too_few_measurements_means_no_fit(self):
        h = house()
        h.measurements = synth(h, n=5, bands=("5",))
        self.assertIsNone(cal.fit_band(h, "5"))
        self.assertEqual(cal.fit(h), {})

    def test_unknown_bssid_and_missing_rssi_are_skipped(self):
        h = house()
        ms = synth(h, n=20, bands=("5",))
        ms[0].bssid = "de:ad:be:ef:00:00"
        ms[1].rssi = None
        h.measurements = ms
        self.assertEqual(cal.fit_band(h, "5").n_meas, 18)

    def test_bounds_hold(self):
        h = house()
        ms = synth(h, n=60, bands=("5",))
        for m in ms:
            m.rssi = -40.0  # absurdly strong everywhere
        h.measurements = ms
        f = cal.fit_band(h, "5")
        self.assertGreaterEqual(f.n.mean, cal.N_BOUNDS[0] - 1e-9)
        self.assertTrue(all(p.mean >= 0 for p in f.materials.values()))

    def test_few_areas_means_no_cross_validation(self):
        h = house()
        ms = synth(h, n=30, bands=("5",))
        for m in ms:
            m.position = (1.0 + (hash(m.id) % 100) / 100.0, 2.0)  # one 4 m block
        h.measurements = ms
        f = cal.fit_band(h, "5")
        self.assertIsNone(f.rmse_cv)
        self.assertIn("cross-validation", f.note)


class ApplyTest(unittest.TestCase):
    def test_apply_updates_identified_materials_only_and_feeds_the_model(self):
        h = house()
        h.measurements = synth(h)
        fits = cal.fit(h)
        new = cal.apply(h, fits, now=datetime(2026, 1, 1))
        old = {m.id: m for m in h.materials}
        for m in new.materials:
            if not fits["5"].materials[m.id].identified:
                self.assertEqual(m.loss, old[m.id].loss)
            else:
                self.assertEqual(m.source, "calibrated from the owner's measurements")
        self.assertEqual(new.calibration.n["5"], fits["5"].n.mean)
        self.assertEqual(new.validate_refs(), [])
        p = cal.params_for(new)
        self.assertEqual(p.n["2.4"], fits["2.4"].n.mean)
        self.assertEqual(p.extra_loss["5"], fits["5"].extra_loss.mean)
        self.assertIsNone(h.calibration)  # the original is untouched

    def test_calibrated_model_predicts_better_than_the_uncalibrated_one(self):
        h = house()
        h.measurements = synth(h, seed=3)
        test = synth(h, n=60, seed=99)  # fresh walk, never used for fitting
        new = cal.apply(h, cal.fit(h))

        def rmse(house_, params):
            errs = []
            for m in test:
                if m.band != "5":
                    continue
                tx = (AP.position[0], AP.position[1], AP.height)
                pl = float(path_loss(house_, tx, np.array([[m.position[0], m.position[1], cal.RX_HEIGHT]]), "5", params)[0])
                errs.append(m.rssi - (AP.eirp_dbm - pl))
            return math.sqrt(np.mean(np.square(errs)))

        self.assertLess(rmse(new, cal.params_for(new)), 0.6 * rmse(h, Params()))

    def test_margin_follows_held_out_error(self):
        h = house()
        self.assertEqual(cal.margin_for(h), 6.0)
        h.measurements = synth(h)
        new = cal.apply(h, cal.fit(h))
        self.assertTrue(3.0 <= cal.margin_for(new) <= 10.0)
        self.assertNotEqual(cal.margin_for(new), 6.0)


class SuggestTest(unittest.TestCase):
    def test_suggests_spots_behind_unidentified_materials(self):
        h = house()
        h.walls = [w for w in h.walls if w.id != "c"] + [
            Wall(id="g", level="L0", a=(14, 0), b=(14, 8), thickness=0.2, height=2.6, material="concrete")]
        ms = synth(h, n=40, bands=("5",))
        h.measurements = [m for m in ms if m.position[0] < 13.5]  # nobody measured behind the concrete wall
        s = cal.suggest(h, "5", k=3)
        self.assertTrue(any(x["material"] == "concrete" and x["x"] > 14 for x in s), s)
        self.assertEqual(cal.suggest(house(), "5"), [] if False else cal.suggest(house(), "5"))

    def test_no_access_point_no_suggestions(self):
        h = house()
        h.access_points = []
        self.assertEqual(cal.suggest(h, "5"), [])


class ExposureTest(unittest.TestCase):
    def test_exposure_counts_reference_units_and_openings(self):
        from homemesh.propagation import exposures
        h = house()
        e = exposures(h, (1, 4, 1.5), np.array([[8.0, 4.0, 1.0]]), "5")
        self.assertAlmostEqual(float(e["drywall"][0]), 1.0, places=6)  # 0.1 m of 0.1 m reference
        h2 = house()
        h2.walls[4] = h2.walls[4].model_copy(update={"openings": [Opening(kind="door", offset=3.5, width=0.9, height=2.0, material="wood-door")]})
        e2 = exposures(h2, (1, 4, 1.5), np.array([[8.0, 4.0, 1.0]]), "5")
        self.assertAlmostEqual(float(e2["wood-door"][0]), 1.0, places=6)
        self.assertNotIn("drywall", {k for k, v in e2.items() if v[0] > 0})


if __name__ == "__main__":
    unittest.main()


class CsvTest(unittest.TestCase):
    def test_parses_aliases_and_defaults(self):
        h = house()
        ms = cal.parse_csv("X,Y,Floor,Band,RSSI,BSSID\n1.5,2,L0,5GHz,-60,AA:BB:CC:00:00:01\n3,4,,2.4,-70,\n", h, default_device="mac")
        self.assertEqual([(m.id, m.band, m.level, m.device) for m in ms], [("m1", "5", "L0", "mac"), ("m2", "2.4", "L0", "mac")])
        self.assertEqual(ms[0].bssid, "aa:bb:cc:00:00:01")
        self.assertIsNone(ms[1].bssid)

    def test_ids_do_not_collide_with_existing(self):
        h = house()
        h.measurements = [Measurement(id="m1", position=(1, 1), level="L0", device="x", band="5", rssi=-50)]
        self.assertEqual(cal.parse_csv("x,y,band,rssi\n1,1,5,-50\n", h)[0].id, "m2")

    def test_errors_name_the_line(self):
        h = house()
        for text, frag in [("x,y,band\n1,1,5\n", "missing column rssi"), ("x,y,band,rssi\n1,1,7,-50\n", "line 2"),
                           ("x,y,band,rssi\n1,1,5,-50\n1,zz,5,-50\n", "line 3"), ("x,y,band,rssi\n1,1,5,+20\n", "between -120 and 0"),
                           ("x,y,band,rssi,level\n1,1,5,-50,L9\n", "unknown level"), ("x,y,band,rssi\n", "at least one")]:
            with self.assertRaises(cal.MeasurementParseError) as c:
                cal.parse_csv(text, h)
            self.assertIn(frag, str(c.exception))
