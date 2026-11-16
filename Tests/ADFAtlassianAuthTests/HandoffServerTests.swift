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
