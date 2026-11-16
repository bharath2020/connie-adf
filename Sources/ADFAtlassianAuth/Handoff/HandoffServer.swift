#if os(macOS)
import Foundation
import Network
import os

/// A one-shot HTTP/1.1 listener (TCP, IPv4) that hands one sealed credential
/// box to one phone.
///
/// Only `GET /h/<sessionId>` matches. For a match the server asks `confirm`;
/// yes → `200 application/octet-stream` with the sealed box, then it stops
/// listening for good; no → `403` and it keeps listening. Every other
/// request gets `404` and a ``Event/rejected(peer:path:)`` event. When the
/// timeout passes the server stops; the outcome is ``Outcome/declined(peer:)``
/// if someone was declined, otherwise ``Outcome/timedOut``. The server drops
/// its copy of the sealed bytes once it finishes.
///
/// While one confirmation is pending, other matching requests get `404`.
public final class HandoffServer: Sendable {
    public enum Event: Sendable, Equatable {
        /// The listener is ready on this port.
        case listening(port: UInt16)
        /// A request head was parsed. A matching path is reported as
        /// `/h/<redacted>` so the session ID never reaches logs.
        case request(peer: String, path: String)
        /// The request got `404` (unknown path, wrong method, malformed, or
        /// the code is busy/spent). Show it as a warning.
        case rejected(peer: String, path: String)
    }

    public enum Outcome: Sendable, Equatable {
        case served(peer: String, at: Date)
        case timedOut
        case cancelled
        /// Timed out after the person at the Mac declined at least one request.
        case declined(peer: String)
        /// The listener failed after it started.
        case failed(String)
    }

    /// The path reported in events for the matching request.
    public static let redactedPath = "/h/\(Redaction.placeholder)"

    private struct State: Sendable {
        var sealed: Data?
        var listener: NWListener?
        var connections: [ObjectIdentifier: NWConnection] = [:]
        var started = false
        var busy = false
        var lastDeclinedPeer: String?
        var outcome: Outcome?
        var waiters: [CheckedContinuation<Outcome, Never>] = []
        var startContinuation: CheckedContinuation<Result<UInt16, HandoffError>, Never>?
        var timeoutTask: Task<Void, Never>?
    }

    private let sessionId: String
    private let bindHost: String
    private let port: UInt16
    private let timeout: Duration
    private let confirm: @Sendable (_ peer: String) async -> Bool
    private let onEvent: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "com.connie.adfreader.handoff-server")
    private let state: OSAllocatedUnfairLock<State>

    /// - Parameters:
    ///   - sealed: The `HandoffSeal` box to serve once.
    ///   - bindHost: The IPv4 address to listen on (for example the Mac's
    ///     Wi-Fi address, or `127.0.0.1` in tests).
    ///   - port: 0 picks a free port; ``start()`` returns the real one.
    ///   - confirm: Asked for each matching request; return true to send.
    ///   - onEvent: Called on the server's queue.
    public init(
        sealed: Data,
        sessionId: String,
        bindHost: String,
        port: UInt16 = 0,
        timeout: Duration = .seconds(120),
        confirm: @escaping @Sendable (_ peer: String) async -> Bool,
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        self.sessionId = sessionId
        self.bindHost = bindHost
        self.port = port
        self.timeout = timeout
        self.confirm = confirm
        self.onEvent = onEvent
        self.state = OSAllocatedUnfairLock(initialState: State(sealed: sealed))
    }

    deinit {
        let leftovers = state.withLock { state -> (NWListener?, [NWConnection], Task<Void, Never>?) in
            (state.listener, Array(state.connections.values), state.timeoutTask)
        }
        leftovers.0?.cancel()
        leftovers.1.forEach { $0.cancel() }
        leftovers.2?.cancel()
    }

    // MARK: Lifecycle

    /// Starts listening and returns the bound port. Call once.
    public func start() async throws(HandoffError) -> UInt16 {
        guard IPv4Address(bindHost) != nil else {
            throw .listenerFailed("\(bindHost) is not an IPv4 address")
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw .listenerFailed("invalid port \(port)")
        }
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindHost), port: nwPort)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw .listenerFailed(error.localizedDescription)
        }

        let result: Result<UInt16, HandoffError> = await withCheckedContinuation { continuation in
            let early: Result<UInt16, HandoffError>? = state.withLock { state in
                if state.started { return .failure(.listenerFailed("the server was already started")) }
                if state.outcome != nil { return .failure(.listenerFailed("the server was cancelled")) }
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

    /// Waits until the box was served, the timeout passed, or ``cancel()``.
    public func waitForCompletion() async -> Outcome {
        await withCheckedContinuation { continuation in
            let existing: Outcome? = state.withLock { state in
                if let outcome = state.outcome { return outcome }
                state.waiters.append(continuation)
                return nil
            }
            if let existing { continuation.resume(returning: existing) }
        }
    }

    /// Stops listening; the outcome becomes ``Outcome/cancelled`` unless the
    /// server already finished.
    public func cancel() {
        finish(.cancelled)
    }

    private func listenerStateChanged(_ newState: NWListener.State, listener: NWListener) {
        switch newState {
        case .ready:
            let boundPort = listener.port?.rawValue ?? port
            let continuation = state.withLock { state -> CheckedContinuation<Result<UInt16, HandoffError>, Never>? in
                defer { state.startContinuation = nil }
                return state.startContinuation
            }
            guard let continuation else { return }
            let timeout = self.timeout
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.timeOut()
            }
            let alreadyFinished = state.withLock { state -> Bool in
                if state.outcome != nil { return true }
                state.timeoutTask = timeoutTask
                return false
            }
            if alreadyFinished { timeoutTask.cancel() }
            onEvent(.listening(port: boundPort))
            continuation.resume(returning: .success(boundPort))
        case .failed(let error), .waiting(let error):
            let continuation = state.withLock { state -> CheckedContinuation<Result<UInt16, HandoffError>, Never>? in
                defer { state.startContinuation = nil }
                return state.startContinuation
            }
            if let continuation {
                continuation.resume(returning: .failure(.listenerFailed(error.localizedDescription)))
                finish(.failed(error.localizedDescription))
            } else if case .failed = newState {
                finish(.failed(error.localizedDescription))
            }
        default:
            break
        }
    }

    private func timeOut() {
        let declinedPeer = state.withLock { $0.lastDeclinedPeer }
        finish(declinedPeer.map { .declined(peer: $0) } ?? .timedOut)
    }

    private func finish(_ outcome: Outcome) {
        let teardown = state.withLock { state -> (NWListener?, [NWConnection], [CheckedContinuation<Outcome, Never>], Task<Void, Never>?, CheckedContinuation<Result<UInt16, HandoffError>, Never>?)? in
            guard state.outcome == nil else { return nil }
            state.outcome = outcome
            state.sealed = nil
            defer {
                state.listener = nil
                state.connections = [:]
                state.waiters = []
                state.timeoutTask = nil
                state.startContinuation = nil
            }
            return (state.listener, Array(state.connections.values), state.waiters, state.timeoutTask, state.startContinuation)
        }
        guard let teardown else { return }
        teardown.0?.cancel()
        teardown.1.forEach { $0.cancel() }
        teardown.3?.cancel()
        teardown.4?.resume(returning: .failure(.listenerFailed("the server stopped before it was ready")))
        teardown.2.forEach { $0.resume(returning: outcome) }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let accepted = state.withLock { state -> Bool in
            guard state.outcome == nil else { return false }
            state.connections[id] = connection
            return true
        }
        guard accepted else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .failed, .cancelled:
                self?.state.withLock { _ = $0.connections.removeValue(forKey: id) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveHead(on: connection, buffer: Data())
    }

    private func receiveHead(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: HTTPRequestLine.maxHeadBytes) { [weak self] content, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let content { buffer.append(content) }
            if let length = HTTPRequestLine.headLength(in: buffer), length <= HTTPRequestLine.maxHeadBytes {
                self.handle(head: buffer.prefix(length), on: connection)
            } else if buffer.count >= HTTPRequestLine.maxHeadBytes {
                self.reject(connection, peer: Self.peer(of: connection), path: "<oversized request>")
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receiveHead(on: connection, buffer: buffer)
            }
        }
    }

    private func handle(head: Data, on connection: NWConnection) {
        let peer = Self.peer(of: connection)
        guard let line = HTTPRequestLine.parse(head) else {
            reject(connection, peer: peer, path: "<malformed request>")
            return
        }
        let matches = line.method == "GET" && Self.pathMatches(line.target, sessionId: sessionId)
        onEvent(.request(peer: peer, path: matches ? Self.redactedPath : line.target))
        guard matches else {
            reject(connection, peer: peer, path: line.target)
            return
        }
        let mayConfirm = state.withLock { state -> Bool in
            guard state.outcome == nil, !state.busy, state.sealed != nil else { return false }
            state.busy = true
            return true
        }
        guard mayConfirm else {
            reject(connection, peer: peer, path: Self.redactedPath)
            return
        }
        let confirm = self.confirm
        Task { [weak self] in
            let approved = await confirm(peer)
            self?.confirmed(approved, peer: peer, on: connection)
        }
    }

    private enum Decision: Sendable {
        case send(Data)
        case decline
        case finished
    }

    private func confirmed(_ approved: Bool, peer: String, on connection: NWConnection) {
        let decision = state.withLock { state -> Decision in
            guard state.outcome == nil, let sealed = state.sealed else {
                state.busy = false
                return .finished
            }
            guard approved else {
                state.busy = false
                state.lastDeclinedPeer = peer
                return .decline
            }
            return .send(sealed)
        }
        switch decision {
        case .finished:
            respond(connection, status: 404)
        case .decline:
            respond(connection, status: 403)
        case .send(let sealed):
            connection.send(content: Self.response(status: 200, body: sealed), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
                if error == nil {
                    self?.state.withLock { _ = $0.connections.removeValue(forKey: ObjectIdentifier(connection)) }
                    self?.finish(.served(peer: peer, at: Date()))
                } else {
                    self?.state.withLock { $0.busy = false }
                }
                connection.cancel()
            })
        }
    }

    private func reject(_ connection: NWConnection, peer: String, path: String) {
        onEvent(.rejected(peer: peer, path: path))
        respond(connection, status: 404)
    }

    private func respond(_ connection: NWConnection, status: Int) {
        let reason = Self.reasonPhrase(status)
        connection.send(content: Self.response(status: status, body: Data("\(reason)\n".utf8)), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: Pure helpers

    /// The remote IP of a connection, without the port.
    static func peer(of connection: NWConnection) -> String {
        switch connection.endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let address): return "\(address)"
            case .ipv6(let address): return "\(address)"
            case .name(let name, _): return name
            @unknown default: return "\(host)"
            }
        default:
            return "\(connection.endpoint)"
        }
    }

    /// Constant-time check that `target` is exactly `/h/<sessionId>`.
    public static func pathMatches(_ target: String, sessionId: String) -> Bool {
        let expected = Array("/h/\(sessionId)".utf8)
        let actual = Array(target.utf8)
        guard expected.count == actual.count, !sessionId.isEmpty else { return false }
        var difference: UInt8 = 0
        for index in expected.indices { difference |= expected[index] ^ actual[index] }
        return difference == 0
    }

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        default: return "Error"
        }
    }

    /// A complete HTTP/1.1 response with `Content-Length`, `Cache-Control:
    /// no-store` and `Connection: close`. `200` is `application/octet-stream`;
    /// everything else is `text/plain`.
    public static func response(status: Int, body: Data) -> Data {
        let contentType = status == 200 ? "application/octet-stream" : "text/plain; charset=utf-8"
        var head = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
#endif
