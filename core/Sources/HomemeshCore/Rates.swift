import Foundation

// SNR to throughput (a port of homemesh/rates.py): PHY rate from the standard's arithmetic, minimum SNR per MCS, MAC efficiency.

public enum WifiStandard: String, Sendable, Codable, Hashable { case n, ac, ax }

public enum Rates {
    static let mcs: [(bits: Double, coding: Double)] = [(1, 1.0 / 2), (2, 1.0 / 2), (2, 3.0 / 4), (4, 1.0 / 2), (4, 3.0 / 4), (6, 2.0 / 3),
                                                       (6, 3.0 / 4), (6, 5.0 / 6), (8, 3.0 / 4), (8, 5.0 / 6), (10, 3.0 / 4), (10, 5.0 / 6)]
    static let minSnr: [Double] = [4, 7, 10, 13, 17, 21, 23, 25, 29, 31, 35, 37]
    static let subcarriers: [WifiStandard: [Int: Double]] = [
        .n: [20: 52, 40: 108],
        .ac: [20: 52, 40: 108, 80: 234, 160: 468],
        .ax: [20: 234, 40: 468, 80: 980, 160: 1960],
    ]
    static let symbolUs: [WifiStandard: Double] = [.n: 3.6, .ac: 3.6, .ax: 13.6]
    static let maxMcs: [WifiStandard: Int] = [.n: 7, .ac: 9, .ax: 11]
    static let maxStreams: [WifiStandard: Int] = [.n: 4, .ac: 8, .ax: 8]
    public static let macEfficiency = 0.6

    /// PHY rate in Mbit/s.
    public static func phyRate(mcs m: Int, _ std: WifiStandard, width: Int, streams: Int) -> Double {
        let (bits, coding) = mcs[m]
        let nsd = subcarriers[std]![width]!
        return nsd * bits * coding * Double(min(streams, maxStreams[std]!)) / symbolUs[std]!
    }

    public static func noiseFloorDbm(width: Int, noiseFigure: Double = 7) -> Double { -174 + 10 * log10(Double(width) * 1e6) + noiseFigure }

    /// A reusable table for one link shape: the throughput lookup is a binary search, not a rebuild.
    public struct Table: Sendable {
        let rates: [Double]
        let thresholds: [Double]
        let macEff: Double
        public init(_ std: WifiStandard, width: Int, streams: Int, macEff: Double = Rates.macEfficiency) {
            let top = Rates.maxMcs[std]!
            rates = (0...top).map { Rates.phyRate(mcs: $0, std, width: width, streams: streams) }
            thresholds = Array(Rates.minSnr[0...top])
            self.macEff = macEff
        }

        /// Throughput in Mbit/s at this SNR (0 below MCS 0).
        public func throughput(_ snr: Double) -> Double {
            if snr.isNaN { return 0 }
            var lo = 0, hi = thresholds.count        // highest threshold <= snr
            while lo < hi { let mid = (lo + hi) / 2; if thresholds[mid] <= snr { lo = mid + 1 } else { hi = mid } }
            return lo > 0 ? rates[lo - 1] * macEff : 0
        }
    }
}
