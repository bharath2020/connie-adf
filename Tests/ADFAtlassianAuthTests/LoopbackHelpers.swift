#if os(macOS)
import Foundation
import Network
import os
@testable import ADFAtlassianAuth

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// A raw TCP client on 127.0.0.1, for requests URLSession can't make
/// (partial heads, closing mid-request, idle connections).
final class RawTCPClient: Sendable {
    let connection: NWConnection

    private init(connection: NWConnection) {
        self.connection = connection
    }

    static func connect(port: UInt16) async -> RawTCPClient? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        let ready: Bool = await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            connection.stateUpdateHandler = { state in
                let result: Bool?
                switch state {
                case .ready: result = true
                case .failed, .cancelled: result = false
                default: result = nil
                }
                guard let result, resumed.withLock({ old in defer { old = true }; return !old }) else { return }
                continuation.resume(returning: result)
            }
            connection.start(queue: .global())
        }
        return ready ? RawTCPClient(connection: connection) : nil
    }

    func send(_ text: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    func close() {
        connection.cancel()
    }
}

/// A tiny loopback HTTP server that answers each path with a canned raw
/// response and records which paths were requested.
final class CannedHTTPServer: Sendable {
    private let routes = OSAllocatedUnfairLock<[String: Data]>(initialState: [:])
    private let hitLog = OSAllocatedUnfairLock<[String]>(initialState: [])
    private let listener: NWListener
    private let queue = DispatchQueue(label: "canned-http-server")

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var hits: [String] { hitLog.withLock { $0 } }

    func route(_ path: String, raw: String) {
        routes.withLock { $0[path] = Data(raw.utf8) }
    }

    func route(_ path: String, raw: Data) {
        routes.withLock { $0[path] = raw }
    }

    func start() async -> UInt16 {
        await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { [listener] state in
                guard case .ready = state, resumed.withLock({ old in defer { old = true }; return !old }) else { return }
                continuation.resume(returning: listener.port?.rawValue ?? 0)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] content, _, _, _ in
            guard let self, let content, let line = HTTPRequestLine.parse(content) else {
                connection.cancel()
                return
            }
            self.hitLog.withLock { $0.append(line.target) }
            let response = self.routes.withLock { $0[line.target] }
                ?? Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
#endif
