import ADFAtlassianAuth
import AVFoundation
import SwiftUI
import UIKit

/// "Scan from Mac": scans the pairing code `adf-auth push` shows on the Mac
/// (or takes the pasted link on devices without a camera, such as the
/// Simulator), fetches the sealed credential from the Mac once over the
/// local network, asks "Add <site> as <email>?", and only on Add checks the
/// token with Atlassian and saves it.
///
/// The pairing link carries the one-time key in its fragment, so it is never
/// shown, logged or kept after the fetch; the credential's token is held
/// only while the confirmation is on screen and never shown.
struct PairScanView: View {
    private enum Phase: Equatable {
        case scanning
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

    @Environment(AccountStore.self) private var accounts
    @Environment(\.dismiss) private var dismiss
    @State private var phase = Phase.scanning
    @State private var camera = Camera.starting
    @State private var scanner: CameraScanner?
    /// The last payload ignored, so a code held in front of the camera (the
    /// scanner reports it every frame) is judged once, not per frame.
    @State private var lastIgnoredPayload: String?
    @State private var hint: String?
    /// The running fetch from the Mac, cancelled by its Cancel button or by
    /// leaving the screen.
    @State private var fetchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 16) {
            cameraArea
            statusArea
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
            if case .success = phase {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 96))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
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
                Button("Paste Link", systemImage: "doc.on.clipboard", action: pasteLink)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("pair-paste")
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
                Button("Try Again", action: tryAgain)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("pair-try-again")
            }
        }
    }

    private func confirmation(_ credential: AtlassianCredential, replacingEmail: String?) -> some View {
        VStack(spacing: 12) {
            Text(verbatim: "Add \(credential.site.host) as \(credential.email)?")
                .font(.headline)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("pair-confirm-title")
            if let expiresAt = credential.expiresAt {
                Text(verbatim: "Token expires \(expiresAt.formatted(date: .abbreviated, time: .omitted)).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let replacingEmail {
                Label {
                    Text(verbatim: "This replaces the account for \(credential.site.host) signed in as \(replacingEmail).")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                }
                .font(.callout)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("pair-confirm-replace-warning")
            }
            HStack(spacing: 12) {
                Button("Cancel", role: .cancel, action: cancelConfirmation)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("pair-confirm-cancel")
                Button("Add") { add(credential) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("pair-confirm-add")
            }
        }
    }

    // MARK: - Payloads

    /// Camera and paste both land here. Only `adfreader://pair?` payloads
    /// are considered; the first one stops the scanner — a valid link starts
    /// the fetch, a malformed or rejected one (for example a host outside
    /// the private LAN ranges) shows why in `pair-error`.
    private func handle(payload: String) {
        guard phase == .scanning, payload != lastIgnoredPayload else { return }
        guard payload.hasPrefix(Self.pairingPrefix) else {
            lastIgnoredPayload = payload
            hint = "That code isn't an ADFReader pairing code. Scan the one adf-auth push shows."
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
            lastIgnoredPayload = payload
            phase = .failure(error.message)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        phase = .fetching
        fetchTask = Task { await fetch(link) }
    }

    private func pasteLink() {
        let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard text.hasPrefix(Self.pairingPrefix) else {
            hint = "The clipboard doesn't hold an ADFReader pairing link. On your Mac run adf-auth push --print-link and copy the link it prints."
            return
        }
        // A pasted link is judged again even if the camera ignored it.
        lastIgnoredPayload = nil
        handle(payload: text)
    }

    /// One GET to the Mac (its user confirms there), then the confirmation
    /// step. Nothing is saved here.
    private func fetch(_ link: PairingLink) async {
        do {
            let credential = try await HandoffClient.fetch(link, session: accounts.session)
            guard Task.isCancelled == false else { return }
            accounts.reload()
            let existing = accounts.summary(for: credential.site)
            let replacingEmail = existing.flatMap {
                $0.email.caseInsensitiveCompare(credential.email) == .orderedSame ? nil : $0.email
            }
            phase = .confirming(credential, replacingEmail: replacingEmail)
        } catch {
            guard Task.isCancelled == false else { return }
            phase = .failure(error.message)
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

    private func cancelFetch() {
        fetchTask?.cancel()
        fetchTask = nil
        tryAgain()
    }

    /// Discards the fetched credential unsaved. The pairing code is spent,
    /// so adding it later takes a new `adf-auth push`.
    private func cancelConfirmation() {
        tryAgain()
        hint = "Nothing was saved. Run adf-auth push again to add the account."
    }

    private func tryAgain() {
        phase = .scanning
        hint = nil
        scanner?.start()
    }

    // MARK: - Camera lifecycle

    private func startCameraIfPossible() async {
        guard scanner == nil else { return }
        guard AVCaptureDevice.default(for: .video) != nil else {
            camera = .unavailable("This device has no camera. On your Mac run adf-auth push --print-link, copy the link, then tap Paste Link.")
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
            camera = .unavailable("Camera access is off. Allow it in Settings, or run adf-auth push --print-link on your Mac, copy the link, then tap Paste Link.")
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
