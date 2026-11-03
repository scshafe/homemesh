import Foundation
import Testing
@testable import HomemeshCore

func golden(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Golden") else { throw CocoaError(.fileNoSuchFile) }
    return try Data(contentsOf: url)
}

struct PropCase: Decodable {
    struct G: Decodable { var x0, y0, step: Double; var nx, ny: Int; var z: Double }
    var fixture: String
    var grid_level: String
    var tx: [Double]
    var band: String
    var grid: G
    var n: [String: Double]
    var extra_loss: [String: Double]
    var loss: [Double]
    var mask: [Bool]
}

@Test func propagationMatchesThePythonOracle() throws {
    let cases = try JSONDecoder().decode([PropCase].self, from: golden("propagation"))
    #expect(cases.count > 20)
    var houses: [String: PropagationModel] = [:]
    var worst = 0.0
    for c in cases {
        if houses[c.fixture] == nil { houses[c.fixture] = PropagationModel(try House.load(golden("\(c.fixture).house"))) }
        let model = houses[c.fixture]!
        let grid = Grid(level: c.grid_level, x0: c.grid.x0, y0: c.grid.y0, step: c.grid.step, nx: c.grid.nx, ny: c.grid.ny, z: c.grid.z)
        let rx = grid.points().map { Vec3($0.x, $0.y, grid.z) }
        let band = Band(rawValue: c.band)!
        let params = PropParams(n: Dictionary(uniqueKeysWithValues: c.n.map { (Band(rawValue: $0.key)!, $0.value) }),
                                extraLoss: Dictionary(uniqueKeysWithValues: c.extra_loss.map { (Band(rawValue: $0.key)!, $0.value) }))
        let got = model.pathLoss(tx: Vec3(c.tx[0], c.tx[1], c.tx[2]), rx: rx, band: band, params: params)
        #expect(got.count == c.loss.count)
        for (g, w) in zip(got, c.loss) { worst = max(worst, abs(g - w)) }
        #expect(model.gridMask(grid) == c.mask)
    }
    #expect(worst < 1e-6, "largest difference from Python: \(worst) dB")
}

struct RateCase: Decodable { var standard: String; var width, streams: Int; var snr: [Double]; var rate: [Double] }

@Test func ratesMatchThePythonOracle() throws {
    for c in try JSONDecoder().decode([RateCase].self, from: golden("rates")) {
        let t = Rates.Table(WifiStandard(rawValue: c.standard)!, width: c.width, streams: c.streams)
        for (s, w) in zip(c.snr, c.rate) { #expect(abs(t.throughput(s) - w) < 1e-6, "\(c.standard) \(c.width) x\(c.streams) at \(s) dB") }
    }
}
