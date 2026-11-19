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

    @Test("local candidates are private Wi-Fi/wired/bridge addresses only")
    func localCandidates() {
        let lan = PhoneHandoffAddress.lanAddresses()
        for candidate in PhoneHandoffAddress.localCandidates(port: 4242) {
            #expect(PairingLink.isLocalNetworkHost(candidate.host))
            #expect(lan.contains(candidate.host))
            #expect(candidate.port == 4242)
        }
    }

    @Test("only Wi-Fi, wired and bridge interfaces are offered", arguments: [
        ("en0", true), ("en1", true), ("en7", true), ("bridge100", true), ("bridge0", true),
        ("pdp_ip0", false), ("pdp_ip1", false), ("utun0", false), ("utun4", false), ("ipsec0", false),
        ("lo0", false), ("awdl0", false), ("llw0", false), ("ap1", false), ("anpi0", false), ("", false),
    ])
    func interfaceNames(_ name: String, allowed: Bool) {
        #expect(PhoneHandoffAddress.isLANInterfaceName(name) == allowed)
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
        #expect(H.replyProceed == 0x00)
        #expect(H.replyBusy == 0x03)
        #expect(H.statusReceived == 0x01)
        #expect(H.statusRejected == 0x02)
        #expect(H.ackBytes == 33)
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

    @Test("Ka matches an independent HKDF, differs from K, and the ack verifies only untampered")
    func ack() throws {
        let pair = Pair()
        let code = try #require(PhonePairingCode(bytes: Data(0..<10)))
        let shared = try pair.mac.sharedSecretFromKeyAgreement(with: pair.phone.publicKey)
        let expectedKa = shared.withUnsafeBytes { ikm in
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(ikm)), salt: Data(0..<10), info: Data("adf-handoff-v2 ack".utf8) + pair.a + pair.b, outputByteCount: 32)
        }
        let macKeys = try H.sessionKeys(privateKey: pair.mac, peerKey: pair.a, code: code, phoneKey: pair.a, macKey: pair.b)
        let phoneKeys = try H.sessionKeys(privateKey: pair.phone, peerKey: pair.b, code: code, phoneKey: pair.a, macKey: pair.b)
        #expect(macKeys.ack == expectedKa)
        #expect(phoneKeys.ack == expectedKa)
        #expect(macKeys.ack != macKeys.seal)

        let ack = H.ack(H.statusReceived, key: phoneKeys.ack, phoneKey: pair.a, macKey: pair.b)
        #expect(ack.count == H.ackBytes)
        let expectedMAC = Data(HMAC<SHA256>.authenticationCode(for: Data([0x01]) + pair.a + pair.b, using: expectedKa))
        #expect(ack == Data([0x01]) + expectedMAC)
        #expect(H.verifiedStatus(ofAck: ack, key: macKeys.ack, phoneKey: pair.a, macKey: pair.b) == H.statusReceived)
        let rejected = H.ack(H.statusRejected, key: phoneKeys.ack, phoneKey: pair.a, macKey: pair.b)
        #expect(H.verifiedStatus(ofAck: rejected, key: macKeys.ack, phoneKey: pair.a, macKey: pair.b) == H.statusRejected)

        // Flipped status, other key, other transcript, truncated: rejected.
        var flipped = rejected
        flipped[flipped.startIndex] = H.statusReceived
        #expect(H.verifiedStatus(ofAck: flipped, key: macKeys.ack, phoneKey: pair.a, macKey: pair.b) == nil)
        #expect(H.verifiedStatus(ofAck: ack, key: macKeys.seal, phoneKey: pair.a, macKey: pair.b) == nil)
        let otherCode = try H.sessionKeys(privateKey: pair.mac, peerKey: pair.a, code: .generate(), phoneKey: pair.a, macKey: pair.b)
        #expect(H.verifiedStatus(ofAck: ack, key: otherCode.ack, phoneKey: pair.a, macKey: pair.b) == nil)
        #expect(H.verifiedStatus(ofAck: ack, key: macKeys.ack, phoneKey: pair.a, macKey: Pair().b) == nil)
        #expect(H.verifiedStatus(ofAck: ack.prefix(17), key: macKeys.ack, phoneKey: pair.a, macKey: pair.b) == nil)
        #expect(H.verifiedStatus(ofAck: Data([H.statusReceived]), key: macKeys.ack, phoneKey: pair.a, macKey: pair.b) == nil)
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
    typealias H = PhoneHandoffHandshake

    final class EventLog: Sendable {
        private let events = OSAllocatedUnfairLock<[PhoneHandoffListener.Event]>(initialState: [])
        func append(_ event: PhoneHandoffListener.Event) { events.withLock { $0.append(event) } }
        var all: [PhoneHandoffListener.Event] { events.withLock { $0 } }
    }

    static func makeListener(
        code: PhonePairingCode = .generate(),
        timeout: Duration = .seconds(20),
        maxFailedAttempts: Int = PhoneHandoffListener.defaultMaxFailedAttempts,
        connectionTimeout: Duration = .seconds(5),
        maxConcurrentHandshakes: Int = PhoneHandoffListener.defaultMaxConcurrentHandshakes,
        maxHandshakesPerPeer: Int = PhoneHandoffListener.defaultMaxHandshakesPerPeer,
        log: EventLog
    ) -> PhoneHandoffListener {
        PhoneHandoffListener(
            code: code, port: 0, timeout: timeout, maxFailedAttempts: maxFailedAttempts,
            connectionTimeout: connectionTimeout, maxConcurrentHandshakes: maxConcurrentHandshakes,
            maxHandshakesPerPeer: maxHandshakesPerPeer, binding: .loopbackForTesting, onEvent: { log.append($0) }
        )
    }

    static func send(
        _ credential: AtlassianCredential = Fixture.credential(),
        port: UInt16,
        code: PhonePairingCode,
        timeout: Duration = .seconds(10)
    ) async -> PhoneHandoffError? {
        await send(credential, to: PhoneHandoffAddress(loopbackForTestingPort: port), code: code, timeout: timeout)
    }

    static func send(
        _ credential: AtlassianCredential = Fixture.credential(),
        to address: PhoneHandoffAddress,
        code: PhonePairingCode,
        timeout: Duration = .seconds(10)
    ) async -> PhoneHandoffError? {
        do throws(PhoneHandoffError) {
            try await PhoneHandoffSender.send(credential, to: address, code: code, timeout: timeout, stepTimeout: .seconds(5))
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

    @Test("a wrong code: the Mac reports it, the phone keeps listening without counting it, then the right code works")
    func wrongCodeThenRight() async throws {
        let log = EventLog()
        let listener = Self.makeListener(log: log)
        let port = try await listener.start()

        let wrong = await Self.send(port: port, code: .generate())
        #expect(wrong == .wrongCode)
        #expect(PhoneHandoffError.wrongCode.message.contains("Wrong code"))
        #expect(await eventually { log.all.contains(.attemptFailed(peer: "127.0.0.1", reason: .disconnected, failedAttempts: 0)) })
        #expect(!listener.isFinished)
        #expect(listener.failedAttempts == 0, "a Mac hanging up is not a code guess")

        #expect(await Self.send(port: port, code: listener.code) == nil)
        #expect(try await listener.waitForCredential() == Fixture.credential())
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

    @Test("start() in a cancelled task cancels the listener")
    func startCancelled() async {
        let listener = Self.makeListener(log: EventLog())
        let task = Task { () -> PhoneHandoffError? in
            try? await Task.sleep(for: .seconds(5))
            do throws(PhoneHandoffError) {
                _ = try await listener.start()
                return nil
            } catch {
                return error
            }
        }
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(listener.isFinished)
    }

    @Test("junk connections never count; only boxes that don't open do, and the cap stops the listener")
    func failureCapCountsOnlyGuesses() async throws {
        let log = EventLog()
        let listener = Self.makeListener(maxFailedAttempts: 2, log: log)
        let port = try await listener.start()

        // More junk than the cap: none of it counts.
        for _ in 1...3 {
            let client = try #require(await RawTCPClient.connect(port: port))
            await client.send("GET / HTTP/1.1\r\nHost: x\r\n\r\n__________")
            #expect(await eventually { listener.openConnections == 0 })
            client.close()
        }
        let empty = try #require(await RawTCPClient.connect(port: port))
        empty.close()
        #expect(await eventually { log.all.filter { if case .attemptFailed = $0 { true } else { false } }.count >= 4 })
        #expect(listener.failedAttempts == 0)
        #expect(!listener.isFinished)
        #expect(log.all.contains(.attemptFailed(peer: "127.0.0.1", reason: .notAHandoff, failedAttempts: 0)))

        // Real guesses: a box sealed under a wrong code. The phone answers
        // "rejected" (under its own Ka) and counts it.
        for attempt in 1...2 {
            let mac = try #require(await ManualMac.connect(port: port))
            let reply = try #require(await mac.greet())
            #expect(reply.first == H.replyProceed)
            let ack = await mac.sendBox(code: .generate(), phoneKey: Data(reply.dropFirst().prefix(H.publicKeyBytes)))
            #expect(ack?.count == H.ackBytes)
            #expect(ack?.first == H.statusRejected)
            #expect(await eventually { listener.failedAttempts == attempt })
            mac.close()
        }
        await #expect(throws: PhoneHandoffError.tooManyFailedAttempts(2)) { try await listener.waitForCredential() }
        #expect(log.all.contains(.attemptFailed(peer: "127.0.0.1", reason: .couldNotOpen, failedAttempts: 2)))
    }

    @Test("a stalled connection is closed after the connection timeout, without counting, and the code stays usable")
    func stalledConnection() async throws {
        let log = EventLog()
        let listener = Self.makeListener(connectionTimeout: .milliseconds(300), log: log)
        let port = try await listener.start()
        let idle = try #require(await RawTCPClient.connect(port: port))
        defer { idle.close() }
        #expect(await eventually { log.all.contains(.attemptFailed(peer: "127.0.0.1", reason: .timedOut, failedAttempts: 0)) })
        #expect(listener.failedAttempts == 0)
        #expect(await Self.send(port: port, code: listener.code) == nil)
        #expect(try await listener.waitForCredential() == Fixture.credential())
    }

    @Test("a stalled junk connection doesn't block a real Mac")
    func stalledDoesNotBlock() async throws {
        let log = EventLog()
        let listener = Self.makeListener(connectionTimeout: .seconds(15), log: log)
        let port = try await listener.start()
        let idle = try #require(await RawTCPClient.connect(port: port))
        defer { idle.close() }
        #expect(await eventually { listener.openConnections == 1 })
        let started = ContinuousClock.now
        #expect(await Self.send(port: port, code: listener.code) == nil)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(try await listener.waitForCredential() == Fixture.credential())
        #expect(listener.failedAttempts == 0)
    }

    @Test("over the limit the phone answers busy; the Mac says so, and a retry works once a slot frees")
    func busy() async throws {
        let log = EventLog()
        let listener = Self.makeListener(connectionTimeout: .seconds(15), maxConcurrentHandshakes: 1, log: log)
        let port = try await listener.start()
        let idle = try #require(await RawTCPClient.connect(port: port))
        #expect(await eventually { listener.openConnections == 1 })

        #expect(await Self.send(port: port, code: listener.code) == .phoneBusy)
        #expect(PhoneHandoffError.phoneBusy.message.contains("busy"))
        #expect(await eventually { log.all.contains(.busy(peer: "127.0.0.1")) })
        #expect(!listener.isFinished)
        #expect(listener.failedAttempts == 0)

        idle.close()
        #expect(await eventually { listener.openConnections == 0 })
        #expect(await Self.send(port: port, code: listener.code) == nil)
        #expect(try await listener.waitForCredential() == Fixture.credential())
    }

    @Test("one address can hold at most two handshakes; the next connection from it is busy")
    func perPeerLimit() async throws {
        let listener = Self.makeListener(connectionTimeout: .seconds(15), log: EventLog())
        let port = try await listener.start()
        let first = try #require(await RawTCPClient.connect(port: port))
        let second = try #require(await RawTCPClient.connect(port: port))
        defer {
            first.close()
            second.close()
        }
        #expect(await eventually { listener.openConnections == 2 })
        #expect(await Self.send(port: port, code: listener.code) == .phoneBusy)
        first.close()
        #expect(await eventually { listener.openConnections == 1 })
        #expect(await Self.send(port: port, code: listener.code) == nil)
    }

    @Test("one-shot with concurrent connections: the first box that opens wins and every other connection is closed")
    func oneShotConcurrent() async throws {
        let log = EventLog()
        let listener = Self.makeListener(connectionTimeout: .seconds(15), maxHandshakesPerPeer: 4, log: log)
        let port = try await listener.start()
        let idle = try #require(await RawTCPClient.connect(port: port))
        defer { idle.close() }
        // A second Mac that knows the code, parked after the phone's reply.
        let parked = try #require(await ManualMac.connect(port: port))
        defer { parked.close() }
        let reply = try #require(await parked.greet())
        #expect(await eventually { listener.openConnections == 2 })

        #expect(await Self.send(port: port, code: listener.code) == nil)
        #expect(try await listener.waitForCredential() == Fixture.credential())
        #expect(await eventually { listener.openConnections == 0 })

        // The parked Mac's box, even with the right code, gets nothing back
        // and changes nothing.
        let late = await parked.sendBox(
            Fixture.credential(token: "ATATT3xFfGF0-synthetic-late"),
            code: listener.code,
            phoneKey: Data(reply.dropFirst().prefix(H.publicKeyBytes))
        )
        #expect(late == nil)
        #expect(try await listener.waitForCredential() == Fixture.credential())
        #expect(log.all.filter { if case .received = $0 { true } else { false } }.count == 1)
    }

    @Test("the Mac rejects a missing or forged acknowledgement", arguments: ScriptedPhone.Ack.allCases)
    func acknowledgement(_ ack: ScriptedPhone.Ack) async throws {
        let code = PhonePairingCode.generate()
        let phone = try ScriptedPhone(code: code, ack: ack)
        let port = await phone.start()
        defer { phone.stop() }
        let result = await Self.send(port: port, code: code, timeout: .seconds(3))
        switch ack {
        case .genuineReceived: #expect(result == nil)
        case .genuineRejected: #expect(result == .rejectedByPhone)
        case .none, .forgedReceived, .wrongKey, .truncated, .bareStatusByte: #expect(result == .unconfirmed)
        }
        #expect(PhoneHandoffError.unconfirmed.message.contains("couldn't confirm the phone received it"))
    }

    @Test("a fake phone without the code gets nothing but the greeting")
    func fakePhoneGetsNothing() async throws {
        let fake = try FakePhone(reply: Data([H.replyProceed]) + Data((0..<64).map { _ in UInt8.random(in: 0...255) }))
        let port = await fake.start()
        defer { fake.stop() }
        let result = await Self.send(port: port, code: .generate())
        #expect(result == .wrongCode)
        try await Task.sleep(for: .milliseconds(200))
        let received = fake.received
        #expect(received.count == 37, "only ADFH2 || B, got \(received.count) bytes")
        #expect(received.prefix(5) == PhoneHandoffHandshake.magic)
    }

    @Test("a server that answers with something else is a protocol mismatch")
    func notAPhone() async throws {
        let fake = try FakePhone(reply: Data("HTTP/1.1 400 Bad Request\r\n\r\n".utf8))
        let port = await fake.start()
        defer { fake.stop() }
        #expect(await Self.send(port: port, code: .generate(), timeout: .seconds(3)) == .protocolMismatch)
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
            Issue.record("expected connectionFailed, got \(String(describing: result))")
            return
        }
    }

    @Test("the real binding on this Mac's Wi-Fi/LAN address passes the interface checks",
          .enabled(if: !PhoneHandoffAddress.lanAddresses().isEmpty))
    func lanBinding() async throws {
        let log = EventLog()
        let listener = PhoneHandoffListener(code: .generate(), timeout: .seconds(20), connectionTimeout: .seconds(5), onEvent: { log.append($0) })
        let port = try await listener.start()
        defer { listener.cancel() }
        let address = try #require(PhoneHandoffAddress.local(port: port))
        #expect(PhoneHandoffAddress.lanAddresses().contains(address.host))
        #expect(await Self.send(to: address, code: listener.code) == nil)
        #expect(try await listener.waitForCredential() == Fixture.credential())
    }
}

/// The Mac side done by hand: it skips the T check, so it can park after
/// the phone's reply or send a box sealed under any code (an online guess).
final class ManualMac: Sendable {
    typealias H = PhoneHandoffHandshake
    let wire: HandoffWire
    let privateKey = Curve25519.KeyAgreement.PrivateKey()
    var macKey: Data { privateKey.publicKey.rawRepresentation }

    private init(wire: HandoffWire) {
        self.wire = wire
    }

    static func connect(port: UInt16) async -> ManualMac? {
        guard case .success(let wire) = await HandoffWire.connect(host: "127.0.0.1", port: port, timeout: .seconds(3), queue: DispatchQueue(label: "manual-mac")) else {
            return nil
        }
        return ManualMac(wire: wire)
    }

    /// Sends the greeting; returns 0x00 || A || T, or nil.
    func greet() async -> Data? {
        guard case .success = await wire.send(H.magic + macKey, timeout: .seconds(3)),
              case .success(let reply) = await wire.receive(exactly: 1 + H.publicKeyBytes + H.tagBytes, timeout: .seconds(3))
        else { return nil }
        return reply
    }

    /// Seals under `code` and sends; returns the 33-byte acknowledgement, or nil.
    func sendBox(_ credential: AtlassianCredential = Fixture.credential(), code: PhonePairingCode, phoneKey: Data) async -> Data? {
        guard let key = try? H.sessionKey(privateKey: privateKey, peerKey: phoneKey, code: code, phoneKey: phoneKey, macKey: macKey),
              let box = try? H.seal(credential, key: key, phoneKey: phoneKey, macKey: macKey),
              case .success = await wire.send(H.lengthPrefix(box.count) + box, timeout: .seconds(3)),
              case .success(let ack) = await wire.receive(exactly: H.ackBytes, timeout: .seconds(3))
        else { return nil }
        return ack
    }

    func close() {
        wire.close()
    }
}

/// A loopback phone that knows the code and runs the real handshake up to
/// the box, then answers with a chosen acknowledgement.
final class ScriptedPhone: Sendable {
    typealias H = PhoneHandoffHandshake

    enum Ack: CaseIterable, Sendable {
        case genuineReceived
        case genuineRejected
        /// Closes without one.
        case none
        /// 0x01 and 32 random bytes.
        case forgedReceived
        /// 0x01 with a MAC under K (the seal key) instead of Ka.
        case wrongKey
        /// 0x01 and half a MAC, then close.
        case truncated
        /// The old unauthenticated status byte alone, then close.
        case bareStatusByte
    }

    private let listener: NWListener
    private let code: PhonePairingCode
    private let ack: Ack
    private let queue = DispatchQueue(label: "scripted-phone")

    init(code: PhonePairingCode, ack: Ack) throws {
        self.code = code
        self.ack = ack
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async -> UInt16 {
        await withCheckedContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { [listener] state in
                guard case .ready = state, once.claim() else { return }
                continuation.resume(returning: listener.port?.rawValue ?? 0)
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.queue)
                Task { await self.serve(HandoffWire(connection: connection, queue: self.queue)) }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ wire: HandoffWire) async {
        defer { wire.close() }
        guard case .success(let hello) = await wire.receive(exactly: H.magic.count + H.publicKeyBytes, timeout: .seconds(3)) else { return }
        let macKey = Data(hello.suffix(H.publicKeyBytes))
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let phoneKey = privateKey.publicKey.rawRepresentation
        let tag = H.tag(code: code, phoneKey: phoneKey, macKey: macKey)
        guard case .success = await wire.send(Data([H.replyProceed]) + phoneKey + tag, timeout: .seconds(3)),
              case .success(let lengthBytes) = await wire.receive(exactly: H.lengthBytes, timeout: .seconds(3)),
              case .success = await wire.receive(exactly: H.length(fromPrefix: lengthBytes), timeout: .seconds(3)),
              let keys = try? H.sessionKeys(privateKey: privateKey, peerKey: macKey, code: code, phoneKey: phoneKey, macKey: macKey)
        else { return }
        let reply: Data
        switch ack {
        case .genuineReceived: reply = H.ack(H.statusReceived, key: keys.ack, phoneKey: phoneKey, macKey: macKey)
        case .genuineRejected: reply = H.ack(H.statusRejected, key: keys.ack, phoneKey: phoneKey, macKey: macKey)
        case .none: return
        case .forgedReceived: reply = Data([H.statusReceived]) + Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        case .wrongKey: reply = H.ack(H.statusReceived, key: keys.seal, phoneKey: phoneKey, macKey: macKey)
        case .truncated: reply = H.ack(H.statusReceived, key: keys.ack, phoneKey: phoneKey, macKey: macKey).prefix(17)
        case .bareStatusByte: reply = Data([H.statusReceived])
        }
        _ = await wire.send(reply, timeout: .seconds(3))
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
