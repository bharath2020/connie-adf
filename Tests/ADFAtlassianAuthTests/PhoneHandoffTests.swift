import CryptoKit
import Foundation
import Testing
@testable import ADFAtlassianAuth

@Suite("Phone pairing code")
struct PhonePairingCodeTests {
    @Test("generate, format and parse round-trip")
    func roundTrip() throws {
        let code = PhonePairingCode.generate()
        let text = code.formatted
        #expect(text.wholeMatch(of: /[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}/) != nil, "\(text)")
        #expect(code.bytes.count == 10)
        #expect(try PhonePairingCode(parsing: text) == code)
        #expect(try PhonePairingCode(parsing: text.lowercased()) == code)
        #expect(try PhonePairingCode(parsing: text.replacingOccurrences(of: "-", with: "")) == code)
        #expect(try PhonePairingCode(parsing: " \(text.replacingOccurrences(of: "-", with: " ")) \n") == code)
        #expect(PhonePairingCode.generate() != code)
    }

    @Test("known vectors: 80 bits, most significant bit first")
    func knownVectors() throws {
        let sequential = try #require(PhonePairingCode(bytes: Data(0..<10)))
        #expect(sequential.formatted == "000G-40R4-0M30-E209")
        let mixed = try #require(PhonePairingCode(bytes: Data([0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE, 0x01, 0x23])))
        #expect(mixed.formatted == "VTPV-XVYA-ZTXB-W093")
        #expect(try PhonePairingCode(parsing: "VTPV-XVYA-ZTXB-W093") == mixed)
        let ones = try #require(PhonePairingCode(bytes: Data(repeating: 0xFF, count: 10)))
        #expect(ones.formatted == "ZZZZ-ZZZZ-ZZZZ-ZZZZ")
        #expect(PhonePairingCode(bytes: Data(count: 9)) == nil)
    }

    @Test("Crockford aliases: I and L read as 1, O as 0, any case")
    func aliases() throws {
        let canonical = try PhonePairingCode(parsing: "1111-1111-0000-0000")
        #expect(try PhonePairingCode(parsing: "IIII-LLLL-OOOO-oooo") == canonical)
        #expect(try PhonePairingCode(parsing: "iiii-llll-0o0O-0000") == canonical)
    }

    @Test("rejects bad characters", arguments: [
        "U000-0000-0000-0000",
        "u000-0000-0000-0000",
        "0000-0000-0000-000!",
        "0000_0000_0000_0000",
        "0000-0000-0000-000Ｋ",
        "0000-0000-0000-000é",
    ])
    func badCharacters(_ text: String) {
        #expect(throws: PhonePairingCode.ParseError.invalidCharacter) { try PhonePairingCode(parsing: text) }
    }

    @Test("rejects the wrong length")
    func wrongLength() {
        #expect(throws: PhonePairingCode.ParseError.wrongLength(15)) { try PhonePairingCode(parsing: "0000-0000-0000-000") }
        #expect(throws: PhonePairingCode.ParseError.wrongLength(17)) { try PhonePairingCode(parsing: "0000-0000-0000-00000") }
        #expect(throws: PhonePairingCode.ParseError.empty) { try PhonePairingCode(parsing: "") }
        #expect(throws: PhonePairingCode.ParseError.empty) { try PhonePairingCode(parsing: " - - ") }
    }

    @Test("descriptions and errors never show the code")
    func redaction() {
        let code = PhonePairingCode.generate()
        let compact = code.formatted.replacingOccurrences(of: "-", with: "")
        for text in [code.description, code.debugDescription, String(reflecting: code), "\(code)"] {
            #expect(!text.contains(code.formatted))
            #expect(!text.contains(compact))
        }
        var dumped = ""
        dump(code, to: &dumped)
        #expect(!dumped.contains(compact))
    }
}

@Suite("Phone handoff address")
struct PhoneHandoffAddressTests {
    @Test("accepts private IPv4 with a port", arguments: [
        ("192.168.1.23:53211", "192.168.1.23", UInt16(53211)),
        (" 10.0.0.5:1\n", "10.0.0.5", 1),
        ("172.16.0.1:65535", "172.16.0.1", 65535),
        ("172.31.255.255:8080", "172.31.255.255", 8080),
        ("100.64.0.1:80", "100.64.0.1", 80),
    ])
    func accepts(_ text: String, host: String, port: UInt16) throws {
        let address = try PhoneHandoffAddress(parsing: text)
        #expect(address.host == host)
        #expect(address.port == port)
        #expect(address.description == "\(host):\(port)")
        #expect(address.pushCommand == "adf-auth push --to \(host):\(port)")
    }

    @Test("rejects public, loopback, IPv6 and malformed addresses", arguments: [
        ("8.8.8.8:80", PhoneHandoffAddress.ParseError.notLocalNetwork),
        ("127.0.0.1:8080", .notLocalNetwork),
        ("169.254.10.1:80", .notLocalNetwork),
        ("172.32.0.1:80", .notLocalNetwork),
        ("0.0.0.0:80", .notLocalNetwork),
        ("224.0.0.1:80", .notLocalNetwork),
        ("192.168.1.23", .missingPort),
        ("192.168.1.23:", .malformed),
        ("192.168.1.23:0", .malformed),
        ("192.168.1.23:65536", .malformed),
        ("192.168.01.23:80", .malformed),
        ("[::1]:80", .malformed),
        ("fe80::1", .malformed),
        ("[fd00::1]:5000", .malformed),
        ("phone.local:80", .malformed),
        ("192.168.1.23:80/x", .malformed),
        ("", .malformed),
    ])
    func rejects(_ text: String, expected: PhoneHandoffAddress.ParseError) {
        #expect(throws: expected) { try PhoneHandoffAddress(parsing: text) }
    }

    @Test("init(host:port:) applies the same rule")
    func memberwise() {
        #expect(PhoneHandoffAddress(host: "192.168.1.2", port: 5000)?.description == "192.168.1.2:5000")
        #expect(PhoneHandoffAddress(host: "127.0.0.1", port: 5000) == nil)
        #expect(PhoneHandoffAddress(host: "192.168.1.2", port: 0) == nil)
        #expect(PhoneHandoffAddress(host: "192.168.1.2:80", port: 5000) == nil)
    }

    @Test("local candidates are private addresses only")
    func localCandidates() {
        for candidate in PhoneHandoffAddress.localCandidates(port: 4242) {
            #expect(PairingLink.isLocalNetworkHost(candidate.host))
            #expect(candidate.port == 4242)
        }
    }
}

@Suite("Phone handoff handshake")
struct PhoneHandoffHandshakeTests {
    typealias H = PhoneHandoffHandshake

    struct Pair {
        let phone = Curve25519.KeyAgreement.PrivateKey()
        let mac = Curve25519.KeyAgreement.PrivateKey()
        var a: Data { phone.publicKey.rawRepresentation }
        var b: Data { mac.publicKey.rawRepresentation }
    }

    static func raw(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    @Test("wire constants")
    func constants() {
        #expect(H.magic == Data([0x41, 0x44, 0x46, 0x48, 0x32]))
        #expect(H.lengthPrefix(0x0102_0304) == Data([1, 2, 3, 4]))
        #expect(H.length(fromPrefix: Data([0, 0, 4, 0])) == 1024)
        #expect(H.maxBoxBytes == 64 * 1024)
    }

    @Test("both sides derive the same K, and it depends on the code")
    func sameKey() throws {
        let pair = Pair()
        let code = PhonePairingCode.generate()
        let phoneK = try H.sessionKey(privateKey: pair.phone, peerKey: pair.b, code: code, phoneKey: pair.a, macKey: pair.b)
        let macK = try H.sessionKey(privateKey: pair.mac, peerKey: pair.a, code: code, phoneKey: pair.a, macKey: pair.b)
        #expect(phoneK == macK)
        #expect(phoneK.bitCount == 256)
        let otherCodeK = try H.sessionKey(privateKey: pair.mac, peerKey: pair.a, code: .generate(), phoneKey: pair.a, macKey: pair.b)
        #expect(otherCodeK != macK)
        // The key is never the code itself or derived from the code alone.
        #expect(Self.raw(macK).prefix(10) != code.bytes)
        #expect(Self.raw(macK) != Self.raw(H.tagKey(code)))
    }

    @Test("K matches an independent HKDF over X25519 with the code as salt")
    func knownConstruction() throws {
        let pair = Pair()
        let code = try #require(PhonePairingCode(bytes: Data(0..<10)))
        let shared = try pair.mac.sharedSecretFromKeyAgreement(with: pair.phone.publicKey)
        let expected = shared.withUnsafeBytes { ikm in
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(ikm)), salt: Data(0..<10), info: Data("adf-handoff-v2 seal".utf8) + pair.a + pair.b, outputByteCount: 32)
        }
        let derived = try H.sessionKey(privateKey: pair.mac, peerKey: pair.a, code: code, phoneKey: pair.a, macKey: pair.b)
        #expect(derived == expected)

        let tagKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(0..<10)), salt: Data(), info: Data("adf-handoff-v2 tag".utf8), outputByteCount: 32)
        let expectedTag = Data(HMAC<SHA256>.authenticationCode(for: Data("adf-handoff-v2 phone".utf8) + pair.a + pair.b, using: tagKey))
        #expect(H.tag(code: code, phoneKey: pair.a, macKey: pair.b) == expectedTag)
    }

    @Test("T verifies with the right code and transcript only")
    func tag() {
        let pair = Pair()
        let code = PhonePairingCode.generate()
        let t = H.tag(code: code, phoneKey: pair.a, macKey: pair.b)
        #expect(t.count == H.tagBytes)
        #expect(H.isValidTag(t, code: code, phoneKey: pair.a, macKey: pair.b))
        #expect(!H.isValidTag(t, code: .generate(), phoneKey: pair.a, macKey: pair.b))
        #expect(!H.isValidTag(t, code: code, phoneKey: pair.b, macKey: pair.a), "A and B are ordered")
        #expect(!H.isValidTag(t, code: code, phoneKey: pair.a, macKey: Pair().b), "bound to this Mac's key")
        var flipped = t
        flipped[flipped.startIndex] ^= 0x01
        #expect(!H.isValidTag(flipped, code: code, phoneKey: pair.a, macKey: pair.b))
        #expect(!H.isValidTag(t.prefix(16), code: code, phoneKey: pair.a, macKey: pair.b))
    }

    @Test("the box opens only with the right code and transcript, untampered")
    func box() throws {
        let pair = Pair()
        let code = PhonePairingCode.generate()
        let macK = try H.sessionKey(privateKey: pair.mac, peerKey: pair.a, code: code, phoneKey: pair.a, macKey: pair.b)
        let phoneK = try H.sessionKey(privateKey: pair.phone, peerKey: pair.b, code: code, phoneKey: pair.a, macKey: pair.b)
        let sealed = try H.seal(Fixture.credential(), key: macK, phoneKey: pair.a, macKey: pair.b)
        #expect(!sealed.contains(Data(Fixture.token.utf8)))
        #expect(H.open(sealed, key: phoneK, phoneKey: pair.a, macKey: pair.b) == Fixture.credential())

        // Wrong code on the phone.
        let wrongK = try H.sessionKey(privateKey: pair.phone, peerKey: pair.b, code: .generate(), phoneKey: pair.a, macKey: pair.b)
        #expect(H.open(sealed, key: wrongK, phoneKey: pair.a, macKey: pair.b) == nil)
        // Right key, wrong transcript in the authenticated data.
        #expect(H.open(sealed, key: phoneK, phoneKey: Pair().a, macKey: pair.b) == nil)
        #expect(H.open(sealed, key: phoneK, phoneKey: pair.b, macKey: pair.a) == nil)
        // Tampering anywhere.
        for index in [sealed.startIndex, sealed.startIndex + 12, sealed.endIndex - 1] {
            var tampered = sealed
            tampered[index] ^= 0x80
            #expect(H.open(tampered, key: phoneK, phoneKey: pair.a, macKey: pair.b) == nil)
        }
        #expect(H.open(sealed.prefix(10), key: phoneK, phoneKey: pair.a, macKey: pair.b) == nil)
    }

    @Test("an invalid credential is never sealed, and a non-credential never opens")
    func validation() throws {
        let pair = Pair()
        let key = SymmetricKey(size: .bits256)
        do throws(PhoneHandoffError) {
            _ = try H.seal(Fixture.credential(token: ""), key: key, phoneKey: pair.a, macKey: pair.b)
            Issue.record("an empty token must not be sealed")
        } catch {
            guard case .invalidCredential = error else {
                Issue.record("expected invalidCredential, got \(error)")
                return
            }
        }
        let junk = try ChaChaPoly.seal(Data("not json".utf8), using: key, authenticating: H.aadLabel + pair.a + pair.b).combined
        #expect(H.open(junk, key: key, phoneKey: pair.a, macKey: pair.b) == nil)
    }
}

#if os(macOS)
import Network
import os

/// Loopback end-to-end tests: the phone listener binds 127.0.0.1 through
/// the test-only ``PhoneHandoffListener/Binding/loopbackForTesting`` path,
/// and the Mac sender reaches it through
/// ``PhoneHandoffAddress/init(loopbackForTestingPort:)``.
@Suite("Phone handoff (loopback)")
struct PhoneHandoffLoopbackTests {
    final class EventLog: Sendable {
        private let events = OSAllocatedUnfairLock<[PhoneHandoffListener.Event]>(initialState: [])
        func append(_ event: PhoneHandoffListener.Event) { events.withLock { $0.append(event) } }
        var all: [PhoneHandoffListener.Event] { events.withLock { $0 } }
    }

    static func makeListener(
        code: PhonePairingCode = .generate(),
        timeout: Duration = .seconds(20),
        maxFailedAttempts: Int = PhoneHandoffListener.defaultMaxFailedAttempts,
        stepTimeout: Duration = .seconds(5),
        log: EventLog
    ) -> PhoneHandoffListener {
        PhoneHandoffListener(
            code: code, port: 0, timeout: timeout, maxFailedAttempts: maxFailedAttempts,
            stepTimeout: stepTimeout, binding: .loopbackForTesting, onEvent: { log.append($0) }
        )
    }

    static func send(
        _ credential: AtlassianCredential = Fixture.credential(),
        port: UInt16,
        code: PhonePairingCode,
        timeout: Duration = .seconds(10)
    ) async -> PhoneHandoffError? {
        do throws(PhoneHandoffError) {
            try await PhoneHandoffSender.send(credential, to: PhoneHandoffAddress(loopbackForTestingPort: port), code: code, timeout: timeout, stepTimeout: .seconds(5))
            return nil
        } catch {
            return error
        }
    }

    @Test("the credential arrives intact, and the listener stops (one-shot)")
    func endToEnd() async throws {
        let log = EventLog()
        let listener = Self.makeListener(log: log)
        let port = try await listener.start()
        #expect(port != 0)
        #expect(listener.port == port)
        #expect(log.all.first == .listening(port: port))

        #expect(await Self.send(port: port, code: listener.code) == nil)
        let received = try await listener.waitForCredential()
        #expect(received == Fixture.credential())
        #expect(listener.isFinished)
        #expect(log.all.contains(.connected(peer: "127.0.0.1")))
        #expect(log.all.contains(.received(peer: "127.0.0.1")))

        // One-shot: a second send after success fails and changes nothing.
        let second = await Self.send(Fixture.credential(token: "ATATT3xFfGF0-synthetic-second"), port: port, code: listener.code, timeout: .seconds(3))
        #expect(second != nil, "a second send must fail after the one-shot listener finished")
        #expect(try await listener.waitForCredential() == Fixture.credential())
    }

    @Test("a wrong code: the Mac reports it, the phone keeps listening, then the right code works")
    func wrongCodeThenRight() async throws {
        let log = EventLog()
        let listener = Self.makeListener(log: log)
        let port = try await listener.start()

        let wrong = await Self.send(port: port, code: .generate())
        #expect(wrong == .wrongCode)
        #expect(PhoneHandoffError.wrongCode.message.contains("Wrong code"))
        #expect(await eventually { listener.failedAttempts == 1 })
        #expect(!listener.isFinished)
        #expect(log.all.contains(.attemptFailed(peer: "127.0.0.1", reason: .disconnected, failedAttempts: 1)))

        #expect(await Self.send(port: port, code: listener.code) == nil)
        #expect(try await listener.waitForCredential() == Fixture.credential())
        #expect(listener.failedAttempts == 1)
    }

    @Test("nothing connects before the timeout: the listener stops with timedOut")
    func listenerTimeout() async throws {
        let log = EventLog()
        let listener = Self.makeListener(timeout: .milliseconds(300), log: log)
        let port = try await listener.start()
        await #expect(throws: PhoneHandoffError.timedOut) { try await listener.waitForCredential() }
        #expect(listener.isFinished)
        #expect(PhoneHandoffError.timedOut.message.contains("Nothing connected before the time ran out"))
        #expect(await Self.send(port: port, code: listener.code, timeout: .seconds(3)) != nil, "a send after the timeout must fail")
    }

    @Test("cancel() stops the listener and wakes waiters")
    func cancel() async throws {
        let listener = Self.makeListener(log: EventLog())
        _ = try await listener.start()
        let waiter = Task { () -> PhoneHandoffError? in
            do throws(PhoneHandoffError) {
                _ = try await listener.waitForCredential()
                return nil
            } catch {
                return error
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        listener.cancel()
        #expect(await waiter.value == .cancelled)
    }

    @Test("garbage connections count as failures and the cap stops the listener")
    func failureCap() async throws {
        let log = EventLog()
        let listener = Self.makeListener(maxFailedAttempts: 2, log: log)
        let port = try await listener.start()
        for attempt in 1...2 {
            let client = try #require(await RawTCPClient.connect(port: port))
            await client.send("GET / HTTP/1.1\r\nHost: x\r\n\r\n__________")
            #expect(await eventually { listener.failedAttempts == attempt })
            client.close()
        }
        await #expect(throws: PhoneHandoffError.tooManyFailedAttempts(2)) { try await listener.waitForCredential() }
        #expect(log.all.contains(.attemptFailed(peer: "127.0.0.1", reason: .notAHandoff, failedAttempts: 2)))
    }

    @Test("a stalled connection is closed after the step timeout and the code stays usable")
    func stalledConnection() async throws {
        let log = EventLog()
        let listener = Self.makeListener(stepTimeout: .milliseconds(300), log: log)
        let port = try await listener.start()
        let idle = try #require(await RawTCPClient.connect(port: port))
        defer { idle.close() }
        #expect(await eventually { listener.failedAttempts == 1 })
        #expect(log.all.contains(.attemptFailed(peer: "127.0.0.1", reason: .timedOut, failedAttempts: 1)))
        #expect(await Self.send(port: port, code: listener.code) == nil)
        #expect(try await listener.waitForCredential() == Fixture.credential())
    }

    @Test("a fake phone without the code gets nothing but the greeting")
    func fakePhoneGetsNothing() async throws {
        let fake = try FakePhone(reply: Data((0..<64).map { _ in UInt8.random(in: 0...255) }))
        let port = await fake.start()
        defer { fake.stop() }
        let result = await Self.send(port: port, code: .generate())
        #expect(result == .wrongCode)
        try await Task.sleep(for: .milliseconds(200))
        let received = fake.received
        #expect(received.count == 37, "only ADFH2 || B, got \(received.count) bytes")
        #expect(received.prefix(5) == PhoneHandoffHandshake.magic)
    }

    @Test("a silent server times out on the Mac as noAnswer")
    func silentServer() async throws {
        let fake = try FakePhone(reply: nil)
        let port = await fake.start()
        defer { fake.stop() }
        let started = ContinuousClock.now
        let result = await Self.send(port: port, code: .generate(), timeout: .seconds(1))
        #expect(result == .noAnswer)
        #expect(ContinuousClock.now - started < .seconds(4))
    }

    @Test("nothing listening: connectionFailed")
    func nothingListening() async throws {
        let listener = Self.makeListener(log: EventLog())
        let port = try await listener.start()
        listener.cancel()
        try await Task.sleep(for: .milliseconds(100))
        let result = await Self.send(port: port, code: listener.code, timeout: .seconds(3))
        guard case .connectionFailed = result else {
            Issue.record("expected connectionFailed, got \(result)")
            return
        }
    }
}

/// A loopback TCP server that records everything it receives and, after
/// the first 37 bytes, optionally answers with `reply`.
final class FakePhone: Sendable {
    private let listener: NWListener
    private let reply: Data?
    private let log = OSAllocatedUnfairLock(initialState: Data())
    private let queue = DispatchQueue(label: "fake-phone")

    init(reply: Data?) throws {
        self.reply = reply
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var received: Data { log.withLock { $0 } }

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
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let content {
                let total = self.log.withLock { log -> Int in
                    log.append(content)
                    return log.count
                }
                if total >= 37, total - content.count < 37, let reply = self.reply {
                    connection.send(content: reply, completion: .contentProcessed { _ in })
                }
            }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection)
            }
        }
    }
}
#endif
