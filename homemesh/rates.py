"""SNR to throughput (design 3.5).

PHY rate comes from the standard's own arithmetic (data subcarriers x bits per
subcarrier x coding rate x streams / symbol time), not from a copied table:

    HT/VHT: symbol 3.6 us (short GI);  HE: 13.6 us (0.8 us GI)

The minimum SNR per MCS below are approximate textbook values for a typical
receiver, a prior that calibration (M7) can adjust. Throughput = PHY x MAC
efficiency (default 0.6): a calibration parameter, not a constant of nature.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

# (bits per subcarrier, coding rate) for MCS 0..11
_MCS = [(1, 1 / 2), (2, 1 / 2), (2, 3 / 4), (4, 1 / 2), (4, 3 / 4), (6, 2 / 3), (6, 3 / 4), (6, 5 / 6),
        (8, 3 / 4), (8, 5 / 6), (10, 3 / 4), (10, 5 / 6)]
_MIN_SNR = [4.0, 7.0, 10.0, 13.0, 17.0, 21.0, 23.0, 25.0, 29.0, 31.0, 35.0, 37.0]

_SUBCARRIERS = {
    "n": {20: 52, 40: 108},
    "ac": {20: 52, 40: 108, 80: 234, 160: 468},
    "ax": {20: 234, 40: 468, 80: 980, 160: 1960},
}
_SYMBOL_US = {"n": 3.6, "ac": 3.6, "ax": 13.6}
_MAX_MCS = {"n": 7, "ac": 9, "ax": 11}
_MAX_STREAMS = {"n": 4, "ac": 8, "ax": 8}

MAC_EFFICIENCY = 0.6


@dataclass(frozen=True)
class Link:
    standard: str
    width: int
    streams: int

    def rate_at(self, snr_db: float, mac_eff: float = MAC_EFFICIENCY) -> float:
        return float(throughput(snr_db, self.standard, self.width, self.streams, mac_eff))


def phy_rate(mcs: int, standard: str, width: int, streams: int) -> float:
    """PHY rate in Mbit/s."""
    bits, coding = _MCS[mcs]
    nsd = _SUBCARRIERS[standard][width]
    return nsd * bits * coding * min(streams, _MAX_STREAMS[standard]) / _SYMBOL_US[standard]


def noise_floor_dbm(width: int, noise_figure_db: float = 7.0) -> float:
    return -174.0 + 10.0 * math.log10(width * 1e6) + noise_figure_db


def best_mcs(snr_db: float, standard: str, margin_db: float = 0.0) -> int | None:
    """Highest usable MCS at this SNR, or None below MCS 0."""
    top = None
    for m in range(_MAX_MCS[standard] + 1):
        if snr_db - margin_db >= _MIN_SNR[m]:
            top = m
    return top


def throughput(snr_db, standard: str, width: int, streams: int, mac_eff: float = MAC_EFFICIENCY):
    """Vectorised: SNR (scalar or ndarray, dB) to throughput in Mbit/s (0 below MCS 0)."""
    import numpy as np

    snr = np.asarray(snr_db, dtype=float)
    table = np.array([phy_rate(m, standard, width, streams) for m in range(_MAX_MCS[standard] + 1)])
    thresholds = np.array(_MIN_SNR[: _MAX_MCS[standard] + 1])
    # index of the highest threshold <= snr; -1 when none
    idx = np.searchsorted(thresholds, np.nan_to_num(snr, nan=-1e9), side="right") - 1
    out = np.where(idx >= 0, table[np.clip(idx, 0, None)] * mac_eff, 0.0)
    return out if out.ndim else float(out)
