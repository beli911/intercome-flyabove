import AVFoundation
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

final class QRScannerViewController: UIViewController {
    var onCode: ((String) -> Void)?
    var onUnavailable: ((String) -> Void)?

    private let session = AVCaptureSession()
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
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            onUnavailable?("A kamera nem érhető el ezen az eszközön.")
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            onUnavailable?("A QR-olvasó nem indítható.")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        // Set after adding the output, or the type is not yet available.
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !session.isRunning, !session.inputs.isEmpty else { return }
        // Starting a capture session blocks, so it must not happen on the main
        // thread. `AVCaptureSession` is not Sendable, but it is documented as
        // safe to drive from one background queue at a time, and this is the
        // only place that starts or stops it.
        let session = session
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    fileprivate func report(_ value: String) {
        guard !hasReported else { return }
        hasReported = true
        session.stopRunning()
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
