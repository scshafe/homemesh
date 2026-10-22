import ARKit
import os
import RoomPlan
import SwiftUI

/// Keeps the screen from dimming and locking while a room is being scanned. `hold` is idempotent and every exit
/// of the scan calls `release`; `apply` is injectable so the lifecycle can be unit-tested.
@MainActor
final class ScreenAwake {
    static let shared = ScreenAwake { UIApplication.shared.isIdleTimerDisabled = $0 }
    private let apply: (Bool) -> Void
    private(set) var held = false
    init(apply: @escaping (Bool) -> Void) { self.apply = apply }
    func hold() { MainActor.assertIsolated("the idle timer is UIKit state: main actor only"); guard !held else { return }; held = true; apply(true) }
    func release() { MainActor.assertIsolated("the idle timer is UIKit state: main actor only"); guard held else { return }; held = false; apply(false) }
}

/// When a RoomPlan session has had enough: the scene limit is not observable, so the signals are rooms and time.
enum SessionBudget {
    static let maxRooms = 4
    static let maxSeconds: TimeInterval = 6 * 60
    static func exhausted(rooms: Int, seconds: TimeInterval) -> Bool { rooms >= maxRooms || seconds >= maxSeconds }
}

/// Wraps Apple's RoomCaptureView and collects the rooms of one scanning session.
///
/// One controller, one RoomCaptureView and one ARSession live for the whole multi-room scan (the screen keeps
/// the view on screen the whole time; it is never presented and dismissed between rooms). Between rooms the
/// session is stopped with `pauseARSession: false`, so the next run continues in the same world frame and
/// rooms share one coordinate frame, as in Apple's multi-room sample. Starting a room while the previous run
/// is still stopping is refused, and every transition is logged (Console: subsystem `homemesh.capture`).
final class ScanController: UIViewController, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
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
    /// The session cannot go on (an error such as the scene size limit, or a start or stop that hung). The
    /// controller has already shut its AR session down and must not be used again: the owner of the controller
    /// replaces it. `salvaged` is the room scanned so far, when RoomPlan could still build it.
    var onSessionLost: ((String, CapturedRoom?) -> Void)?

    /// RoomPlan stops a session whose scene grows too large ("Capture scene exceeded limit"), and a very long one
    /// gets slow. The measurable signals are rooms scanned and time spent scanning in this session; past either,
    /// the next room should start a new session.
    private(set) var roomsDone = 0
    private(set) var scanSeconds: TimeInterval = 0
    var wantsFreshSession: Bool { SessionBudget.exhausted(rooms: roomsDone, seconds: scanSeconds) }
    private(set) var lost = false
    static let startTimeout: Duration = .seconds(8)
    static let stopTimeout: Duration = .seconds(45)
    private var watchdog: Task<Void, Never>?

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
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appLeft), name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(appBack), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// The app is leaving the foreground (home, lock, call): the system takes over the timer, we stop holding it.
    @objc private func appLeft() { ScreenAwake.shared.release() }
    @objc private func appBack() { if phase == .running { ScreenAwake.shared.hold() } }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        shutdown()
    }

    /// Ends the scan for good: stops the session and pauses the AR session, which releases the camera. A new scan
    /// gets a new controller (and so a new RoomCaptureView, session and world frame), never a paused one.
    func shutdown() {
        monitor?.cancel()
        monitor = nil
        watchdog?.cancel()
        watchdog = nil
        Self.log.notice("shutdown from phase \(self.phase.rawValue, privacy: .public): pausing the AR session")
        captureView.captureSession.stop(pauseARSession: true)
        phase = .idle
        ScreenAwake.shared.release()
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
        MainActor.assertIsolated("scan state is changed on the main actor only")
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
        guard !lost else {
            Self.log.error("start refused: this session is lost")
            return
        }
        runSignpost = Self.signposter.beginInterval("run")
        sessionStarted = false
        wallsSeen = 0
        runStarted = Date()
        set(.running)
        ScreenAwake.shared.hold()
        startMonitor()
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        armWatchdog(Self.startTimeout, while: .running, expecting: "the camera session did not start") { [weak self] in self?.sessionStarted == false }
    }

    private var sessionStarted = false

    /// If `stillStuck` holds after `after`, the session is given up on rather than left to hang. Logged either way.
    private func armWatchdog(_ after: Duration, while phase: Phase, expecting what: String, stillStuck: @escaping @MainActor () -> Bool) {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: after)
            guard !Task.isCancelled, let self, self.phase == phase, stillStuck() else { return }
            Self.log.error("watchdog: \(what, privacy: .public) within \(String(describing: after), privacy: .public)")
            self.lose("The scanner stalled (\(what)). Start the next room again; it will use a new session.", data: nil)
        }
    }

    /// Gives up this session: stops everything, tries to keep what was scanned, tells the owner of the controller.
    private func lose(_ message: String, data: CapturedRoomData?) {
        MainActor.assertIsolated("a lost session is handled on the main actor")
        guard !lost else { return }
        lost = true
        if let runSignpost { Self.signposter.endInterval("run", runSignpost) }
        runSignpost = nil
        let hadWalls = wallsSeen > 0
        shutdown()
        onPhase?(.idle)
        guard let data, hadWalls else { onSessionLost?(message, nil); return }
        Task { @MainActor [weak self] in
            let room = try? await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
            Self.log.notice("salvage after a lost session: \(room == nil ? "failed" : "\(room!.walls.count) wall(s)", privacy: .public)")
            self?.onSessionLost?(message, room)
        }
    }

    /// Ends this room. The AR session keeps running, so the next room continues in the same frame.
    func stop() {
        guard phase == .running else { return }
        stopSignpost = Self.signposter.beginInterval("stop and process")
        set(.stopping)
        scanSeconds += Date().timeIntervalSince(runStarted)
        ScreenAwake.shared.release()
        monitor?.cancel()
        onHint?("")
        captureView.captureSession.stop(pauseARSession: false)
        armWatchdog(Self.stopTimeout, while: .stopping, expecting: "processing the room took too long") { true }
    }

    // MARK: RoomCaptureSessionDelegate and RoomCaptureViewDelegate
    //
    // RoomPlan calls these on its own serial queue (com.apple.RoomPlan.FloorPlanCaptureSession), not on the main
    // thread. Every one is `nonisolated`, touches no state, and hops to the main actor before doing anything, so
    // the UIKit and view state work (idle timer, view teardown, SwiftUI callbacks) always runs on main.

    nonisolated func captureSession(_ session: RoomCaptureSession, didStartWith configuration: RoomCaptureSession.Configuration) {
        Task { @MainActor in self.sessionDidStart() }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        let walls = room.walls.count
        Task { @MainActor in self.wallsSeen = walls }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        let box = Unchecked((data, error))
        Task { @MainActor in self.sessionDidEnd(data: box.value.0, error: box.value.1) }
    }

    nonisolated func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        if let error {
            Self.log.error("not presenting: \(error.localizedDescription, privacy: .public)")
            return false
        }
        return true
    }

    nonisolated func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        let box = Unchecked((processedResult, error))
        Task { @MainActor in self.viewDidPresent(box.value.0, error: box.value.1) }
    }

    private func sessionDidStart() {
        MainActor.assertIsolated("RoomPlan callbacks must be handled on the main actor")
        Self.log.notice("session started")
        sessionStarted = true
        watchdog?.cancel()
    }

    private func sessionDidEnd(data: CapturedRoomData, error: Error?) {
        guard !lost else { return }
        if let error {
            let exceeded = (error as? RoomCaptureSession.CaptureError) == .exceedSceneSizeLimit
            let ns = error as NSError
            Self.log.error("session ended with error: \(error.localizedDescription, privacy: .public) (\(ns.domain, privacy: .public) \(ns.code), size limit: \(exceeded))")
            lose(exceeded
                 ? "RoomPlan's scene size limit was reached. The next room starts a new session (a new frame) and is placed by the usual placement step."
                 : "The scan stopped: \(error.localizedDescription). The next room starts a new session.", data: data)
            return
        }
        if let runSignpost { Self.signposter.endInterval("run", runSignpost) }
        runSignpost = nil
        Self.log.notice("session ended; the room is being processed")
    }

    private func viewDidPresent(_ processedResult: CapturedRoom, error: Error?) {
        guard !lost else { return }
        watchdog?.cancel()
        if let stopSignpost { Self.signposter.endInterval("stop and process", stopSignpost) }
        stopSignpost = nil
        set(.idle)
        if let error {
            Self.log.error("processing failed: \(error.localizedDescription, privacy: .public)")
            onError?(error.localizedDescription)
            return
        }
        roomsDone += 1
        Self.log.notice("room processed: \(processedResult.walls.count) wall(s); \(self.roomsDone) in this session, \(Int(self.scanSeconds)) s scanned")
        onProcessed?(processedResult)
    }
}

/// A value handed from RoomPlan's queue to the main actor. RoomPlan's result types are not declared Sendable; each
/// value is used only after the hop and never touched on the queue again.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

struct ScanView: UIViewControllerRepresentable {
    let controller: ScanController
    func makeUIViewController(context: Context) -> ScanController { controller }
    func updateUIViewController(_ uiViewController: ScanController, context: Context) {}
}
