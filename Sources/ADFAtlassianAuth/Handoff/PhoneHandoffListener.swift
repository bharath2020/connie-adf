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
/// - listens on Wi-Fi, wired and bridge (Personal Hotspot) interfaces only:
///   never cellular, and a connection that arrives on any other local
///   address (a VPN tunnel, for example) is closed at once; peers must be
///   private local-network IPv4 addresses;
/// - runs up to ``maxConcurrentHandshakes`` handshakes at once (at most
///   ``maxHandshakesPerPeer`` from one address), each with its own fresh
///   ephemeral X25519 key and one overall ``connectionTimeout``; a
///   connection beyond that gets the "busy" reply, which the Mac reports as
///   ``PhoneHandoffError/phoneBusy``;
/// - closes a connection that fails and keeps listening. Only a sealed
///   credential that doesn't open (an online guess of the code) counts
///   toward ``maxFailedAttempts``; then it stops with
///   ``PhoneHandoffError/tooManyFailedAttempts(_:)``. Junk, timeouts and a
///   Mac that hangs up (wrong code typed there) don't count;
/// - stops for good after the first credential that opens and validates
///   (one-shot: every other connection is closed), on its timeout
///   (``PhoneHandoffError/timedOut``) or on ``cancel()``.
///
/// It never saves anything: the caller shows its own confirmation before
/// storing the returned credential.
public final class PhoneHandoffListener: Sendable {
    /// Something that happened while listening, for status text.
    public enum Event: Sendable, Equatable {
        /// The listener is ready on this port.
        case listening(port: UInt16)
        /// A Mac sent the handoff greeting and the handshake started.
        case connected(peer: String)
        /// A connection failed; the listener keeps listening unless this
        /// was the last allowed wrong-code attempt. `failedAttempts` counts
        /// only wrong-code attempts (``FailureReason/isCodeGuess``).
        case attemptFailed(peer: String, reason: FailureReason, failedAttempts: Int)
        /// A Mac connected while the phone was already handling the most
        /// connections it takes; it was told to try again.
        case busy(peer: String)
        /// A credential arrived; the listener has stopped.
        case received(peer: String)
    }

    /// Why one connection failed.
    public enum FailureReason: Sendable, Equatable {
        /// It didn't start with the handoff greeting, or sent a bad length.
        case notAHandoff
        /// The connection took longer than ``PhoneHandoffListener/connectionTimeout``.
        case timedOut
        /// The Mac hung up before sending the credential. The Mac does this
        /// when its typed code doesn't match.
        case disconnected
        /// The sealed credential didn't open (different code) or isn't valid.
        case couldNotOpen

        /// True only for a sealed credential that didn't open: the one
        /// failure that tests a code guess, and the only one that counts
        /// toward ``PhoneHandoffListener/maxFailedAttempts``.
        public var isCodeGuess: Bool { self == .couldNotOpen }

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
    /// Wrong-code attempts allowed before the listener stops.
    public static let defaultMaxFailedAttempts = 20
    /// Default time one connection may take, from accept to the credential.
    public static let defaultConnectionTimeout: Duration = .seconds(20)
    /// Handshakes run at once; more connections get the "busy" reply.
    public static let defaultMaxConcurrentHandshakes = 4
    /// Handshakes from one peer address at once.
    public static let defaultMaxHandshakesPerPeer = 2
    /// "Busy" replies in flight at once; beyond that, connections are just closed.
    static let maxBusyReplies = 8
    /// Time a "busy" reply may take (greeting in, one byte out).
    static let busyReplyTimeout: Duration = .seconds(3)
    /// Time for the final acknowledgement once the credential opened.
    static let ackTimeout: Duration = .seconds(5)
    /// How long ``start()`` tolerates a `.waiting` listener (network not
    /// ready yet, Local Network permission pending) before failing.
    static let defaultStartGracePeriod: Duration = .seconds(20)

    enum Binding: Sendable {
        /// Any local IPv4 address of a Wi-Fi, wired or bridge interface;
        /// peers must be private local-network addresses.
        case anyIPv4
        #if DEBUG
        /// Test-only: 127.0.0.1, and loopback peers are allowed. Not
        /// compiled into release builds.
        case loopbackForTesting
        #endif
    }

    /// The code to show. Secret: display it, never log it.
    public let code: PhonePairingCode
    /// Time one connection may take, from accept to the credential.
    public let connectionTimeout: Duration
    /// Wrong-code attempts allowed before the listener stops.
    public let maxFailedAttempts: Int
    /// Handshakes run at once.
    public let maxConcurrentHandshakes: Int
    /// Handshakes from one peer address at once.
    public let maxHandshakesPerPeer: Int

    private let requestedPort: UInt16
    private let timeout: Duration
    private let startGracePeriod: Duration
    private let binding: Binding
    private let onEvent: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "com.connie.adfreader.phone-handoff-listener")
    private let state: OSAllocatedUnfairLock<State>

    private struct Handshake: Sendable {
        let connection: NWConnection
        let peer: String
        var task: Task<Void, Never>?
    }

    private struct State: Sendable {
        var started = false
        var listener: NWListener?
        var port: UInt16?
        var handshakes: [ObjectIdentifier: Handshake] = [:]
        var busyReplies: [ObjectIdentifier: NWConnection] = [:]
        var failedAttempts = 0
        var outcome: Result<AtlassianCredential, PhoneHandoffError>?
        var waiters: [CheckedContinuation<Result<AtlassianCredential, PhoneHandoffError>, Never>] = []
        var startContinuation: CheckedContinuation<Result<UInt16, PhoneHandoffError>, Never>?
        /// Why the listener is `.waiting` while ``start()`` is pending.
        var startWaitingDetail: String?
        var timeoutTask: Task<Void, Never>?
    }

    /// - Parameters:
    ///   - code: The code to show; a fresh random one by default.
    ///   - port: 0 picks a free port; ``start()`` returns the real one.
    ///   - timeout: How long to listen (default 5 minutes), counted from ``start()``.
    ///   - maxFailedAttempts: Wrong-code attempts before stopping (default 20, at least 1).
    ///   - connectionTimeout: Time one connection may take (default 20 s).
    ///   - onEvent: Called on an arbitrary thread; hop to the main actor for UI.
    public convenience init(
        code: PhonePairingCode = .generate(),
        port: UInt16 = 0,
        timeout: Duration = defaultTimeout,
        maxFailedAttempts: Int = defaultMaxFailedAttempts,
        connectionTimeout: Duration = defaultConnectionTimeout,
        onEvent: @escaping @Sendable (Event) -> Void = { _ in }
    ) {
        self.init(
            code: code, port: port, timeout: timeout, maxFailedAttempts: maxFailedAttempts,
            connectionTimeout: connectionTimeout, binding: .anyIPv4, onEvent: onEvent
        )
    }

    init(
        code: PhonePairingCode,
        port: UInt16,
        timeout: Duration,
        maxFailedAttempts: Int,
        connectionTimeout: Duration,
        maxConcurrentHandshakes: Int = defaultMaxConcurrentHandshakes,
        maxHandshakesPerPeer: Int = defaultMaxHandshakesPerPeer,
        startGracePeriod: Duration = defaultStartGracePeriod,
        binding: Binding,
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        self.code = code
        self.requestedPort = port
        self.timeout = timeout
        self.maxFailedAttempts = max(1, maxFailedAttempts)
        self.connectionTimeout = connectionTimeout
        self.maxConcurrentHandshakes = max(1, maxConcurrentHandshakes)
        self.maxHandshakesPerPeer = max(1, maxHandshakesPerPeer)
        self.startGracePeriod = startGracePeriod
        self.binding = binding
        self.onEvent = onEvent
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    deinit {
        let leftovers = state.withLock { state in
            (state.listener, Array(state.handshakes.values), Array(state.busyReplies.values), state.timeoutTask)
        }
        leftovers.0?.cancel()
        for handshake in leftovers.1 {
            handshake.connection.cancel()
            handshake.task?.cancel()
        }
        leftovers.2.forEach { $0.cancel() }
        leftovers.3?.cancel()
    }

    /// The bound port once ``start()`` returned, else nil.
    public var port: UInt16? {
        state.withLock { $0.port }
    }

    /// Wrong-code attempts so far (sealed credentials that didn't open).
    public var failedAttempts: Int {
        state.withLock { $0.failedAttempts }
    }

    /// True once the listener has stopped (credential, timeout, cancel or failure).
    public var isFinished: Bool {
        state.withLock { $0.outcome != nil }
    }

    /// Connections being handled right now (handshakes and "busy" replies).
    var openConnections: Int {
        state.withLock { $0.handshakes.count + $0.busyReplies.count }
    }

    // MARK: Lifecycle

    /// Starts listening and returns the bound port. Call once. The timeout
    /// starts now. While the network isn't ready yet (the listener is
    /// `.waiting`, for example during the Local Network permission prompt)
    /// it keeps waiting for a grace period before failing with
    /// ``PhoneHandoffError/listenerFailed(_:)``. Cancelling the calling task
    /// cancels the listener and throws ``PhoneHandoffError/cancelled``.
    public func start() async throws(PhoneHandoffError) -> UInt16 {
        if Task.isCancelled {
            cancel()
            throw .cancelled
        }
        guard let nwPort = NWEndpoint.Port(rawValue: requestedPort) else {
            throw .listenerFailed("invalid port \(requestedPort)")
        }
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        parameters.allowLocalEndpointReuse = true
        // Never on cellular. VPN tunnels are refused per connection
        // (`localAddressAllowed`), since their interface type varies.
        parameters.prohibitedInterfaceTypes = [.cellular]
        let listener: NWListener
        do {
            switch binding {
            case .anyIPv4:
                listener = try NWListener(using: parameters, on: nwPort)
            #if DEBUG
            case .loopbackForTesting:
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
                listener = try NWListener(using: parameters)
            #endif
            }
        } catch {
            throw .listenerFailed(error.localizedDescription)
        }

        let result: Result<UInt16, PhoneHandoffError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
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
        } onCancel: {
            self.cancel()
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

    /// Stops listening and closes every connection. Waiters get
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
                defer {
                    state.startContinuation = nil
                    state.startWaitingDetail = nil
                }
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
        case .waiting(let error):
            // Transient (no network yet, permission pending): only fail if
            // it lasts longer than the grace period while start() waits.
            // Once listening, the listener recovers on its own.
            let detail = HandoffWire.describe(error)
            let firstWait = state.withLock { state -> Bool in
                guard state.startContinuation != nil else { return false }
                defer { state.startWaitingDetail = detail }
                return state.startWaitingDetail == nil
            }
            if firstWait {
                queue.asyncAfter(deadline: .now() + startGracePeriod.timeInterval) { [weak self] in
                    self?.startGraceExpired()
                }
            }
        case .failed(let error):
            finish(.failure(.listenerFailed(HandoffWire.describe(error))))
        default:
            break
        }
    }

    private func startGraceExpired() {
        let detail = state.withLock { state in
            state.startContinuation != nil ? state.startWaitingDetail : nil
        }
        if let detail {
            finish(.failure(.listenerFailed(detail)))
        }
    }

    private struct Teardown: Sendable {
        let listener: NWListener?
        let handshakes: [Handshake]
        let busyReplies: [NWConnection]
        let timeoutTask: Task<Void, Never>?
        let waiters: [CheckedContinuation<Result<AtlassianCredential, PhoneHandoffError>, Never>]
        let startContinuation: CheckedContinuation<Result<UInt16, PhoneHandoffError>, Never>?
    }

    /// Sets the outcome once and tears everything down: the listener and
    /// every connection except `kept`, the one that delivered the
    /// credential (it stays open for the acknowledgement). Returns false if
    /// already finished.
    @discardableResult
    private func finish(_ outcome: Result<AtlassianCredential, PhoneHandoffError>, keeping kept: NWConnection? = nil) -> Bool {
        let teardown = state.withLock { state -> Teardown? in
            guard state.outcome == nil else { return nil }
            state.outcome = outcome
            let teardown = Teardown(
                listener: state.listener,
                handshakes: state.handshakes.values.filter { $0.connection !== kept },
                busyReplies: Array(state.busyReplies.values),
                timeoutTask: state.timeoutTask,
                waiters: state.waiters,
                startContinuation: state.startContinuation
            )
            state.listener = nil
            state.handshakes = [:]
            state.busyReplies = [:]
            state.timeoutTask = nil
            state.waiters = []
            state.startContinuation = nil
            return teardown
        }
        guard let teardown else { return false }
        teardown.listener?.cancel()
        for handshake in teardown.handshakes {
            handshake.connection.cancel()
            handshake.task?.cancel()
        }
        teardown.busyReplies.forEach { $0.cancel() }
        teardown.timeoutTask?.cancel()
        if let startContinuation = teardown.startContinuation {
            switch outcome {
            case .failure(let error): startContinuation.resume(returning: .failure(error))
            case .success: startContinuation.resume(returning: .failure(.cancelled))
            }
        }
        teardown.waiters.forEach { $0.resume(returning: outcome) }
        return true
    }

    // MARK: Connections

    private func peerAllowed(_ peer: String) -> Bool {
        switch binding {
        case .anyIPv4: return PairingLink.isLocalNetworkHost(peer)
        #if DEBUG
        case .loopbackForTesting: return peer == "127.0.0.1" || PairingLink.isLocalNetworkHost(peer)
        #endif
        }
    }

    /// The connection arrived on one of this device's Wi-Fi, wired or bridge
    /// addresses (not cellular, not a VPN tunnel). Needs a ready connection.
    private func localAddressAllowed(_ connection: NWConnection) -> Bool {
        guard let local = HandoffWire.localIPv4(of: connection) else { return false }
        switch binding {
        case .anyIPv4: return PhoneHandoffAddress.lanAddresses().contains(local)
        #if DEBUG
        case .loopbackForTesting: return local == "127.0.0.1"
        #endif
        }
    }

    private enum Admission {
        case handshake
        case busy
        case refused
    }

    private func accept(_ connection: NWConnection) {
        guard let peer = HandoffWire.peerIPv4(of: connection), peerAllowed(peer) else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        let admission = state.withLock { state -> Admission in
            guard state.outcome == nil else { return .refused }
            let fromPeer = state.handshakes.values.count { $0.peer == peer }
            if state.handshakes.count < maxConcurrentHandshakes, fromPeer < maxHandshakesPerPeer {
                state.handshakes[id] = Handshake(connection: connection, peer: peer)
                return .handshake
            }
            if state.busyReplies.count < Self.maxBusyReplies {
                state.busyReplies[id] = connection
                return .busy
            }
            return .refused
        }
        switch admission {
        case .refused:
            connection.cancel()
        case .busy:
            Task { [weak self] in
                await self?.replyBusy(connection, peer: peer)
            }
        case .handshake:
            let task = Task { [weak self] in
                guard let self else { return }
                await self.handshake(connection, peer: peer)
            }
            let stillActive = state.withLock { state -> Bool in
                guard state.handshakes[id] != nil else { return false }
                state.handshakes[id]?.task = task
                return true
            }
            if !stillActive { task.cancel() }
        }
    }

    /// Over the limit: read the greeting, answer "busy", close.
    private func replyBusy(_ connection: NWConnection, peer: String) async {
        typealias H = PhoneHandoffHandshake
        let wire = HandoffWire(connection: connection, queue: queue)
        defer {
            wire.close()
            state.withLock { _ = $0.busyReplies.removeValue(forKey: ObjectIdentifier(connection)) }
        }
        let clock = ContinuousClock()
        let deadline = clock.now + Self.busyReplyTimeout
        func left() -> Duration { max(.zero, deadline - clock.now) }
        guard case .success = await wire.start(timeout: left()), localAddressAllowed(connection),
              case .success(let hello) = await wire.receive(exactly: H.magic.count + H.publicKeyBytes, timeout: left()),
              hello.prefix(H.magic.count) == H.magic
        else { return }
        if case .success = await wire.send(Data([H.replyBusy]), timeout: left()) {
            onEvent(.busy(peer: peer))
        }
    }

    private enum Attempt: Sendable {
        /// Not on an allowed interface, or never became ready: closed silently.
        case ignored
        case opened(AtlassianCredential, ack: Data)
        case failed(FailureReason)
    }

    private func handshake(_ connection: NWConnection, peer: String) async {
        let wire = HandoffWire(connection: connection, queue: queue)
        switch await receiveCredential(on: wire, peer: peer) {
        case .opened(let credential, let ack):
            // One-shot: stop listening and close every other connection
            // before anything else.
            guard finish(.success(credential), keeping: connection) else {
                wire.close()
                return
            }
            onEvent(.received(peer: peer))
            _ = await wire.send(ack, timeout: Self.ackTimeout)
            wire.close()
        case .failed(let reason):
            wire.close()
            attemptFailed(connection, peer: peer, reason: reason)
        case .ignored:
            wire.close()
            state.withLock { _ = $0.handshakes.removeValue(forKey: ObjectIdentifier(connection)) }
        }
    }

    private func attemptFailed(_ connection: NWConnection, peer: String, reason: FailureReason) {
        let count = state.withLock { state -> Int? in
            guard state.outcome == nil, state.handshakes.removeValue(forKey: ObjectIdentifier(connection)) != nil else { return nil }
            if reason.isCodeGuess { state.failedAttempts += 1 }
            return state.failedAttempts
        }
        guard let count else { return }
        onEvent(.attemptFailed(peer: peer, reason: reason, failedAttempts: count))
        if reason.isCodeGuess, count >= maxFailedAttempts {
            finish(.failure(.tooManyFailedAttempts(count)))
        }
    }

    /// One handshake, all within ``connectionTimeout`` from accept.
    private func receiveCredential(on wire: HandoffWire, peer: String) async -> Attempt {
        typealias H = PhoneHandoffHandshake
        let clock = ContinuousClock()
        let deadline = clock.now + connectionTimeout
        func left() -> Duration { max(.zero, deadline - clock.now) }
        func reason(_ failure: HandoffWire.Failure) -> FailureReason {
            failure == .timedOut ? .timedOut : .disconnected
        }

        // 0. Ready, and on a Wi-Fi/wired/bridge address of this device.
        guard case .success = await wire.start(timeout: left()), localAddressAllowed(wire.connection) else {
            return .ignored
        }

        // 1. "ADFH2" || B
        let hello: Data
        switch await wire.receive(exactly: H.magic.count + H.publicKeyBytes, timeout: left()) {
        case .success(let data): hello = data
        case .failure(let failure): return .failed(failure == .timedOut ? .timedOut : .notAHandoff)
        }
        guard hello.prefix(H.magic.count) == H.magic else { return .failed(.notAHandoff) }
        let macKey = Data(hello.suffix(H.publicKeyBytes))
        onEvent(.connected(peer: peer))

        // 2. 0x00 || A || T, with a fresh key for every connection.
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let phoneKey = privateKey.publicKey.rawRepresentation
        let tag = H.tag(code: code, phoneKey: phoneKey, macKey: macKey)
        if case .failure(let failure) = await wire.send(Data([H.replyProceed]) + phoneKey + tag, timeout: left()) {
            return .failed(reason(failure))
        }

        // 3. The Mac checks T and hangs up if it doesn't match.
        // 4. len32 || box
        let lengthBytes: Data
        switch await wire.receive(exactly: H.lengthBytes, timeout: left()) {
        case .success(let data): lengthBytes = data
        case .failure(let failure): return .failed(reason(failure))
        }
        let length = H.length(fromPrefix: lengthBytes)
        guard length > 0, length <= H.maxBoxBytes else { return .failed(.notAHandoff) }
        let box: Data
        switch await wire.receive(exactly: length, timeout: left()) {
        case .success(let data): box = data
        case .failure(let failure): return .failed(reason(failure))
        }

        // A box arrived: from here on, a failure is a code guess.
        guard let keys = try? H.sessionKeys(privateKey: privateKey, peerKey: macKey, code: code, phoneKey: phoneKey, macKey: macKey) else {
            return .failed(.couldNotOpen)
        }
        guard let credential = H.open(box, key: keys.seal, phoneKey: phoneKey, macKey: macKey) else {
            // 5. s || M (rejected). Reveals nothing T doesn't already.
            _ = await wire.send(H.ack(H.statusRejected, key: keys.ack, phoneKey: phoneKey, macKey: macKey), timeout: left())
            return .failed(.couldNotOpen)
        }
        // 5. s || M (received), sent once the listener has stopped.
        return .opened(credential, ack: H.ack(H.statusReceived, key: keys.ack, phoneKey: phoneKey, macKey: macKey))
    }
}
