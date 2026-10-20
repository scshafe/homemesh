import math
import unittest

import numpy as np

from homemesh import equipment
from homemesh.rates import best_mcs, noise_floor_dbm, phy_rate, throughput


class PhyTest(unittest.TestCase):
    def test_known_he_rates(self):
        # IEEE 802.11ax, 0.8 us GI, 1 stream: 20 MHz MCS0 = 8.6, MCS11 = 143.4; 80 MHz MCS11 = 600.5
        self.assertAlmostEqual(phy_rate(0, "ax", 20, 1), 8.6, places=1)
        self.assertAlmostEqual(phy_rate(11, "ax", 20, 1), 143.4, places=1)
        self.assertAlmostEqual(phy_rate(11, "ax", 80, 1), 600.5, places=1)
        self.assertAlmostEqual(phy_rate(11, "ax", 160, 2), 2401.9, places=0)

    def test_known_vht_and_ht_rates(self):
        # 802.11ac short GI: 80 MHz MCS9 1ss = 433.3; 20 MHz MCS8 1ss = 86.7. 802.11n 20 MHz MCS7 SGI = 72.2
        self.assertAlmostEqual(phy_rate(9, "ac", 80, 1), 433.3, places=1)
        self.assertAlmostEqual(phy_rate(8, "ac", 20, 1), 86.7, places=1)
        self.assertAlmostEqual(phy_rate(7, "n", 20, 1), 72.2, places=1)

    def test_streams_scale_linearly(self):
        self.assertAlmostEqual(phy_rate(5, "ax", 80, 2), 2 * phy_rate(5, "ax", 80, 1))

    def test_noise_floor(self):
        self.assertAlmostEqual(noise_floor_dbm(20, 7.0), -174 + 10 * math.log10(20e6) + 7, places=6)
        self.assertGreater(noise_floor_dbm(80), noise_floor_dbm(20))


class ThroughputTest(unittest.TestCase):
    def test_monotonic_and_zero_below_mcs0(self):
        snr = np.linspace(-10, 50, 121)
        t = throughput(snr, "ax", 80, 2)
        self.assertTrue((np.diff(t) >= 0).all())
        self.assertEqual(throughput(0.0, "ax", 80, 2), 0.0)
        self.assertEqual(float(t[-1]), phy_rate(11, "ax", 80, 2) * 0.6)

    def test_standard_caps_mcs(self):
        self.assertEqual(best_mcs(60, "n"), 7)
        self.assertEqual(best_mcs(60, "ac"), 9)
        self.assertEqual(best_mcs(60, "ax"), 11)
        self.assertIsNone(best_mcs(1, "ax"))

    def test_margin_lowers_rate(self):
        self.assertLessEqual(best_mcs(30, "ax", margin_db=6), best_mcs(30, "ax"))

    def test_nan_snr_is_zero(self):
        self.assertEqual(float(throughput(np.array([np.nan]), "ax", 20, 1)[0]), 0.0)

    def test_scalar_in_scalar_out(self):
        self.assertIsInstance(throughput(30.0, "ac", 40, 1), float)


class CatalogueTest(unittest.TestCase):
    def test_generic_catalogue_is_marked_assumed(self):
        for e in equipment.generic_catalogue().values():
            self.assertTrue(all(r.assumed for r in e.radios), e.id)

    def test_backhaul_radio_order_prefers_dedicated(self):
        tri = equipment.generic_catalogue()["generic-mesh-tri"]
        self.assertTrue(tri.backhaul_radios()[0].dedicated_backhaul)
        self.assertEqual(tri.radio("5").dedicated_backhaul, False)


if __name__ == "__main__":
    unittest.main()
