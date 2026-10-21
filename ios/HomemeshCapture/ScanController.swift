import RoomPlan
import SwiftUI

/// Wraps Apple's RoomCaptureView and collects the rooms of one scanning session.
/// Flow: Start -> walk the room -> Done (the view shows the processed room) -> Add room.
/// More rooms: Start again. Finish combines them with StructureBuilder (iOS 17) so they share one frame.
final class ScanController: UIViewController, RoomCaptureViewDelegate {
    // RoomCaptureViewDelegate refines NSCoding; UIViewController already encodes itself.
    required init?(coder: NSCoder) { fatalError("not used") }
    init() { super.init(nibName: nil, bundle: nil) }

    let captureView = RoomCaptureView(frame: .zero)
    var onProcessed: ((CapturedRoom) -> Void)?
    var onError: ((String) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        captureView.frame = view.bounds
        captureView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        captureView.delegate = self
        view.addSubview(captureView)
    }

    func start() {
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    func stop() {
        captureView.captureSession.stop()
    }

    // MARK: RoomCaptureViewDelegate

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool { true }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        if let error { onError?(error.localizedDescription); return }
        onProcessed?(processedResult)
    }
}

struct ScanView: UIViewControllerRepresentable {
    let controller: ScanController
    func makeUIViewController(context: Context) -> ScanController { controller }
    func updateUIViewController(_ uiViewController: ScanController, context: Context) {}
}
