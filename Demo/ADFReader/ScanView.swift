import ADFBeam
import AVFoundation
import SwiftUI

/// Scans ADF Beam QR frames (camera) or ingests pasted frame payloads (dev
/// path), collects chunks with live per-chunk progress and haptics, and on
/// completion writes the assembled JSON to a temp file and pushes the
/// existing `ReaderView` on it.
struct ScanView: View {
    private enum Phase: Equatable {
        case scanning
        case success
        case failure(String)
    }

    @State private var collector = ChunkCollector()
    @State private var phase = Phase.scanning
    @State private var receivedIndices: Set<Int> = []
    @State private var total = 0
    @State private var chunkEvent = 0
    @State private var hintVisible = false
    @State private var cameraAuthorized = false
    @State private var scanner: CameraScanner?
    @State private var pasteSheetVisible = false
    @State private var pastedText = ""
    @State private var scannedFixture: Fixture?

    var body: some View {
        VStack(spacing: 16) {
            cameraArea
            progressArea
        }
        .padding()
        .navigationTitle("Scan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Paste", systemImage: "doc.on.clipboard") {
                    pasteSheetVisible = true
                }
            }
        }
        .sheet(isPresented: $pasteSheetVisible) { pasteSheet }
        .navigationDestination(item: $scannedFixture) { fixture in
            ReaderView(source: .fixture(fixture), options: .none)
        }
        .task { await startCameraIfPossible() }
        .task(id: chunkEvent) { await updateIdleHint() }
        .onDisappear { scanner?.stop() }
    }

    // MARK: - Camera

    @ViewBuilder
    private var cameraArea: some View {
        ZStack {
            if let scanner, cameraAuthorized {
                CameraPreview(session: scanner.session)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.quaternary)
                    .overlay {
                        ContentUnavailableView(
                            "Camera Unavailable",
                            systemImage: "camera.on.rectangle",
                            description: Text("Use the Paste button to add frame payloads instead.")
                        )
                    }
            }
            if hintVisible, phase == .scanning {
                Text("Keep the code in frame")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity)
            }
            if phase == .success {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 96))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy, value: hintVisible)
        .animation(.snappy, value: phase)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Progress

    @ViewBuilder
    private var progressArea: some View {
        switch phase {
        case .failure(let message):
            VStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Scan Again") { resetScanner() }
                    .buttonStyle(.borderedProminent)
            }
        case .scanning, .success:
            VStack(spacing: 8) {
                segmentedProgressBar
                    .frame(height: 10)
                Text(total > 0
                    ? "\(receivedIndices.count) of \(total) chunks"
                    : "Point the camera at an ADF Beam code")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var segmentedProgressBar: some View {
        Canvas { context, size in
            let count = max(total, 1)
            let gap: CGFloat = count > 60 ? 0 : 2
            let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            for index in 0..<count {
                let rect = CGRect(
                    x: (width + gap) * CGFloat(index), y: 0,
                    width: width, height: size.height
                )
                let filled = total > 0 && receivedIndices.contains(index)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: min(3, width / 2)),
                    with: .color(filled ? .green : Color(.systemFill))
                )
            }
        }
    }

    // MARK: - Paste sheet

    private var pasteSheet: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Paste frame payloads (one `ADF1|…` line per frame).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TextEditor(text: $pastedText)
                    .font(.footnote.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                Button("Paste from Clipboard", systemImage: "doc.on.clipboard") {
                    if let text = UIPasteboard.general.string {
                        pastedText = text
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .navigationTitle("Paste Frames")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { pasteSheetVisible = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add Frames") {
                        let lines = pastedText.split(separator: "\n").map(String.init)
                        pastedText = ""
                        pasteSheetVisible = false
                        for line in lines {
                            ingest(payload: line.trimmingCharacters(in: .whitespaces))
                        }
                    }
                    .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - Chunk ingestion

    private func ingest(payload: String) {
        guard phase == .scanning else { return }
        guard let frame = try? BeamFrame(payload: payload) else { return }
        switch collector.accept(frame) {
        case .duplicate:
            return
        case .accepted, .reset:
            receivedIndices = collector.receivedIndices
            total = collector.total ?? 0
            chunkEvent += 1
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if collector.isComplete {
                finishScan()
            }
        }
    }

    private func finishScan() {
        do {
            let data = try BeamAssembler.assemble(collector)
            _ = try JSONSerialization.jsonObject(with: data)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Scanned Document.json")
            try data.write(to: url, options: .atomic)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            phase = .success
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                scannedFixture = Fixture(url: url)
            }
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            phase = .failure("Couldn't decode the scanned document. \(error.localizedDescription)")
        }
    }

    private func resetScanner() {
        collector.reset()
        receivedIndices = []
        total = 0
        hintVisible = false
        phase = .scanning
    }

    // MARK: - Idle hint

    private func updateIdleHint() async {
        hintVisible = false
        guard phase == .scanning, total > 0, receivedIndices.count < total else { return }
        try? await Task.sleep(for: .seconds(3))
        if Task.isCancelled == false, phase == .scanning {
            hintVisible = true
        }
    }

    // MARK: - Camera lifecycle

    private func startCameraIfPossible() async {
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorized = true
        case .notDetermined:
            authorized = await AVCaptureDevice.requestAccess(for: .video)
        default:
            authorized = false
        }
        cameraAuthorized = authorized
        guard authorized, scanner == nil else { return }
        let scanner = CameraScanner { payload in
            ingest(payload: payload)
        }
        self.scanner = scanner
        scanner.start()
    }
}

// MARK: - Camera plumbing

/// Owns the capture session on a private queue and forwards QR payloads to
/// the main actor. `@unchecked Sendable`: the session is only mutated on
/// `queue`, and `onPayload` is an immutable `let`.
private final class CameraScanner: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
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

private struct CameraPreview: UIViewRepresentable {
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
