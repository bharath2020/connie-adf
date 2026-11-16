import AVFoundation
import SwiftUI

// Camera QR plumbing shared by ADF Beam (`ScanView`) and the Atlassian
// pairing scanner (`PairScanView`). The scanner forwards every QR payload of
// every frame; de-duplication is the caller's job (ADF Beam's
// `ChunkCollector` reports duplicates, `PairScanView` keeps the first valid
// pairing link and stops).

/// Owns the capture session on a private queue and forwards QR payloads to
/// the main actor. `@unchecked Sendable`: the session is only mutated on
/// `queue`, and `onPayload` is an immutable `let`.
final class CameraScanner: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "adf-beam.camera-scanner")
    private let onPayload: @MainActor (String) -> Void
    private var configured = false

    init(onPayload: @escaping @MainActor (String) -> Void) {
        self.onPayload = onPayload
    }

    func start() {
        queue.async {
            self.configureIfNeeded()
            if self.session.isRunning == false {
                self.session.startRunning()
            }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    private func configureIfNeeded() {
        guard configured == false else { return }
        configured = true
        guard
            let device = AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else { return }
        session.beginConfiguration()
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            if output.availableMetadataObjectTypes.contains(.qr) {
                output.metadataObjectTypes = [.qr]
            }
        }
        session.commitConfiguration()
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let payloads = metadataObjects
            .compactMap { $0 as? AVMetadataMachineReadableCodeObject }
            .filter { $0.type == .qr }
            .compactMap(\.stringValue)
        guard payloads.isEmpty == false else { return }
        // The delegate queue is the main queue (set in configureIfNeeded).
        MainActor.assumeIsolated {
            for payload in payloads {
                onPayload(payload)
            }
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
