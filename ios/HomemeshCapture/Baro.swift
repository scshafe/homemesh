import CoreMotion
import Foundation

/// The barometer: relative altitude and pressure, kept while a scan screen is open. Relative altitude counts from
/// when the sampler started, so readings are comparable only inside one `session` (one start of the app); the
/// pressure is also kept for a coarse comparison across sessions (see `FloorSuggestion`).
@MainActor
final class BaroSampler {
    static let shared = BaroSampler()
    private let altimeter = CMAltimeter()
    private let session = UUID().uuidString.prefix(8).lowercased()
    private var latest: (rel: Double, kpa: Double, at: Double)?
    private var running = false

    func start() {
        guard !running, CMAltimeter.isRelativeAltitudeAvailable() else { return }
        running = true
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            let r = (data.relativeAltitude.doubleValue, data.pressure.doubleValue, Date().timeIntervalSince1970)
            Task { @MainActor in self?.latest = r }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        altimeter.stopRelativeAltitudeUpdates()
    }

    /// The newest reading, or nil when the device has no barometer or has not delivered one yet.
    var reading: BaroReading? {
        latest.map { BaroReading(session: String(session), rel_m: $0.rel, kpa: $0.kpa, at: $0.at) }
    }
}
