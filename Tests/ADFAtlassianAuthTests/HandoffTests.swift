import CryptoKit
import Foundation
import Testing
@testable import ADFAtlassianAuth

@Suite("Pairing link")
struct PairingLinkTests {
    static let sid = Data(repeating: 0xAB, count: 16).base64URLEncodedString()
    static let key = Data((0..<32).map { UInt8($0 * 7 & 0xFF) }).base64URLEncodedString()
    static let valid = "adfreader://pair?v=1&h=192.168.1.20:54321&s=\(sid)#k=\(key)"

    @Test("format and parse round-trip")
    func roundTrip() throws {
        let link = PairingLink.generate(host: "192.168.1.20:54321")
        let parsed = try PairingLink(url: link.url)
        #expect(parsed == link)
        #expect(try PairingLink(string: " \(link.url.absoluteString)\n") == link)
        #expect(link.url.absoluteString.hasPrefix("adfreader://pair?v=1&h=192.168.1.20:54321&s="))
        #expect(link.url.fragment?.hasPrefix("k=") == true)
        #expect(link.fetchURL.absoluteString == "http://192.168.1.20:54321/h/\(link.sessionId)")
        #expect(link.fetchPath == "/h/\(link.sessionId)")
    }

    @Test("a known link parses into its parts")
    func parsesKnownLink() throws {
        let link = try PairingLink(string: Self.valid)
        #expect(link.host == "192.168.1.20:54321")
        #expect(link.sessionId == Self.sid)
        #expect(link.key.withUnsafeBytes { Data($0) } == Data((0..<32).map { UInt8($0 * 7 & 0xFF) }))
        #expect(link.url.absoluteString == Self.valid)
    }

    @Test("generated session IDs and keys have the right sizes and differ")
    func generate() {
        let a = PairingLink.generate(host: "10.0.0.2:1")
        let b = PairingLink.generate(host: "10.0.0.2:1")
        #expect(Data(base64URLEncoded: a.sessionId)?.count == 16)
        #expect(!a.sessionId.contains("="))
        #expect(a.key.bitCount == 256)
        #expect(a != b)
        #expect(a.sessionId != b.sessionId)
    }

    @Test("strict rejection", arguments: [
        ("https://pair?v=1&h=192.168.1.20:54321&s=\(sid)#k=\(key)", PairingLink.ParseError.notAPairingLink),
        ("adfreader://beam?v=1&h=192.168.1.20:54321&s=\(sid)#k=\(key)", .notAPairingLink),
        ("adfreader://pair/extra?v=1&h=192.168.1.20:54321&s=\(sid)#k=\(key)", .notAPairingLink),
        ("adfreader://pair?v=2&h=192.168.1.20:54321&s=\(sid)#k=\(key)", .unsupportedVersion("2")),
        ("adfreader://pair?h=192.168.1.20:54321&s=\(sid)#k=\(key)", .unsupportedVersion(nil)),
        ("adfreader://pair?v=1&v=1&h=192.168.1.20:54321&s=\(sid)#k=\(key)", .notAPairingLink),
        ("adfreader://pair?v=1&s=\(sid)#k=\(key)", .missingHost),
        ("adfreader://pair?v=1&h=example.com:80&s=\(sid)#k=\(key)", .invalidHost("example.com:80")),
        ("adfreader://pair?v=1&h=192.168.1.256&s=\(sid)#k=\(key)", .invalidHost("192.168.1.256")),
        ("adfreader://pair?v=1&h=192.168.1.20:0&s=\(sid)#k=\(key)", .invalidHost("192.168.1.20:0")),
        ("adfreader://pair?v=1&h=192.168.1.20:54321#k=\(key)", .missingSession),
        ("adfreader://pair?v=1&h=192.168.1.20:54321&s=abc#k=\(key)", .invalidSession),
        ("adfreader://pair?v=1&h=192.168.1.20:54321&s=\(sid)=#k=\(key)", .invalidSession),
        ("adfreader://pair?v=1&h=192.168.1.20:54321&s=\(sid)", .missingKey),
        ("adfreader://pair?v=1&h=192.168.1.20:54321&s=\(sid)#key=\(key)", .missingKey),
        ("adfreader://pair?v=1&h=192.168.1.20:54321&s=\(sid)#k=", .missingKey),
        ("adfreader://pair?v=1&h=192.168.1.20:54321&s=\(sid)&k=\(key)", .missingKey),
        ("adfreader://pair?v=1&h=192.168.1.20:54321&s=\(sid)#k=\(String(key.dropLast(2)))", .invalidKey),
        ("adfreader://pair?v=1&h=192.168.1.20:54321&s=\(sid)#k=\(key)AAAA", .invalidKey),
        ("adfreader://pair?v=1&h=192.168.1.20:54321&s=\(sid)#k=\(key.replacingOccurrences(of: "A", with: "+"))+", .invalidKey),
    ])
    func rejects(link: String, expected: PairingLink.ParseError) {
        #expect(throws: expected) { try PairingLink(string: link) }
    }

    @Test("the link and its description never contain a token, and descriptions redact the key")
    func noSecrets() throws {
        let link = PairingLink.generate(host: "192.168.1.20:54321")
        let credential = Fixture.credential()
        _ = try HandoffSeal.seal(credential, link: link)
        #expect(!link.url.absoluteString.contains(Fixture.token))
        var dumped = ""
        dump(link, to: &dumped)
        for text in ["\(link)", String(reflecting: link), dumped] {
            #expect(!text.contains(link.sessionId))
            #expect(!text.contains(link.keyString))
            #expect(text.contains("192.168.1.20:54321"))
        }
    }

    @Test("base64url helpers are strict")
    func base64URL() {
        let data = Data([0xFB, 0xFF, 0xFE])
        #expect(data.base64URLEncodedString() == "-__-")
        #expect(Data(base64URLEncoded: "-__-") == data)
        #expect(Data(base64URLEncoded: "+//+") == nil)
        #expect(Data(base64URLEncoded: "AA==") == nil)
        #expect(Data(base64URLEncoded: "") == nil)
        #expect(Data(base64URLEncoded: "A") == nil)
    }
}

@Suite("Handoff seal")
struct HandoffSealTests {
    @Test("seal then open returns the credential")
    func roundTrip() throws {
        let link = PairingLink.generate(host: "10.0.0.2:4000")
        let credential = Fixture.credential()
        let sealed = try HandoffSeal.seal(credential, link: link)
        #expect(sealed.range(of: Data(Fixture.token.utf8)) == nil)
        #expect(try HandoffSeal.open(sealed, link: link) == credential)
    }

    @Test("open fails with the wrong key")
    func wrongKey() throws {
        let link = PairingLink.generate(host: "10.0.0.2:4000")
        let sealed = try HandoffSeal.seal(Fixture.credential(), link: link)
        let other = try PairingLink(host: link.host, sessionId: link.sessionId, key: SymmetricKey(size: .bits256))
        #expect(throws: HandoffError.decryptionFailed) { try HandoffSeal.open(sealed, link: other) }
    }

    @Test("open fails with the wrong session ID (authenticated data)")
    func wrongSession() throws {
        let link = PairingLink.generate(host: "10.0.0.2:4000")
        let sealed = try HandoffSeal.seal(Fixture.credential(), link: link)
        let other = try PairingLink(host: link.host, sessionId: PairingLink.generate(host: link.host).sessionId, key: link.key)
        #expect(throws: HandoffError.decryptionFailed) { try HandoffSeal.open(sealed, link: other) }
    }

    @Test("open fails on tampered or truncated data")
    func tampered() throws {
        let link = PairingLink.generate(host: "10.0.0.2:4000")
        var sealed = try HandoffSeal.seal(Fixture.credential(), link: link)
        sealed[sealed.startIndex + 20] ^= 0x01
        #expect(throws: HandoffError.decryptionFailed) { try HandoffSeal.open(sealed, link: link) }
        #expect(throws: HandoffError.decryptionFailed) { try HandoffSeal.open(Data([1, 2, 3]), link: link) }
    }

    @Test("sealing an invalid credential is refused")
    func sealValidates() {
        var credential = Fixture.credential()
        credential.token = ""
        #expect(throws: HandoffError.invalidCredential(AtlassianCredential.ValidationError.emptyToken.message)) {
            try HandoffSeal.seal(credential, link: PairingLink.generate(host: "10.0.0.2:4000"))
        }
    }
}

@Suite("Handoff client")
struct HandoffClientTests {
    @Test("200 opens the sealed box with one GET to the fetch URL")
    func success() async throws {
        let link = PairingLink.generate(host: "192.168.1.20:54321")
        let credential = Fixture.credential()
        let sealed = try HandoffSeal.seal(credential, link: link)
        let stub = AuthStubProtocol.session(responding: .init(status: 200, headers: ["Content-Type": "application/octet-stream"], body: sealed))
        let received = try await HandoffClient.fetch(link, session: stub.session)
        #expect(received == credential)
        #expect(stub.requests.count == 1)
        #expect(stub.requests.first?.method == "GET")
        #expect(stub.requests.first?.url == link.fetchURL)
    }

    @Test("404 and 410 say the code was already used or expired", arguments: [404, 410])
    func spent(status: Int) async {
        let stub = AuthStubProtocol.session(responding: .init(status: status, headers: [:], body: Data()))
        await #expect(throws: HandoffError.alreadyUsedOrExpired) {
            try await HandoffClient.fetch(PairingLink.generate(host: "192.168.1.20:1"), session: stub.session)
        }
        #expect(HandoffError.alreadyUsedOrExpired.message == "This pairing code was already used or expired. Run `adf-auth push` again.")
    }

    @Test("other failures map to declined, http and network errors")
    func otherFailures() async {
        let link = PairingLink.generate(host: "192.168.1.20:1")
        await #expect(throws: HandoffError.declined) {
            try await HandoffClient.fetch(link, session: AuthStubProtocol.session(responding: .init(status: 403, headers: [:], body: Data())).session)
        }
        await #expect(throws: HandoffError.http(status: 500)) {
            try await HandoffClient.fetch(link, session: AuthStubProtocol.session(responding: .init(status: 500, headers: [:], body: Data())).session)
        }
        await #expect(throws: HandoffError.decryptionFailed) {
            try await HandoffClient.fetch(link, session: AuthStubProtocol.session(responding: .init(status: 200, headers: [:], body: Data("garbage-garbage-garbage-garbage".utf8))).session)
        }
        await #expect {
            try await HandoffClient.fetch(link, session: AuthStubProtocol.session { _ in .failure(URLError(.timedOut)) }.session)
        } throws: { error in
            if case .network = error as? HandoffError { return true }
            return false
        }
    }
}

@Suite("HTTP request line")
struct HTTPRequestLineTests {
    @Test("parses a GET request line")
    func parsesGet() {
        let head = Data("GET /h/abc HTTP/1.1\r\nHost: 1.2.3.4\r\n\r\n".utf8)
        #expect(HTTPRequestLine.parse(head) == HTTPRequestLine(method: "GET", target: "/h/abc", version: "HTTP/1.1"))
        #expect(HTTPRequestLine.headLength(in: head) == head.count)
        #expect(HTTPRequestLine.headLength(in: Data("GET / HTTP/1.1\r\nHost".utf8)) == nil)
    }

    @Test("rejects malformed lines", arguments: [
        "",
        "GET /h/abc HTTP/1.1",
        "GET /h/abc\r\n",
        "GET  /h/abc HTTP/1.1\r\n",
        "get /h/abc HTTP/1.1\r\n",
        "GET h/abc HTTP/1.1\r\n",
        "GET http://x/h/abc HTTP/1.1\r\n",
        "GET /h/abc HTTP/2\r\n",
        "GET /h/a\u{7F}bc HTTP/1.1\r\n",
        "GET /h/a\tbc HTTP/1.1\r\n",
    ])
    func rejects(line: String) {
        #expect(HTTPRequestLine.parse(Data(line.utf8)) == nil)
    }

    #if os(macOS)
    @Test("path matching is exact")
    func pathMatches() {
        #expect(HandoffServer.pathMatches("/h/abc", sessionId: "abc"))
        #expect(!HandoffServer.pathMatches("/h/abd", sessionId: "abc"))
        #expect(!HandoffServer.pathMatches("/h/abc/", sessionId: "abc"))
        #expect(!HandoffServer.pathMatches("/h/abc?x", sessionId: "abc"))
        #expect(!HandoffServer.pathMatches("/h/", sessionId: ""))
    }

    @Test("responses carry length, no-store and close")
    func response() {
        let text = String(decoding: HandoffServer.response(status: 200, body: Data("xyz".utf8)), as: UTF8.self)
        #expect(text == "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 3\r\nCache-Control: no-store\r\nConnection: close\r\n\r\nxyz")
        #expect(String(decoding: HandoffServer.response(status: 404, body: Data()), as: UTF8.self).hasPrefix("HTTP/1.1 404 Not Found\r\n"))
    }
    #endif
}
