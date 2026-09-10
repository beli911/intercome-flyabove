@preconcurrency import AVFoundation
import SwiftUI

/// Live camera preview that reports the first QR code it reads.
///
/// Deliberately narrow: it emits a string and stops. Deciding what a code means
/// is not a camera's job.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onUnavailable: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onCode = onCode
        controller.onUnavailable = onUnavailable
        return controller
    }

    func updateUIViewController(_: QRScannerViewController, context _: Context) {}
}

private final class QRScannerSessionCoordinator: @unchecked Sendable {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "hu.flyabove.qrscanner.session")
    private var isDisposed = false

    func configure(
        delegate: AVCaptureMetadataOutputObjectsDelegate,
        onUnavailable: @escaping @MainActor (String) -> Void
    ) {
        sessionQueue.async { [weak self] in
            guard let self, !self.isDisposed else { return }
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input)
            else {
                Task { @MainActor in
                    onUnavailable("A kamera nem érhető el ezen az eszközön.")
                }
                return
            }
            self.session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard self.session.canAddOutput(output) else {
                Task { @MainActor in
                    onUnavailable("A QR-olvasó nem indítható.")
                }
                return
            }
            self.session.addOutput(output)
            output.setMetadataObjectsDelegate(delegate, queue: .main)
            // Set after adding the output, or the type is not yet available.
            output.metadataObjectTypes = [.qr]
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self, !self.isDisposed else { return }
            guard !self.session.inputs.isEmpty else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    /// Stops the camera but keeps the session usable.
    ///
    /// Deliberately separate from `dispose()`. Leaving the view is not the end
    /// of the scanner: the sheet can come back, and a scan that failed can be
    /// tried again. A `stop` that also disposed made the second appearance a
    /// black preview with no error at all — nothing to see and nothing to read.
    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, !self.isDisposed else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    /// Final teardown: after this the coordinator never starts again.
    func dispose() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.isDisposed = true
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }
}

final class QRScannerViewController: UIViewController {
    var onCode: ((String) -> Void)?
    var onUnavailable: ((String) -> Void)?

    private let coordinator = QRScannerSessionCoordinator()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    /// One code per presentation: a scanner that keeps firing turns a single
    /// glance at a poster into a stream of redemption attempts.
    private var hasReported = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configure()
    }

    private func configure() {
        let layer = AVCaptureVideoPreviewLayer(session: coordinator.session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer

        coordinator.configure(delegate: self) { [weak self] message in
            self?.onUnavailable?(message)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        coordinator.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        coordinator.stop()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    deinit {
        // The camera must not outlive the controller: an AVCaptureSession left
        // running keeps the hardware and the green indicator on.
        coordinator.dispose()
    }

    fileprivate func report(_ value: String) {
        guard !hasReported else { return }
        hasReported = true
        // One code per presentation, so this really is the end of this scanner.
        coordinator.dispose()
        onCode?(value)
    }
}

extension QRScannerViewController: AVCaptureMetadataOutputObjectsDelegate {
    // The delegate is registered on the main queue, so this genuinely does run
    // there; the protocol just does not say so.
    nonisolated func metadataOutput(
        _: AVCaptureMetadataOutput,
        didOutput objects: [AVMetadataObject],
        from _: AVCaptureConnection
    ) {
        guard let object = objects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue
        else { return }
        MainActor.assumeIsolated { report(value) }
    }
}
