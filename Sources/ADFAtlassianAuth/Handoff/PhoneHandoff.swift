import CryptoKit
import Foundation
import Network
import os

/// Failures of the "Mac connects to phone" handoff (``PhoneHandoffListener``
/// on the phone, ``PhoneHandoffSender`` on the Mac), each with a
/// user-facing ``message``.
public enum PhoneHandoffError: Error, Sendable, Equatable {
    // MARK: Phone (listener)

    /// The listener could not start (or failed while listening).
    case listenerFailed(String)
    /// No Mac completed the handoff before the listener's time ran out.
    case timedOut
    /// ``PhoneHandoffListener/cancel()`` was called (or the waiting task was cancelled).
    case cancelled
    /// This many sealed credentials failed to open (online guesses of the
    /// code), so the listener stopped to be safe.
    case tooManyFailedAttempts(Int)

    // MARK: Mac (sender)

    /// The phone's proof did not match the typed code: the code is wrong,
    /// or something other than the phone answered. Nothing was sent.
    case wrongCode
    /// No TCP connection to the phone.
    case connectionFailed(String)
    /// The phone stopped answering (or closed) before the handoff finished.
    case noAnswer
    /// The address answered, but not with the handoff protocol.
    case protocolMismatch
    /// The phone is already handling other connections. Nothing was sent.
    case phoneBusy
    /// The phone received the box but could not open or use it.
    case rejectedByPhone
    /// The box was sent, but no authenticated "received" came back (none
    /// at all, or one that doesn't verify), so delivery is unconfirmed.
    case unconfirmed
    /// The saved credential failed validation before sending.
    case invalidCredential(String)
    case sealFailed(String)

    public var message: String {
        switch self {
        case .listenerFailed(let detail):
            return "Couldn't listen for the Mac: \(detail)"
        case .timedOut:
            return "Nothing connected before the time ran out. Open this screen again for a new code."
        case .cancelled:
            return "Stopped waiting for the Mac."
        case .tooManyFailedAttempts(let count):
            return "Stopped listening after \(count) attempts with a wrong code. Open this screen again for a new code."
        case .wrongCode:
            return "Wrong code, or that address isn't your phone. Nothing was sent. Check the code on the phone's screen and try again."
        case .connectionFailed(let detail):
            return "Couldn't connect to the phone: \(detail) Check the address on the phone's screen, keep that screen open, put the phone and the Mac on the same Wi-Fi, and make sure no VPN blocks local-network access."
        case .noAnswer:
            return "The phone stopped answering before the handoff finished. Nothing was added; try again while the phone shows the code."
        case .protocolMismatch:
            return "Something answered at that address, but it isn't ADFReader's \"Mac connects to phone\" screen. Check the address and port, and that the Mac reaches the phone over the same Wi-Fi (not through a VPN)."
        case .phoneBusy:
            return "The phone is busy with other connections, so nothing was sent. Wait a few seconds and try again while the phone shows the code."
        case .rejectedByPhone:
            return "The phone couldn't open the credential, so nothing was added. Open the screen on the phone again and retry."
        case .unconfirmed:
            return "The credential was sent, but adf-auth couldn't confirm the phone received it. Check the phone: if it asks \"Add <site> as <email>?\" for this account, tap Add; otherwise try again."
        case .invalidCredential(let detail):
            return "The saved account can't be sent: \(detail)"
        case .sealFailed(let detail):
            return "Couldn't encrypt the credential: \(detail)"
        }
    }
}

/// The v2 handshake (`docs/Atlassian-Auth.md`, "Mac connects to phone").
///
/// ```text
/// Mac   -> phone  "ADFH2" || B
/// phone -> Mac    0x00 || A || T   T  = HMAC-SHA256(Kt, "adf-handoff-v2 phone" || A || B)
///                                  Kt = HKDF-SHA256(ikm: C, salt: empty, info: "adf-handoff-v2 tag")
///            or   0x03 (busy), then close
/// Mac   -> phone  len32 || box     box = ChaChaPoly(K, aad: "adf-handoff-v2" || A || B)
///                                  K   = HKDF-SHA256(ikm: X25519(b, A), salt: C, info: "adf-handoff-v2 seal" || A || B)
/// phone -> Mac    s || M           s   = 0x01 (received) | 0x02 (rejected)
///                                  M   = HMAC-SHA256(Ka, s || A || B)
///                                  Ka  = HKDF-SHA256(ikm: X25519(b, A), salt: C, info: "adf-handoff-v2 ack" || A || B)
/// ```
///
/// A and B are raw 32-byte ephemeral X25519 public keys, C is the code.
enum PhoneHandoffHandshake {
    static let magic = Data("ADFH2".utf8)
    static let publicKeyBytes = 32
    static let tagBytes = 32
    /// Box length prefix: UInt32 big-endian.
    static let lengthBytes = 4
    /// The largest box accepted (a sealed credential is ~1 KiB).
    static let maxBoxBytes = HandoffClient.maxResponseBytes

    /// First byte of the phone's reply: A || T follows.
    static let replyProceed: UInt8 = 0x00
    /// First byte of the phone's reply: too many connections; nothing follows.
    static let replyBusy: UInt8 = 0x03

    static let statusReceived: UInt8 = 0x01
    static let statusRejected: UInt8 = 0x02
    /// s || M.
    static let ackBytes = 1 + 32

    static let tagKeyInfo = Data("adf-handoff-v2 tag".utf8)
    static let tagLabel = Data("adf-handoff-v2 phone".utf8)
    static let sealInfoLabel = Data("adf-handoff-v2 seal".utf8)
    static let ackInfoLabel = Data("adf-handoff-v2 ack".utf8)
    static let aadLabel = Data("adf-handoff-v2".utf8)

    /// Kt: the MAC key for T, from the code alone.
    static func tagKey(_ code: PhonePairingCode) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: code.key, salt: Data(), info: tagKeyInfo, outputByteCount: 32)
    }

    /// T = HMAC-SHA256(Kt, "adf-handoff-v2 phone" || A || B).
    static func tag(code: PhonePairingCode, phoneKey: Data, macKey: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: tagLabel + phoneKey + macKey, using: tagKey(code)))
    }

    /// Constant-time check of T.
    static func isValidTag(_ tag: Data, code: PhonePairingCode, phoneKey: Data, macKey: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: tagLabel + phoneKey + macKey, using: tagKey(code))
    }

    /// The two keys of one session, both from X25519 and salted with C.
    struct SessionKeys {
        /// K, for the box.
        let seal: SymmetricKey
        /// Ka, for the final acknowledgement.
        let ack: SymmetricKey
    }

    /// K = HKDF-SHA256(ikm: X25519(own, peer), salt: C, info: "adf-handoff-v2 seal" || A || B) and
    /// Ka = HKDF-SHA256(ikm: X25519(own, peer), salt: C, info: "adf-handoff-v2 ack" || A || B).
    /// Throws if the key agreement fails.
    static func sessionKeys(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerKey: Data,
        code: PhonePairingCode,
        phoneKey: Data,
        macKey: Data
    ) throws -> SessionKeys {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        var salt = code.bytes
        defer { salt.zeroize() }
        return SessionKeys(
            seal: shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: sealInfoLabel + phoneKey + macKey, outputByteCount: 32),
            ack: shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: ackInfoLabel + phoneKey + macKey, outputByteCount: 32)
        )
    }

    /// K alone (see ``sessionKeys(privateKey:peerKey:code:phoneKey:macKey:)``).
    static func sessionKey(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerKey: Data,
        code: PhonePairingCode,
        phoneKey: Data,
        macKey: Data
    ) throws -> SymmetricKey {
        try sessionKeys(privateKey: privateKey, peerKey: peerKey, code: code, phoneKey: phoneKey, macKey: macKey).seal
    }

    /// s || HMAC-SHA256(Ka, s || A || B).
    static func ack(_ status: UInt8, key: SymmetricKey, phoneKey: Data, macKey: Data) -> Data {
        let message = Data([status]) + phoneKey + macKey
        return Data([status]) + Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    /// The status of an acknowledgement whose MAC verifies (constant time), else nil.
    static func verifiedStatus(ofAck ack: Data, key: SymmetricKey, phoneKey: Data, macKey: Data) -> UInt8? {
        guard ack.count == ackBytes, let status = ack.first else { return nil }
        let mac = ack.dropFirst()
        let message = Data([status]) + phoneKey + macKey
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: message, using: key) ? status : nil
    }

    /// Validates, encodes and seals; returns the `combined` box.
    static func seal(_ credential: AtlassianCredential, key: SymmetricKey, phoneKey: Data, macKey: Data) throws(PhoneHandoffError) -> Data {
        do {
            try credential.validate()
        } catch {
            throw .invalidCredential(error.message)
        }
        var plaintext: Data
        do {
            plaintext = try credential.encoded()
        } catch {
            throw .sealFailed(error.localizedDescription)
        }
        defer { plaintext.zeroize() }
        let box: Data
        do {
            box = try ChaChaPoly.seal(plaintext, using: key, authenticating: aadLabel + phoneKey + macKey).combined
        } catch {
            throw .sealFailed(error.localizedDescription)
        }
        guard box.count <= maxBoxBytes else { throw .sealFailed("the credential is larger than \(maxBoxBytes / 1024) KiB") }
        return box
    }

    /// Opens, decodes and validates; nil for any failure (wrong key or
    /// transcript, tampering, not a credential, invalid credential).
    static func open(_ box: Data, key: SymmetricKey, phoneKey: Data, macKey: Data) -> AtlassianCredential? {
        guard var plaintext = try? ChaChaPoly.open(ChaChaPoly.SealedBox(combined: box), using: key, authenticating: aadLabel + phoneKey + macKey) else {
            return nil
        }
        defer { plaintext.zeroize() }
        guard let credential = try? AtlassianCredential.decode(plaintext) else { return nil }
        do {
            try credential.validate()
        } catch {
            return nil
        }
        return credential
    }

    static func lengthPrefix(_ count: Int) -> Data {
        let value = UInt32(count).bigEndian
        return withUnsafeBytes(of: value) { Data($0) }
    }

    static func length(fromPrefix data: Data) -> Int {
        data.reduce(0) { ($0 << 8) | Int($1) }
    }
}

/// Exact-size reads and writes on one `NWConnection`, each with a timeout.
/// A timeout cancels the connection.
final class HandoffWire: Sendable {
    enum Failure: Error, Sendable, Equatable {
        case timedOut
        /// The other side closed before sending everything.
        case closed
        case failed(String)
    }

    let connection: NWConnection
    private let queue: DispatchQueue

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Opens a TCP (IPv4) connection to `host:port`.
    static func connect(host: String, port: UInt16, timeout: Duration, queue: DispatchQueue) async -> Result<HandoffWire, Failure> {
        guard let address = IPv4Address(host), let nwPort = NWEndpoint.Port(rawValue: port) else {
            return .failure(.failed("\(host):\(port) is not an IPv4 address and port."))
        }
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(host: .ipv4(address), port: nwPort, using: parameters)
        let result: Result<Void, Failure> = await withCheckedContinuation { continuation in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: .success(())) }
                case .waiting(let error), .failed(let error):
                    // `.waiting` is how a refused connection shows up.
                    if once.claim() { continuation.resume(returning: .failure(.failed(Self.describe(error)))) }
                case .cancelled:
                    if once.claim() { continuation.resume(returning: .failure(.closed)) }
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                if once.claim() { continuation.resume(returning: .failure(.timedOut)) }
            }
            connection.start(queue: queue)
        }
        switch result {
        case .success:
            connection.stateUpdateHandler = nil
            return .success(HandoffWire(connection: connection, queue: queue))
        case .failure(let failure):
            connection.stateUpdateHandler = nil
            connection.cancel()
            return .failure(failure)
        }
    }

    /// Starts an accepted (inbound) connection and waits until it is ready.
    func start(timeout: Duration) async -> Result<Void, Failure> {
        let connection = self.connection
        let result: Result<Void, Failure> = await withCheckedContinuation { continuation in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: .success(())) }
                case .waiting(let error), .failed(let error):
                    if once.claim() { continuation.resume(returning: .failure(.failed(Self.describe(error)))) }
                case .cancelled:
                    if once.claim() { continuation.resume(returning: .failure(.closed)) }
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                if once.claim() { continuation.resume(returning: .failure(.timedOut)) }
            }
            connection.start(queue: queue)
        }
        connection.stateUpdateHandler = nil
        if case .failure = result { connection.cancel() }
        return result
    }

    /// Exactly `count` bytes, or a failure.
    func receive(exactly count: Int, timeout: Duration) async -> Result<Data, Failure> {
        let connection = self.connection
        return await withCheckedContinuation { continuation in
            let once = Once()
            queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                if once.claim() {
                    continuation.resume(returning: .failure(.timedOut))
                    connection.cancel()
                }
            }
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { content, _, isComplete, error in
                guard once.claim() else { return }
                if let content, content.count == count {
                    continuation.resume(returning: .success(content))
                } else if let error {
                    continuation.resume(returning: .failure(.failed(Self.describe(error))))
                } else {
                    continuation.resume(returning: .failure(.closed))
                }
            }
        }
    }

    /// Sends `data`; succeeds once the stack has taken it.
    func send(_ data: Data, timeout: Duration) async -> Result<Void, Failure> {
        let connection = self.connection
        return await withCheckedContinuation { continuation in
            let once = Once()
            queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                if once.claim() {
                    continuation.resume(returning: .failure(.timedOut))
                    connection.cancel()
                }
            }
            connection.send(content: data, completion: .contentProcessed { error in
                guard once.claim() else { return }
                if let error {
                    continuation.resume(returning: .failure(.failed(Self.describe(error))))
                } else {
                    continuation.resume(returning: .success(()))
                }
            })
        }
    }

    func close() {
        connection.cancel()
    }

    static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code) where code == .ECONNREFUSED:
            return "connection refused (nothing is listening there)."
        case .posix(let code) where code == .EHOSTUNREACH || code == .ENETUNREACH:
            return "no route to that address."
        default:
            let text = error.localizedDescription
            return text.hasSuffix(".") ? text : text + "."
        }
    }

    /// The remote IPv4 address of a connection (dotted, no port), or nil.
    static func peerIPv4(of connection: NWConnection) -> String? {
        ipv4(of: connection.endpoint)
    }

    /// The local IPv4 address a ready connection uses (dotted), or nil.
    static func localIPv4(of connection: NWConnection) -> String? {
        connection.currentPath?.localEndpoint.flatMap(ipv4(of:))
    }

    /// The IPv4 address of a host-port endpoint (dotted, no port), or nil.
    static func ipv4(of endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        let address: IPv4Address?
        switch host {
        case .ipv4(let v4): address = v4
        case .ipv6(let v6): address = v6.asIPv4
        default: address = nil
        }
        guard let address else { return nil }
        return address.rawValue.map(String.init).joined(separator: ".")
    }
}

/// A thread-safe "first caller wins" flag.
final class Once: Sendable {
    private let done = OSAllocatedUnfairLock(initialState: false)

    /// True for the first call only.
    func claim() -> Bool {
        done.withLock { done in
            defer { done = true }
            return !done
        }
    }
}

extension Duration {
    /// Seconds as a `TimeInterval`, for Dispatch deadlines.
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
