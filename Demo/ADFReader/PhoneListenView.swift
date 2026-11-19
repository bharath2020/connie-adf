import ADFAtlassianAuth
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Mac connects to phone": for a Mac that blocks incoming connections
/// (common on company-managed Macs). The phone listens and shows
/// `adf-auth push --to <ip:port>` and a one-time code; the Mac connects out,
/// the user types the code there, and the sealed credential arrives here.
/// Then the same "Add <site> as <email>?" step as Scan from Mac; nothing is
/// saved until Add.
///
/// The listener (`PhoneHandoffListener`, one-shot, 5 minutes) runs only
/// while this screen is visible: leaving it, Cancel, or the app going to
/// the background stops it. While it listens the screen stays awake, so
/// Auto-Lock doesn't stop it while the user types on the Mac. The code is
/// shown, never logged.
struct PhoneListenView: View {
    private struct Listening: Equatable {
        /// `adf-auth push --to a.b.c.d:port`.
        var command: String
        /// `XXXX-XXXX-XXXX-XXXX`.
        var code: String
        var deadline: Date
        /// The latest event worth telling the user (a Mac connected, an
        /// attempt failed); nil while nothing has connected.
        var status: Status?
    }

    private struct Status: Equatable {
        var text: String
        var isProblem: Bool
    }

    private enum Phase: Equatable {
        case starting
        case listening(Listening)
        /// The listener started but this device has no private IPv4
        /// address (no Wi-Fi), so there is no command to show.
        case noNetwork
        /// The credential arrived; the listener has stopped. Nothing is
        /// saved until the user taps Add.
        case confirming(AtlassianCredential, replacingEmail: String?)
        case checking(site: String)
        case success(site: String, email: String)
        /// Stopped by the user (Cancel), the background, or a discarded
        /// credential. Try Again starts over with a new code.
        case stopped(String)
        /// Timed out, too many failed attempts, or the listener failed.
        case failure(String)
    }

    @Environment(AccountStore.self) private var accounts
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var phase = Phase.starting
    /// Bumped by Try Again: restarts the listening task with a new code.
    @State private var attempt = 0
    /// The running listener, so Cancel and the background can stop it.
    @State private var listener: PhoneHandoffListener?

    static let troubleshootingHint = """
    Nothing connecting? Keep this screen open, put the iPhone and the Mac on the same Wi-Fi \
    (this screen listens on Wi-Fi only, never on cellular or a VPN), \
    and check Settings > Privacy & Security > Local Network > ADFReader is on. \
    A company VPN that blocks local-network access on the Mac also prevents this; \
    then use Scan from Mac or Add Manually.
    """

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                content
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Mac connects to phone")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: attempt) { await listen() }
        .onAppear { keepScreenAwake(isListening) }
        .onDisappear {
            stop(showing: nil)
            keepScreenAwake(false)
        }
        .onChange(of: isListening) { _, listening in
            keepScreenAwake(listening)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background, isListening {
                stop(showing: "Stopped listening while ADFReader was in the background. Nothing was saved. Tap Try Again for a new code.")
            }
        }
        .animation(.snappy, value: phase)
    }

    private var isListening: Bool {
        switch phase {
        case .starting, .listening: return true
        default: return false
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .starting:
            ProgressView("Starting…")
                .padding(.top, 40)
                .accessibilityIdentifier("phone-listen-progress")
        case .listening(let listening):
            listeningView(listening)
        case .noNetwork:
            VStack(spacing: 12) {
                ContentUnavailableView(
                    "No Wi-Fi Address",
                    systemImage: "wifi.slash",
                    description: Text("This iPhone has no local-network address, so your Mac can't reach it. Join the same Wi-Fi as your Mac, then tap Try Again.")
                )
                .accessibilityIdentifier("phone-listen-no-network")
                tryAgainButton
            }
        case .confirming(let credential, let replacingEmail):
            CredentialConfirmation(
                credential: credential,
                replacingEmail: replacingEmail,
                identifierPrefix: "phone",
                onCancel: cancelConfirmation,
                onAdd: { add(credential) }
            )
            .padding(.top, 40)
        case .checking(let site):
            ProgressView("Checking the token for \(site)…")
                .padding(.top, 40)
                .accessibilityIdentifier("phone-listen-progress")
        case .success(let site, let email):
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 96))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text(verbatim: "Connected to \(site) as \(email)")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("phone-listen-success")
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("phone-listen-done")
            }
            .padding(.top, 40)
        case .stopped(let message):
            VStack(spacing: 12) {
                Label(message, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("phone-listen-stopped")
                tryAgainButton
            }
            .padding(.top, 40)
        case .failure(let message):
            VStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("phone-listen-error")
                Text(Self.troubleshootingHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                tryAgainButton
            }
            .padding(.top, 40)
        }
    }

    private func listeningView(_ listening: Listening) -> some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("On your Mac run:")
                    .foregroundStyle(.secondary)
                Text(verbatim: listening.command)
                    .font(.body.monospaced().weight(.semibold))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("phone-listen-command")
                Button("Copy Command", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = listening.command
                }
                .font(.footnote)
                .accessibilityIdentifier("phone-listen-copy-command")
            }
            VStack(spacing: 8) {
                Text("Then type this code on the Mac:")
                    .foregroundStyle(.secondary)
                Text(verbatim: listening.code)
                    .font(.system(.title, design: .monospaced).weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .textSelection(.enabled)
                    .speechSpellsOutCharacters()
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("phone-listen-code")
                Button("Copy Code", systemImage: "doc.on.doc") {
                    copyCode(listening.code, until: listening.deadline)
                }
                .font(.footnote)
                .accessibilityIdentifier("phone-listen-copy-code")
            }
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(verbatim: "Waiting for your Mac… \(Self.remaining(until: listening.deadline, now: context.date)) left")
                            .monospacedDigit()
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("phone-listen-waiting")
                if let status = listening.status {
                    Label(status.text, systemImage: status.isProblem ? "exclamationmark.triangle" : "laptopcomputer")
                        .font(.callout)
                        .foregroundStyle(status.isProblem ? Color.orange : Color.primary)
                        .multilineTextAlignment(.center)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("phone-listen-status")
                }
            }
            Text("The code is for this screen only; it isn't your token. Keep this screen open until the Mac finishes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Label(Self.troubleshootingHint, systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("phone-listen-hint")
            Button("Cancel", role: .cancel) {
                stop(showing: "Stopped listening. Nothing was saved.")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("phone-listen-cancel")
        }
    }

    private var tryAgainButton: some View {
        Button("Try Again", action: tryAgain)
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("phone-listen-try-again")
    }

    // MARK: - Listening

    /// One listening session, run by `.task(id: attempt)`: SwiftUI cancels
    /// it when the screen goes away, which cancels the listener.
    private func listen() async {
        let (events, sink) = AsyncStream.makeStream(of: PhoneHandoffListener.Event.self)
        let listener = PhoneHandoffListener(onEvent: { sink.yield($0) })
        self.listener = listener
        phase = .starting
        await withTaskCancellationHandler {
            await run(listener, events: events, sink: sink)
        } onCancel: {
            listener.cancel()
            sink.finish()
        }
        if self.listener === listener {
            self.listener = nil
        }
    }

    private func run(
        _ listener: PhoneHandoffListener,
        events: AsyncStream<PhoneHandoffListener.Event>,
        sink: AsyncStream<PhoneHandoffListener.Event>.Continuation
    ) async {
        let port: UInt16
        do {
            port = try await listener.start()
        } catch {
            sink.finish()
            show(error)
            return
        }
        guard Task.isCancelled == false else {
            listener.cancel()
            sink.finish()
            return
        }
        guard let address = PhoneHandoffAddress.local(port: port) else {
            listener.cancel()
            sink.finish()
            phase = .noNetwork
            return
        }
        let seconds = Double(PhoneHandoffListener.defaultTimeout.components.seconds)
        phase = .listening(Listening(
            command: address.pushCommand,
            code: listener.code.formatted,
            deadline: Date().addingTimeInterval(seconds),
            status: nil
        ))
        let waiting = Task { () -> Result<AtlassianCredential, PhoneHandoffError> in
            defer { sink.finish() }
            do throws(PhoneHandoffError) {
                return .success(try await listener.waitForCredential())
            } catch {
                return .failure(error)
            }
        }
        for await event in events {
            handle(event)
        }
        let outcome = await waiting.value
        guard Task.isCancelled == false else { return }
        switch outcome {
        case .success(let credential):
            phase = .confirming(credential, replacingEmail: accounts.replacedEmail(by: credential))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .failure(let error):
            show(error)
        }
    }

    private func handle(_ event: PhoneHandoffListener.Event) {
        guard case .listening(var listening) = phase else { return }
        switch event {
        case .listening, .received:
            return
        case .connected(let peer):
            listening.status = Status(text: "A Mac connected (\(peer))…", isProblem: false)
        case .attemptFailed(_, let reason, let failedAttempts):
            // Only a wrong-code attempt counts toward the limit.
            let text: String
            if reason.isCodeGuess {
                let left = PhoneHandoffListener.defaultMaxFailedAttempts - failedAttempts
                text = "\(reason.message) Still waiting (\(left) more wrong-code \(left == 1 ? "attempt" : "attempts") allowed)."
            } else {
                text = "\(reason.message) Still waiting."
            }
            listening.status = Status(text: text, isProblem: true)
        case .busy(let peer):
            listening.status = Status(
                text: "Turned away \(peer): other connections were in progress. Still waiting; the Mac can try again in a few seconds.",
                isProblem: true
            )
        }
        phase = .listening(listening)
    }

    /// Cancelled is not shown: whoever cancelled already set the phase.
    private func show(_ error: PhoneHandoffError) {
        switch error {
        case .cancelled:
            return
        case .timedOut:
            phase = .failure("Nothing connected before the code expired. Nothing was saved. Tap Try Again for a new code.")
        case .tooManyFailedAttempts(let count):
            phase = .failure("Stopped listening after \(count) attempts with a wrong code. Nothing was saved. Tap Try Again for a new code.")
        default:
            phase = .failure(error.message)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// Stops the listener. `message` (if any) replaces a listening phase.
    private func stop(showing message: String?) {
        if let message, isListening {
            phase = .stopped(message)
        }
        listener?.cancel()
        listener = nil
    }

    private func tryAgain() {
        listener?.cancel()
        listener = nil
        phase = .starting
        attempt += 1
    }

    // MARK: - Confirmation

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

    /// Discards the received credential unsaved. The listener is already
    /// stopped (one-shot), so another try needs a new code.
    private func cancelConfirmation() {
        phase = .stopped("Nothing was saved. Tap Try Again for a new code, then run the command on your Mac again.")
    }

    // MARK: - Helpers

    private func keepScreenAwake(_ awake: Bool) {
        UIApplication.shared.isIdleTimerDisabled = awake
    }

    /// The code on the pasteboard expires with the listener, so it doesn't
    /// linger after the handoff can no longer use it.
    private func copyCode(_ code: String, until deadline: Date) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: code]],
            options: [.expirationDate: deadline]
        )
    }

    static func remaining(until deadline: Date, now: Date) -> String {
        let seconds = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
