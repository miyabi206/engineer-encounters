import AVFoundation
import SwiftUI
import UIKit

@MainActor
enum QRCameraAccess {
    static var current: QRCameraPermission {
        QRPermissionMapping.permission(authorizationRawValue: AVCaptureDevice.authorizationStatus(for: .video).rawValue)
    }
    static func request() async -> QRCameraPermission {
        if current == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .video) }
        return current
    }
}

@MainActor
struct QRScannerView: UIViewControllerRepresentable {
    let isScanning: Bool
    let onScan: @MainActor @Sendable (String) -> Void
    let onFailure: @MainActor @Sendable () -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        QRScannerController(onScan: onScan, onFailure: onFailure)
    }
    func updateUIViewController(_ controller: QRScannerController, context: Context) {
        controller.setScanning(isScanning)
    }
    static func dismantleUIViewController(_ controller: QRScannerController, coordinator: Void) {
        controller.setScanning(false)
    }
}

@MainActor
final class QRScannerController: UIViewController {
    private let worker: QRCaptureWorker
    private let preview: AVCaptureVideoPreviewLayer
    private var scanning = false

    init(onScan: @escaping @MainActor @Sendable (String) -> Void,
         onFailure: @escaping @MainActor @Sendable () -> Void) {
        worker = QRCaptureWorker(onScan: onScan, onFailure: onFailure)
        preview = AVCaptureVideoPreviewLayer(session: worker.session)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        view.isAccessibilityElement = true
        view.accessibilityLabel = SessionStrings.text(.cameraPreview)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview.frame = view.bounds
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        worker.setRunning(scanning)
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        worker.setRunning(false)
    }
    func setScanning(_ value: Bool) {
        scanning = value
        worker.setRunning(value && viewIfLoaded?.window != nil)
    }
}

/// AVFoundation supports a preview on the main thread and session work on a serial queue.
/// Every mutable capture/configuration/delegate operation below is confined to `queue`.
/// Sendability only permits queue submission; it does not allow concurrent capture mutations.
final class QRCaptureWorker: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "EngineerEncounters.QR.camera")
    private let onScan: @MainActor @Sendable (String) -> Void
    private let onFailure: @MainActor @Sendable () -> Void
    private var configured = false
    private var delivered = false

    init(onScan: @escaping @MainActor @Sendable (String) -> Void,
         onFailure: @escaping @MainActor @Sendable () -> Void) {
        self.onScan = onScan; self.onFailure = onFailure
    }

    func setRunning(_ running: Bool) {
        queue.async { [self] in
            if running {
                guard configure() else {
                    Task { @MainActor [onFailure] in onFailure() }
                    return
                }
                delivered = false
                if !session.isRunning { session.startRunning() }
            } else if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() -> Bool {
        if configured { return true }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let output = AVCaptureMetadataOutput()
        guard session.canAddInput(input) else { return false }
        session.addInput(input)
        guard session.canAddOutput(output) else { session.removeInput(input); return false }
        session.addOutput(output)
        guard output.availableMetadataObjectTypes.contains(.qr) else {
            session.removeInput(input); session.removeOutput(output); return false
        }
        output.setMetadataObjectsDelegate(self, queue: queue)
        output.metadataObjectTypes = [.qr]
        configured = true
        return true
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !delivered,
              let value = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        delivered = true
        // Stop before handing off to the UI, avoiding repeated redemptions of the same frame.
        if session.isRunning { session.stopRunning() }
        Task { @MainActor [onScan] in onScan(value) }
    }
}
