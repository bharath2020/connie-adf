import CryptoKit
import Foundation
import Network
import os

/// Phone side of the "Mac connects to phone" handoff: a one-shot TCP (IPv4)
/// listener that receives one sealed credential from `adf-auth push --to`.
///
/// Show ``code`` (``PhonePairingCode/formatted``) and the address from
/// ``PhoneHandoffAddress/local(port:)`` with the port ``start()`` returns,
/// then await ``waitForCredential()``. The listener:
///
/// - handles one connection at a time (others are closed at once) and only
///   from private local-network IPv4 peers;
/// - runs the v2 handshake (``PhoneHandoffHandshake``) with a fresh
///   ephemeral X25519 key per connection, and per-step timeouts;
/// - closes a connection that fails (wrong code, garbage, timeout,
///   disconnect) and keeps listening, until ``maxFailedAttempts`` failures,
///   then stops with ``PhoneHandoffError/tooManyFailedAttempts(_:)``;
/// - stops for good after the first credential that opens and validates
///   (one-shot), on its timeout (``PhoneHandoffError/timedOut``) or on
///   ``cancel()``.
///
/// It never saves anything: the caller shows its own confirmation before
/// storing the returned credential.
public final class PhoneHandoffListener: Sendable {
    /// Something that happened while listening, for status text.
    public enum Event: Sendable, Equatable {
        /// The listener is ready on this port.
        case listening(port: UInt16)
        /// A Mac connected and the handshake started.
        case connected(peer: String)
        /// A connection failed; the listener keeps listening unless this
        /// was the last allowed failure.
        case attemptFailed(peer: String, reason: FailureReason, failedAttempts: Int)
        /// A credential arrived; the listener has stopped.
        case received(peer: String)
    }

    /// Why one connection failed.
    public enum FailureReason: Sendable, Equatable {
        /// It didn't start with the handoff greeting, or sent a bad length.
        case notAHandoff
        /// A step took longer than ``PhoneHandoffListener/stepTimeout``.
        case timedOut
        /// The Mac hung up before sending the credential. The Mac does this
        /// when its typed code doesn't match.
        case disconnected
        /// The sealed credential didn't open (different code) or isn't valid.
        case couldNotOpen

        public var message: String {
            switch self {
            case .notAHandoff: return "Something connected that isn't adf-auth."
            case .timedOut: return "A connection stalled and was closed."
            case .disconnected: return "A Mac connected but hung up. Check the code typed on the Mac."
            case .couldNotOpen: return "A Mac sent something that couldn't be opened with this code."
            }
        }
    }

    /// How long the code stays valid by default.
    public static let defaultTimeout: Duration = .seconds(300)
    /// Failed connections allowed before the listener stops.
    public static let defaultMaxFailedAttempts = 20
    /// Default time allowed for each handshake step.
    public static let defaultStepTimeout: Duration = .seconds(15)

    enum Binding: Sendable {
        /// Any local IPv4 address; peers must be private local-network addresses.
        case anyIPv4
        /// Test-only: 127.0.0.1, and loopback peers are allowed.
        case loopbackForTesting
    }

    /// The code to show. Secret: display it, never log it.
    public let code: PhonePairingCode
    /// Time each handshake step may take.
    public let stepTimeout: Duration
    /// Failed connections allowed before the listener stops.
    public let maxFailedAttempts: Int

    private let requestedPort: UInt16
    private let timeout: Duration
    private let binding: Binding
    private let onEvent: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "com.connie.adfreader.phone-handoff-listener")
    private let state: OSAllocatedUnfairLock<State>

    private struct State: Sendable {
        var started = false
        var listener: NWListener?
        var port: UInt16?
        var active: NWConnection?
        var activeTask: Task<Void, Never>?
        var failedAttempts = 0
        var outcome: Result<AtlassianCredential, PhoneHandoffError>?
        var waiters: [CheckedContinuation<Result<AtlassianCredential, PhoneHandoffError>, Never>] = []
        var startContinuation: CheckedContinuation<Result<UInt16, PhoneHandoffError>, Never>?
        var timeoutTask: Task<Void, Never>?
    }

    /// - Parameters:
    ///   - code: The code to show; a fresh random one by default.
    ///   - port: 0 picks a free port; ``start()`` returns the real one.
    ///   - timeout: How long to listen (default 5 minutes), counted from ``start()``.
    ///   - maxFailedAttempts: Failed connections before stopping (default 20, at least 1).
    ///   - stepTimeout: Time each handshake step may take (default 15 s).
    ///   - onEvent: Called on the listener's queue; hop to the main actor for UI.
    public convenience init(
        code: PhonePairingCode = .generate(),
        port: UInt16 = 0,
        timeout: Duration = defaultTimeout,
        maxFailedAttempts: Int = defaultMaxFailedAttempts,
        stepTimeout: Duration = defaultStepTimeout,
        onEvent: @escaping @Sendable (Event) -> Void = { _ in }
    ) {
        self.init(
            code: code, port: port, timeout: timeout, maxFailedAttempts: maxFailedAttempts,
            stepTimeout: stepTimeout, binding: .anyIPv4, onEvent: onEvent
        )
    }

    init(
        code: PhonePairingCode,
        port: UInt16,
        timeout: Duration,
        maxFailedAttempts: Int,
        stepTimeout: Duration,
        binding: Binding,
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        self.code = code
        self.requestedPort = port
        self.timeout = timeout
        self.maxFailedAttempts = max(1, maxFailedAttempts)
        self.stepTimeout = stepTimeout
        self.binding = binding
        self.onEvent = onEvent
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    deinit {
        let leftovers = state.withLock { state -> (NWListener?, NWConnection?, Task<Void, Never>?, Task<Void, Never>?) in
            (state.listener, state.active, state.activeTask, state.timeoutTask)
        }
        leftovers.0?.cancel()
        leftovers.1?.cancel()
        leftovers.2?.cancel()
        leftovers.3?.cancel()
    }

    /// The bound port once ``start()`` returned, else nil.
    public var port: UInt16? {
        state.withLock { $0.port }
    }

    /// Failed connections so far.
    public var failedAttempts: Int {
        state.withLock { $0.failedAttempts }
    }

    /// True once the listener has stopped (credential, timeout, cancel or failure).
    public var isFinished: Bool {
        state.withLock { $0.outcome != nil }
    }

    // MARK: Lifecycle

    /// Starts listening and returns the bound port. Call once. The timeout
    /// starts now.
    public func start() async throws(PhoneHandoffError) -> UInt16 {
        guard let nwPort = NWEndpoint.Port(rawValue: requestedPort) else {
            throw .listenerFailed("invalid port \(requestedPort)")
        }
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            switch binding {
            case .anyIPv4:
                listener = try NWListener(using: parameters, on: nwPort)
            case .loopbackForTesting:
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
                listener = try NWListener(using: parameters)
            }
        } catch {
            throw .listenerFailed(error.localizedDescription)
        }

        let result: Result<UInt16, PhoneHandoffError> = await withCheckedContinuation { continuation in
            let early: Result<UInt16, PhoneHandoffError>? = state.withLock { state in
                if state.started { return .failure(.listenerFailed("the listener was already started")) }
                if state.outcome != nil { return .failure(.cancelled) }
                state.started = true
                state.listener = listener
                state.startContinuation = continuation
                return nil
            }
            if let early {
                continuation.resume(returning: early)
                return
            }
            listener.stateUpdateHandler = { [weak self] newState in
                self?.listenerStateChanged(newState, listener: listener)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
        return try result.get()
    }

    /// Waits for the credential. Throws ``PhoneHandoffError/timedOut``,
    /// ``PhoneHandoffError/cancelled``, ``PhoneHandoffError/tooManyFailedAttempts(_:)``
    /// or ``PhoneHandoffError/listenerFailed(_:)``. Cancelling the calling
    /// task cancels the listener. May be called more than once; every call
    /// gets the same outcome.
    public func waitForCredential() async throws(PhoneHandoffError) -> AtlassianCredential {
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<AtlassianCredential, PhoneHandoffError>, Never>) in
                let existing = state.withLock { state -> Result<AtlassianCredential, PhoneHandoffError>? in
                    if let outcome = state.outcome { return outcome }
                    state.waiters.append(continuation)
                    return nil
                }
                if let existing { continuation.resume(returning: existing) }
            }
        } onCancel: {
            self.cancel()
        }
        return try result.get()
    }

    /// Stops listening and closes any connection. Waiters get
    /// ``PhoneHandoffError/cancelled`` unless the listener already finished.
    public func cancel() {
        finish(.failure(.cancelled))
    }

    private func listenerStateChanged(_ newState: NWListener.State, listener: NWListener) {
        switch newState {
        case .ready:
            let boundPort = listener.port?.rawValue ?? requestedPort
            let timeout = self.timeout
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finish(.failure(.timedOut))
            }
            let continuation = state.withLock { state -> CheckedContinuation<Result<UInt16, PhoneHandoffError>, Never>? in
                defer { state.startContinuation = nil }
                guard state.outcome == nil, let continuation = state.startContinuation else { return nil }
                state.port = boundPort
                state.timeoutTask = timeoutTask
                return continuation
            }
            guard let continuation else {
                timeoutTask.cancel()
                return
            }
            onEvent(.listening(port: boundPort))
            continuation.resume(returning: .success(boundPort))
        case .failed(let error), .waiting(let error):
            let detail = HandoffWire.describe(error)
            let continuation = state.withLock { state -> CheckedContinuation<Result<UInt16, PhoneHandoffError>, Never>? in
                defer { state.startContinuation = nil }
                return state.startContinuation
            }
            if let continuation {
                continuation.resume(returning: .failure(.listenerFailed(detail)))
                finish(.failure(.listenerFailed(detail)))
            } else if case .failed = newState {
                finish(.failure(.listenerFailed(detail)))
            }
        default:
            break
        }
    }

    private struct Teardown: Sendable {
        let listener: NWListener?
        let connection: NWConnection?
        let task: Task<Void, Never>?
        let timeoutTask: Task<Void, Never>?
        let waiters: [CheckedContinuation<Result<AtlassianCredential, PhoneHandoffError>, Never>]
        let startContinuation: CheckedContinuation<Result<UInt16, PhoneHandoffError>, Never>?
    }

    /// Sets the outcome once and tears everything down. `keeping` is the
    /// connection that delivered the credential: it stays open so the
    /// status byte can still be sent. Returns false if already finished.
    @discardableResult
    private func finish(_ outcome: Result<AtlassianCredential, PhoneHandoffError>, keeping kept: NWConnection? = nil) -> Bool {
        let teardown = state.withLock { state -> Teardown? in
            guard state.outcome == nil else { return nil }
            state.outcome = outcome
            let keepActive = kept != nil && state.active === kept
            let teardown = Teardown(
                listener: state.listener,
                connection: keepActive ? nil : state.active,
                task: keepActive ? nil : state.activeTask,
                timeoutTask: state.timeoutTask,
                waiters: state.waiters,
                startContinuation: state.startContinuation
            )
            state.listener = nil
            state.active = nil
            state.activeTask = nil
            state.timeoutTask = nil
            state.waiters = []
            state.startContinuation = nil
            return teardown
        }
        guard let teardown else { return false }
        teardown.listener?.cancel()
        teardown.connection?.cancel()
        teardown.task?.cancel()
        teardown.timeoutTask?.cancel()
        teardown.startContinuation?.resume(returning: .failure(.cancelled))
        teardown.waiters.forEach { $0.resume(returning: outcome) }
        return true
    }

    // MARK: Connections

    private func peerAllowed(_ peer: String) -> Bool {
        switch binding {
        case .anyIPv4: return PairingLink.isLocalNetworkHost(peer)
        case .loopbackForTesting: return peer == "127.0.0.1" || PairingLink.isLocalNetworkHost(peer)
        }
    }

    private func accept(_ connection: NWConnection) {
        guard let peer = HandoffWire.peerIPv4(of: connection), peerAllowed(peer) else {
            connection.cancel()
            return
        }
        let accepted = state.withLock { state -> Bool in
            guard state.outcome == nil, state.active == nil else { return false }
            state.active = connection
            return true
        }
        guard accepted else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        onEvent(.connected(peer: peer))
        let wire = HandoffWire(connection: connection, queue: queue)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.handshake(on: wire, peer: peer)
        }
        let stillActive = state.withLock { state -> Bool in
            guard state.active === connection else { return false }
            state.activeTask = task
            return true
        }
        if !stillActive { task.cancel() }
    }

    private enum Attempt: Sendable {
        case opened(AtlassianCredential)
        case failed(FailureReason)
    }

    private func handshake(on wire: HandoffWire, peer: String) async {
        let attempt = await receiveCredential(on: wire)
        switch attempt {
        case .opened(let credential):
            // One-shot: stop listening before anything else.
            guard finish(.success(credential), keeping: wire.connection) else {
                wire.close()
                return
            }
            onEvent(.received(peer: peer))
            _ = await wire.send(Data([PhoneHandoffHandshake.statusReceived]), timeout: stepTimeout)
            wire.close()
        case .failed(let reason):
            if reason == .couldNotOpen {
                _ = await wire.send(Data([PhoneHandoffHandshake.statusRejected]), timeout: stepTimeout)
            }
            wire.close()
            attemptFailed(wire.connection, peer: peer, reason: reason)
        }
    }

    private func attemptFailed(_ connection: NWConnection, peer: String, reason: FailureReason) {
        let count = state.withLock { state -> Int? in
            guard state.outcome == nil, state.active === connection else { return nil }
            state.active = nil
            state.activeTask = nil
            state.failedAttempts += 1
            return state.failedAttempts
        }
        guard let count else { return }
        onEvent(.attemptFailed(peer: peer, reason: reason, failedAttempts: count))
        if count >= maxFailedAttempts {
            finish(.failure(.tooManyFailedAttempts(count)))
        }
    }

    private func receiveCredential(on wire: HandoffWire) async -> Attempt {
        typealias H = PhoneHandoffHandshake
        func reason(_ failure: HandoffWire.Failure) -> FailureReason {
            failure == .timedOut ? .timedOut : .disconnected
        }

        // 1. "ADFH2" || B
        let hello: Data
        switch await wire.receive(exactly: H.magic.count + H.publicKeyBytes, timeout: stepTimeout) {
        case .success(let data): hello = data
        case .failure(let failure): return .failed(failure == .timedOut ? .timedOut : .notAHandoff)
        }
        guard hello.prefix(H.magic.count) == H.magic else { return .failed(.notAHandoff) }
        let macKey = Data(hello.suffix(H.publicKeyBytes))

        // 2. A || T, with a fresh key for every connection.
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let phoneKey = privateKey.publicKey.rawRepresentation
        let tag = H.tag(code: code, phoneKey: phoneKey, macKey: macKey)
        if case .failure(let failure) = await wire.send(phoneKey + tag, timeout: stepTimeout) {
            return .failed(reason(failure))
        }

        // 3. The Mac checks T and hangs up if it doesn't match.
        // 4. len32 || box
        let lengthBytes: Data
        switch await wire.receive(exactly: H.lengthBytes, timeout: stepTimeout) {
        case .success(let data): lengthBytes = data
        case .failure(let failure): return .failed(reason(failure))
        }
        let length = H.length(fromPrefix: lengthBytes)
        guard length > 0, length <= H.maxBoxBytes else { return .failed(.notAHandoff) }
        let box: Data
        switch await wire.receive(exactly: length, timeout: stepTimeout) {
        case .success(let data): box = data
        case .failure(let failure): return .failed(reason(failure))
        }

        guard let key = try? H.sessionKey(privateKey: privateKey, peerKey: macKey, code: code, phoneKey: phoneKey, macKey: macKey),
              let credential = H.open(box, key: key, phoneKey: phoneKey, macKey: macKey)
        else { return .failed(.couldNotOpen) }
        return .opened(credential)
    }
}
