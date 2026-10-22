import ARKit
import os
import RoomPlan
import SwiftUI

/// Wraps Apple's RoomCaptureView and collects the rooms of one scanning session.
///
/// One controller, one RoomCaptureView and one ARSession live for the whole multi-room scan (the screen keeps
/// the view on screen the whole time; it is never presented and dismissed between rooms). Between rooms the
/// session is stopped with `pauseARSession: false`, so the next run continues in the same world frame and
/// rooms share one coordinate frame, as in Apple's multi-room sample. Starting a room while the previous run
/// is still stopping is refused, and every transition is logged (Console: subsystem `homemesh.capture`).
final class ScanController: UIViewController, @preconcurrency RoomCaptureViewDelegate, @preconcurrency RoomCaptureSessionDelegate {
    // RoomCaptureViewDelegate refines NSCoding; UIViewController already encodes itself.
    required init?(coder: NSCoder) { fatalError("not used") }
    init() { super.init(nibName: nil, bundle: nil) }

    nonisolated static let log = Logger(subsystem: "homemesh.capture", category: "scan")
    nonisolated static let signposter = OSSignposter(subsystem: "homemesh.capture", category: "scan")

    enum Phase: String { case idle, running, stopping }

    let captureView = RoomCaptureView(frame: .zero)
    private(set) var phase = Phase.idle
    var onProcessed: ((CapturedRoom) -> Void)?
    var onError: ((String) -> Void)?
    var onPhase: ((Phase) -> Void)?
    /// A visible message while scanning ("" clears it): limited tracking, or no walls detected after a while.
    var onHint: ((String) -> Void)?

    private var monitor: Task<Void, Never>?
    private var runStarted = Date()
    private var wallsSeen = 0

    private var runSignpost: OSSignpostIntervalState?
    private var stopSignpost: OSSignpostIntervalState?

    override func viewDidLoad() {
        super.viewDidLoad()
        captureView.frame = view.bounds
        captureView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        captureView.delegate = self
        captureView.captureSession.delegate = self
        view.addSubview(captureView)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        shutdown()
    }

    /// Ends the scan for good: stops the session and pauses the AR session, which releases the camera. A new scan
    /// gets a new controller (and so a new RoomCaptureView, session and world frame), never a paused one.
    func shutdown() {
        monitor?.cancel()
        monitor = nil
        Self.log.notice("shutdown from phase \(self.phase.rawValue, privacy: .public): pausing the AR session")
        captureView.captureSession.stop(pauseARSession: true)
        phase = .idle
    }

    private func startMonitor() {
        monitor?.cancel()
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    private func tick() {
        guard phase == .running else { return }
        switch captureView.captureSession.arSession.currentFrame?.camera.trackingState {
        case .limited(let reason)?:
            Self.log.notice("tracking limited: \(String(describing: reason), privacy: .public)")
            onHint?("Tracking is limited (\(Self.describe(reason))). Move slowly and keep walls and furniture in view.")
        case .notAvailable?:
            onHint?("The camera has no tracking. Check that nothing covers it and that the room is lit.")
        default:
            if wallsSeen == 0 && Date().timeIntervalSince(runStarted) > 15 {
                Self.log.error("no walls detected after 15 s")
                onHint?("No walls detected yet. Move closer to a wall and sweep slowly along it; if it stays empty, stop and start again.")
            } else {
                onHint?("")
            }
        }
    }

    private static func describe(_ r: ARCamera.TrackingState.Reason) -> String {
        switch r {
        case .excessiveMotion: return "moving too fast"
        case .insufficientFeatures: return "too few features: dim light or a blank wall"
        case .initializing: return "starting up"
        case .relocalizing: return "relocalizing"
        @unknown default: return "unknown"
        }
    }

    private func set(_ p: Phase) {
        Self.log.notice("scan phase \(self.phase.rawValue, privacy: .public) -> \(p.rawValue, privacy: .public)")
        phase = p
        onPhase?(p)
    }

    func start() {
        guard phase == .idle else {
            Self.log.error("start refused: phase is \(self.phase.rawValue, privacy: .public)")
            onError?("The previous room is still being processed; wait a moment and try again.")
            return
        }
        runSignpost = Self.signposter.beginInterval("run")
        wallsSeen = 0
        runStarted = Date()
        set(.running)
        startMonitor()
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    /// Ends this room. The AR session keeps running, so the next room continues in the same frame.
    func stop() {
        guard phase == .running else { return }
        stopSignpost = Self.signposter.beginInterval("stop and process")
        set(.stopping)
        monitor?.cancel()
        onHint?("")
        captureView.captureSession.stop(pauseARSession: false)
    }

    // MARK: RoomCaptureSessionDelegate

    func captureSession(_ session: RoomCaptureSession, didStartWith configuration: RoomCaptureSession.Configuration) {
        Self.log.notice("session started")
    }

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        wallsSeen = room.walls.count
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        if let runSignpost { Self.signposter.endInterval("run", runSignpost) }
        runSignpost = nil
        if let error {
            Self.log.error("session ended with error: \(error.localizedDescription, privacy: .public)")
            monitor?.cancel()
            set(.idle)
            onError?("The scan stopped: \(error.localizedDescription)")
        } else {
            Self.log.notice("session ended; the room is being processed")
        }
    }

    // MARK: RoomCaptureViewDelegate

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        if let error {
            Self.log.error("not presenting: \(error.localizedDescription, privacy: .public)")
            return false
        }
        return true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        if let stopSignpost { Self.signposter.endInterval("stop and process", stopSignpost) }
        stopSignpost = nil
        set(.idle)
        if let error {
            Self.log.error("processing failed: \(error.localizedDescription, privacy: .public)")
            onError?(error.localizedDescription)
            return
        }
        Self.log.notice("room processed: \(processedResult.walls.count) wall(s)")
        onProcessed?(processedResult)
    }
}

struct ScanView: UIViewControllerRepresentable {
    let controller: ScanController
    func makeUIViewController(context: Context) -> ScanController { controller }
    func updateUIViewController(_ uiViewController: ScanController, context: Context) {}
}
