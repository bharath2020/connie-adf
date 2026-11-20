import ADFAtlassianAuth
import AVFoundation
import CryptoKit
import SwiftUI
import UIKit

/// "Scan from Mac": scans the pairing code `adf-auth push` shows on the Mac,
/// fetches the sealed credential from the Mac once over the local network, asks "Add <site> as <email>?", and only on Add checks the
/// token with Atlassian and saves it.
///
/// The pairing link carries the one-time key in its fragment, so it is never
/// shown, logged or kept after the fetch; the credential's token is held
/// only while the confirmation is on screen and never shown.
struct PairScanView: View {
    private enum Phase: Equatable {
        case scanning
        /// The camera is stopped after a Cancel; "Scan Again" restarts it.
        /// Never restarted automatically, so a code still on the Mac's
        /// screen is not re-read behind the user's back.
        case paused(String)
        /// Waiting for the Mac, whose user must confirm the send.
        case fetching
        /// The credential arrived; nothing is saved until the user taps Add.
        /// `replacingEmail` is the stored account's email when one exists
        /// for the same site under a different email.
        case confirming(AtlassianCredential, replacingEmail: String?)
        case checking(site: String)
        case success(site: String, email: String)
        case failure(String)
    }

    private enum Camera: Equatable {
        case starting
        case running
        /// No camera on this device (the Simulator) or access denied.
        case unavailable(String)
    }

    static let pairingPrefix = "adfreader://pair?"
    static let spentMessage = "This code was already used — run adf-auth push again on your Mac."

    @Environment(AccountStore.self) private var accounts
    @Environment(\.dismiss) private var dismiss
    @State private var phase = Phase.scanning
    @State private var camera = Camera.starting
    @State private var scanner: CameraScanner?
    /// The last payload ignored, so a code held in front of the camera (the
    /// scanner reports it every frame) is judged once, not per frame. A
    /// SHA-256, so a pairing link's one-time key is never kept.
    @State private var lastIgnoredDigest: SHA256.Digest?
    /// Codes known to be spent (SHA-256 of the payload): served once (200),
    /// or answered 404/410. The camera ignores them; any other failed or
    /// cancelled fetch leaves the code valid, so Try Again can use it.
    @State private var spentDigests: Set<SHA256.Digest> = []
    @State private var hint: String?
    /// The running fetch from the Mac, cancelled by its Cancel button or by
    /// leaving the screen.
    @State private var fetchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 16) {
            if showsCameraArea {
                cameraArea
            } else {
                // Past scanning the camera (or its "unavailable" placeholder)
                // is gone, and the state's content sits centred on its own.
                Spacer(minLength: 0)
                if case .success = phase {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 96))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityHidden(true)
                }
            }
            statusArea
            if showsCameraArea == false {
                Spacer(minLength: 0)
            }
        }
        .padding()
        .navigationTitle("Scan from Mac")
        .navigationBarTitleDisplayMode(.inline)
        .task { await startCameraIfPossible() }
        .onDisappear {
            scanner?.stop()
            fetchTask?.cancel()
            fetchTask = nil
        }
        .animation(.snappy, value: phase)
    }

    // MARK: - Camera

    /// The camera preview or its placeholder shows only while the user is
    /// choosing a code: scanning, or paused after a Cancel.
    private var showsCameraArea: Bool {
        switch phase {
        case .scanning, .paused:
            return true
        case .fetching, .confirming, .checking, .success, .failure:
            return false
        }
    }

    @ViewBuilder
    private var cameraArea: some View {
        ZStack {
            switch camera {
            case .running:
                if let scanner {
                    CameraPreview(session: scanner.session)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            case .starting:
                RoundedRectangle(cornerRadius: 16)
                    .fill(.quaternary)
            case .unavailable(let reason):
                RoundedRectangle(cornerRadius: 16)
                    .fill(.quaternary)
                    .overlay {
                        ContentUnavailableView(
                            "Camera Unavailable",
                            systemImage: "camera.on.rectangle",
                            description: Text(reason)
                        )
                    }
                    .accessibilityIdentifier("pair-camera-unavailable")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Status

    @ViewBuilder
    private var statusArea: some View {
        switch phase {
        case .scanning:
            VStack(spacing: 10) {
                VStack(spacing: 4) {
                    Text("On your Mac run:")
                    Text(verbatim: "adf-auth push")
                        .font(.body.monospaced().weight(.semibold))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("pair-instructions")
                Text("Then scan the code it shows. The code holds a one-time key, not your token.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let hint {
                    Label(hint, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("pair-hint")
                }
            }
        case .paused(let message):
            VStack(spacing: 10) {
                Label(message, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("pair-paused")
                Button("Scan Again", systemImage: "qrcode.viewfinder", action: scanAgain)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("pair-scan-again")
            }
        case .fetching:
            VStack(spacing: 12) {
                ProgressView("Waiting for your Mac — confirm on the Mac")
                    .accessibilityIdentifier("pair-progress")
                Text("adf-auth push asks on the Mac before it sends anything.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Cancel", role: .cancel, action: cancelFetch)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("pair-fetch-cancel")
            }
        case .confirming(let credential, let replacingEmail):
            confirmation(credential, replacingEmail: replacingEmail)
        case .checking(let site):
            ProgressView("Checking the token for \(site)…")
                .accessibilityIdentifier("pair-progress")
        case .success(let site, let email):
            VStack(spacing: 12) {
                Text(verbatim: "Connected to \(site) as \(email)")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("pair-success")
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("pair-done")
            }
        case .failure(let message):
            VStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("pair-error")
                Button("Try Again", action: scanAgain)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("pair-try-again")
            }
        }
    }

    private func confirmation(_ credential: AtlassianCredential, replacingEmail: String?) -> some View {
        CredentialConfirmation(
            credential: credential,
            replacingEmail: replacingEmail,
            identifierPrefix: "pair",
            onCancel: cancelConfirmation,
            onAdd: { add(credential) }
        )
    }

    // MARK: - Payloads

    /// Each scanned payload lands here. Only `adfreader://pair?` payloads
    /// are considered; the first new one stops the scanner — a valid link
    /// starts the fetch, a malformed or rejected one (for example a host
    /// outside the private LAN ranges) shows why in `pair-error`. A code
    /// the Mac already served is never fetched again.
    private func handle(payload: String) {
        guard phase == .scanning else { return }
        let digest = SHA256.hash(data: Data(payload.utf8))
        guard digest != lastIgnoredDigest else { return }
        guard payload.hasPrefix(Self.pairingPrefix) else {
            lastIgnoredDigest = digest
            hint = "That code isn't an ADFReader pairing code. Scan the one adf-auth push shows."
            return
        }
        if spentDigests.contains(digest) {
            // The code on the Mac's screen was already sent: say so and keep
            // scanning for a new one.
            lastIgnoredDigest = digest
            hint = Self.spentMessage
            return
        }
        scanner?.stop()
        hint = nil
        let link: PairingLink
        do {
            link = try PairingLink(string: payload)
        } catch {
            // Remembered so Try Again doesn't re-reject the same code
            // still in front of the camera on its next frame.
            lastIgnoredDigest = digest
            phase = .failure(error.message)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        phase = .fetching
        fetchTask = Task { await fetch(link, digest: digest) }
    }

    /// One GET to the Mac (its user confirms there), then the confirmation
    /// step. Nothing is saved here.
    private func fetch(_ link: PairingLink, digest: SHA256.Digest) async {
        do {
            let credential = try await HandoffClient.fetch(link, session: accounts.session)
            // Served once: the Mac's listener has stopped.
            spentDigests.insert(digest)
            guard Task.isCancelled == false else { return }
            phase = .confirming(credential, replacingEmail: accounts.replacedEmail(by: credential))
        } catch {
            if error == .alreadyUsedOrExpired {
                spentDigests.insert(digest)
            }
            guard Task.isCancelled == false else { return }
            phase = .failure(error == .alreadyUsedOrExpired
                ? "This code was already used or has expired — run adf-auth push again on your Mac."
                : error.message)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        fetchTask = nil
    }

    /// Add: the GraphQL token check, then the keychain save.
    private func add(_ credential: AtlassianCredential) {
        phase = .checking(site: credential.site.host)
        Task {
            do {
                let summary = try await accounts.connect(credential)
                phase = .success(site: summary.site.host, email: summary.email)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                phase = .failure(AccountStore.message(for: error))
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    /// Stops waiting for the Mac. The camera stays off ("Scan Again"
    /// restarts it); the code stays valid until it expires on the Mac.
    private func cancelFetch() {
        fetchTask?.cancel()
        fetchTask = nil
        phase = .paused("Cancelled. Nothing was saved. To add the account, tap Scan Again and scan the code on your Mac.")
    }

    /// Discards the fetched credential unsaved. The pairing code is spent,
    /// so adding it later takes a new `adf-auth push`.
    private func cancelConfirmation() {
        phase = .paused("Nothing was saved. Run adf-auth push again on your Mac to add the account.")
    }

    /// Back to scanning. Codes the Mac already served stay ignored, so the
    /// one still on the Mac's screen shows the "already used" hint instead
    /// of being fetched again.
    private func scanAgain() {
        phase = .scanning
        hint = nil
        scanner?.start()
    }

    // MARK: - Camera lifecycle

    private func startCameraIfPossible() async {
        guard scanner == nil else { return }
        guard AVCaptureDevice.default(for: .video) != nil else {
            camera = .unavailable("This device has no camera. Add the account with Add Manually instead.")
            return
        }
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorized = true
        case .notDetermined:
            authorized = await AVCaptureDevice.requestAccess(for: .video)
        default:
            authorized = false
        }
        guard authorized else {
            camera = .unavailable("Camera access is off. Allow it in Settings, or add the account with Add Manually.")
            return
        }
        let scanner = CameraScanner { payload in
            handle(payload: payload)
        }
        self.scanner = scanner
        camera = .running
        scanner.start()
    }
}
