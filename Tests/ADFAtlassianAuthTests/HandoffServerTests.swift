#if os(macOS)
import Foundation
import os
import Testing
@testable import ADFAtlassianAuth

/// Loopback-only tests of the one-shot listener. Each test binds 127.0.0.1
/// on an ephemeral port and uses a fresh ephemeral URLSession per request.
@Suite("Handoff server (loopback)")
struct HandoffServerTests {
    final class EventLog: Sendable {
        private let events = OSAllocatedUnfairLock<[HandoffServer.Event]>(initialState: [])
        func append(_ event: HandoffServer.Event) { events.withLock { $0.append(event) } }
        var all: [HandoffServer.Event] { events.withLock { $0 } }
    }

    struct Fetch: Sendable {
        let status: Int?
        let body: Data?
        let failed: Bool
    }

    static func get(port: UInt16, path: String) async -> Fetch {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5)
        request.httpMethod = "GET"
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            return Fetch(status: (response as? HTTPURLResponse)?.statusCode, body: data, failed: false)
        } catch {
            return Fetch(status: nil, body: nil, failed: true)
        }
    }

    func makeServer(
        sealed: Data = Data("sealed-box-bytes".utf8),
        sessionId: String = "session-abc",
        timeout: Duration = .seconds(10),
        confirm: @escaping @Sendable (String) async -> Bool = { _ in true },
        log: EventLog
    ) -> HandoffServer {
        HandoffServer(sealed: sealed, sessionId: sessionId, bindHost: "127.0.0.1", port: 0, timeout: timeout, confirm: confirm, onEvent: { log.append($0) })
    }

    @Test("serves the sealed box exactly once, then stops listening")
    func servesOnce() async throws {
        let log = EventLog()
        let link = PairingLink.generate(host: "127.0.0.1:1")
        let sealed = try HandoffSeal.seal(Fixture.credential(), link: link)
        let server = makeServer(sealed: sealed, sessionId: link.sessionId, log: log)
        let port = try await server.start()
        #expect(port != 0)
        #expect(log.all.first == .listening(port: port))

        let first = await Self.get(port: port, path: "/h/\(link.sessionId)")
        #expect(first.status == 200)
        #expect(first.body == sealed)
        #expect(try HandoffSeal.open(try #require(first.body), link: link) == Fixture.credential())

        let outcome = await server.waitForCompletion()
        guard case .served(let peer, _) = outcome else {
            Issue.record("expected .served, got \(outcome)")
            return
        }
        #expect(peer == "127.0.0.1")

        let second = await Self.get(port: port, path: "/h/\(link.sessionId)")
        #expect(second.status != 200, "a spent code is never served again")
        #expect(second.body != sealed)
        #expect(log.all.contains(.request(peer: "127.0.0.1", path: HandoffServer.redactedPath)))
        #expect(!log.all.contains { "\($0)".contains(link.sessionId) }, "events never carry the session ID")
    }

    @Test("an unknown path gets 404 and a rejected event, and the code stays valid")
    func unknownPath() async throws {
        let log = EventLog()
        let server = makeServer(log: log)
        let port = try await server.start()

        let wrong = await Self.get(port: port, path: "/h/not-the-session")
        #expect(wrong.status == 404)
        #expect(log.all.contains(.rejected(peer: "127.0.0.1", path: "/h/not-the-session")))

        let right = await Self.get(port: port, path: "/h/session-abc")
        #expect(right.status == 200)
        #expect(right.body == Data("sealed-box-bytes".utf8))
        if case .served = await server.waitForCompletion() {} else { Issue.record("expected .served") }
    }

    @Test("a declined confirmation gets 403, nothing is served, and the outcome is declined")
    func declined() async throws {
        let log = EventLog()
        let asked = OSAllocatedUnfairLock(initialState: [String]())
        let server = makeServer(timeout: .milliseconds(800), confirm: { peer in
            asked.withLock { $0.append(peer) }
            return false
        }, log: log)
        let port = try await server.start()

        let response = await Self.get(port: port, path: "/h/session-abc")
        #expect(response.status == 403)
        #expect(response.body != Data("sealed-box-bytes".utf8))
        #expect(asked.withLock { $0 } == ["127.0.0.1"])

        #expect(await server.waitForCompletion() == .declined(peer: "127.0.0.1"))
        let after = await Self.get(port: port, path: "/h/session-abc")
        #expect(after.status != 200)
    }

    @Test("with no request the server times out")
    func timesOut() async throws {
        let log = EventLog()
        let server = makeServer(timeout: .milliseconds(300), log: log)
        let port = try await server.start()
        #expect(await server.waitForCompletion() == .timedOut)
        let after = await Self.get(port: port, path: "/h/session-abc")
        #expect(after.status != 200)
    }

    @Test("cancel stops the server")
    func cancels() async throws {
        let server = makeServer(log: EventLog())
        _ = try await server.start()
        server.cancel()
        #expect(await server.waitForCompletion() == .cancelled)
        server.cancel()
        #expect(await server.waitForCompletion() == .cancelled)
    }

    @Test("a malformed request gets 404 and a rejected event")
    func malformed() async throws {
        let log = EventLog()
        let server = makeServer(log: log)
        let port = try await server.start()
        let response = await Self.get(port: port, path: "/h/session-abc?extra=1")
        #expect(response.status == 404)
        #expect(log.all.contains(.rejected(peer: "127.0.0.1", path: "/h/session-abc?extra=1")))
        server.cancel()
    }

    @Test("start refuses a non-IPv4 bind host and a second start")
    func startErrors() async throws {
        let bad = HandoffServer(sealed: Data(), sessionId: "s", bindHost: "localhost", confirm: { _ in true }, onEvent: { _ in })
        await #expect(throws: HandoffError.self) { try await bad.start() }

        let server = makeServer(log: EventLog())
        _ = try await server.start()
        await #expect(throws: HandoffError.self) { try await server.start() }
        server.cancel()
    }

    @Test("start fails for an address this Mac does not own", .timeLimit(.minutes(1)))
    func bindFailure() async {
        // 192.0.2.0/24 is TEST-NET-1, never assigned to a local interface.
        let server = HandoffServer(sealed: Data(), sessionId: "s", bindHost: "192.0.2.1", confirm: { _ in true }, onEvent: { _ in })
        await #expect(throws: HandoffError.self) { try await server.start() }
        guard case .failed = await server.waitForCompletion() else {
            Issue.record("expected .failed")
            return
        }
    }

    static let request = "GET /h/session-abc HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"

    @Test("a phone that disconnects while the Mac is confirming is not served, and the code stays usable", .timeLimit(.minutes(1)))
    func peerClosesDuringConfirm() async throws {
        let log = EventLog()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let firstCancelled = OSAllocatedUnfairLock(initialState: false)
        let server = makeServer(confirm: { _ in
            let call = calls.withLock { count in count += 1; return count }
            guard call == 1 else { return true }
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                firstCancelled.withLock { $0 = true }
            }
            return true // ignored: the server must not serve after the phone left
        }, log: log)
        let port = try await server.start()

        let phone = try #require(await RawTCPClient.connect(port: port))
        await phone.send(Self.request)
        #expect(await eventually { calls.withLock { $0 } == 1 })
        phone.close()
        #expect(await eventually { firstCancelled.withLock { $0 } }, "the confirm task is cancelled")

        let retry = await Self.get(port: port, path: "/h/session-abc")
        #expect(retry.status == 200)
        #expect(calls.withLock { $0 } == 2)
        if case .served = await server.waitForCompletion() {} else { Issue.record("expected .served") }
    }

    @Test("finishing while a confirmation is pending cancels it", .timeLimit(.minutes(1)))
    func timeoutCancelsConfirm() async throws {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let asked = OSAllocatedUnfairLock(initialState: false)
        let server = makeServer(timeout: .milliseconds(400), confirm: { _ in
            asked.withLock { $0 = true }
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancelled.withLock { $0 = true }
            }
            return true
        }, log: EventLog())
        let port = try await server.start()
        let phone = try #require(await RawTCPClient.connect(port: port))
        defer { phone.close() }
        await phone.send(Self.request)
        #expect(await eventually { asked.withLock { $0 } })
        #expect(await server.waitForCompletion() == .timedOut)
        #expect(await eventually { cancelled.withLock { $0 } })
    }

    @Test("connections beyond the cap are closed at once", .timeLimit(.minutes(1)))
    func connectionCap() async throws {
        #expect(makeServer(log: EventLog()).maxConnections == HandoffServer.defaultMaxConnections)
        #expect(HandoffServer.defaultMaxConnections == 8)

        let server = HandoffServer(sealed: Data("sealed-box-bytes".utf8), sessionId: "session-abc", bindHost: "127.0.0.1",
                                   timeout: .seconds(20), maxConnections: 3, headTimeout: .seconds(20),
                                   confirm: { _ in true }, onEvent: { _ in })
        let port = try await server.start()
        var idle: [RawTCPClient] = []
        for _ in 0..<3 { idle.append(try #require(await RawTCPClient.connect(port: port))) }
        #expect(await eventually { server.openConnectionCount == 3 })

        let refused = await Self.get(port: port, path: "/h/session-abc")
        #expect(refused.status != 200, "the fourth connection is not served")
        #expect(server.openConnectionCount <= 3)

        idle.forEach { $0.close() }
        #expect(await eventually { server.openConnectionCount == 0 })
        let served = await Self.get(port: port, path: "/h/session-abc")
        #expect(served.status == 200)
        _ = await server.waitForCompletion()
    }

    @Test("a connection without a complete request head is closed after the head timeout", .timeLimit(.minutes(1)))
    func headTimeout() async throws {
        #expect(makeServer(log: EventLog()).headTimeout == .seconds(10))
        let server = HandoffServer(sealed: Data("sealed-box-bytes".utf8), sessionId: "session-abc", bindHost: "127.0.0.1",
                                   timeout: .seconds(20), maxConnections: 8, headTimeout: .milliseconds(300),
                                   confirm: { _ in true }, onEvent: { _ in })
        let port = try await server.start()
        let slow = try #require(await RawTCPClient.connect(port: port))
        defer { slow.close() }
        await slow.send("GET /h/session-abc HTTP/1.1\r\nHost: 127")
        #expect(await eventually { server.openConnectionCount == 1 })
        #expect(await eventually(timeout: .seconds(5)) { server.openConnectionCount == 0 })
        let served = await Self.get(port: port, path: "/h/session-abc")
        #expect(served.status == 200)
        _ = await server.waitForCompletion()
    }

    @Test("LAN address lookup returns IPv4 text or nil")
    func lanAddress() {
        if let address = LANAddress.primaryIPv4() {
            #expect(PairingLink.isValidHost(address))
            #expect(!address.hasPrefix("127."))
        }
        for interface in LANAddress.ipv4Interfaces() {
            #expect(PairingLink.isValidHost(interface.address))
        }
    }
}
#endif
