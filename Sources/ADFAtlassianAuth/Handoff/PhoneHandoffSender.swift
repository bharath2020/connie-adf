import CryptoKit
import Foundation

/// Mac side of the "Mac connects to phone" handoff (`adf-auth push --to`):
/// connects out to ``PhoneHandoffListener`` on the phone, checks that the
/// phone knows the typed code, then sends one sealed credential.
public enum PhoneHandoffSender {
    /// Default limit for the whole connect-and-send.
    public static let defaultTimeout: Duration = .seconds(30)
    /// Default limit for each step (connect, each read and write).
    public static let defaultStepTimeout: Duration = .seconds(15)

    /// Runs the handshake and sends `credential`.
    ///
    /// Nothing that depends on the code is sent before the phone's tag T
    /// verifies; on a mismatch the connection is closed and
    /// ``PhoneHandoffError/wrongCode`` is thrown. Returns once the phone
    /// reports, with an acknowledgement authenticated by the session key,
    /// that it opened and validated the credential (it then asks the person
    /// to confirm before saving). A missing or forged acknowledgement throws
    /// ``PhoneHandoffError/unconfirmed``; a phone handling too many
    /// connections answers ``PhoneHandoffError/phoneBusy``.
    ///
    /// - Parameters:
    ///   - address: The phone's address. Parsing (``PhoneHandoffAddress/init(parsing:)``)
    ///     only accepts private local-network IPv4 addresses.
    ///   - code: The code shown on the phone.
    ///   - timeout: Limit for the whole exchange (default 30 s).
    ///   - stepTimeout: Limit for each step (default 15 s).
    public static func send(
        _ credential: AtlassianCredential,
        to address: PhoneHandoffAddress,
        code: PhonePairingCode,
        timeout: Duration = defaultTimeout,
        stepTimeout: Duration = defaultStepTimeout
    ) async throws(PhoneHandoffError) {
        typealias H = PhoneHandoffHandshake
        do {
            try credential.validate()
        } catch {
            throw .invalidCredential(error.message)
        }
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        func stepLimit() -> Duration {
            max(.zero, min(stepTimeout, deadline - clock.now))
        }

        let queue = DispatchQueue(label: "com.connie.adfreader.phone-handoff-sender")
        let wire: HandoffWire
        switch await HandoffWire.connect(host: address.host, port: address.port, timeout: stepLimit(), queue: queue) {
        case .success(let connected):
            wire = connected
        case .failure(.timedOut):
            throw .connectionFailed("no answer within the time limit.")
        case .failure(.closed):
            throw .connectionFailed("the connection was closed.")
        case .failure(.failed(let detail)):
            throw .connectionFailed(detail)
        }
        defer { wire.close() }

        // 1. "ADFH2" || B
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let macKey = privateKey.publicKey.rawRepresentation
        if case .failure = await wire.send(H.magic + macKey, timeout: stepLimit()) {
            throw .noAnswer
        }

        // 2. 0x00 || A || T, or 0x03 (busy).
        switch await wire.receive(exactly: 1, timeout: stepLimit()) {
        case .success(let data) where data.first == H.replyProceed: break
        case .success(let data) where data.first == H.replyBusy: throw .phoneBusy
        case .success: throw .protocolMismatch
        case .failure(.closed): throw .protocolMismatch
        case .failure: throw .noAnswer
        }
        let reply: Data
        switch await wire.receive(exactly: H.publicKeyBytes + H.tagBytes, timeout: stepLimit()) {
        case .success(let data): reply = data
        case .failure(.closed): throw .protocolMismatch
        case .failure: throw .noAnswer
        }
        let phoneKey = Data(reply.prefix(H.publicKeyBytes))
        let tag = Data(reply.suffix(H.tagBytes))

        // 3. Verify T before sending anything that depends on the code.
        guard H.isValidTag(tag, code: code, phoneKey: phoneKey, macKey: macKey) else {
            wire.close()
            throw .wrongCode
        }

        // 4. len32 || box
        let keys: H.SessionKeys
        do {
            keys = try H.sessionKeys(privateKey: privateKey, peerKey: phoneKey, code: code, phoneKey: phoneKey, macKey: macKey)
        } catch {
            throw .protocolMismatch
        }
        let box = try H.seal(credential, key: keys.seal, phoneKey: phoneKey, macKey: macKey)
        if case .failure = await wire.send(H.lengthPrefix(box.count) + box, timeout: stepLimit()) {
            // Part or all of the box may have arrived.
            throw .unconfirmed
        }

        // 5. s || M, authenticated with Ka. Anything else (no answer, a
        // forged or truncated acknowledgement) leaves delivery unconfirmed.
        guard case .success(let ack) = await wire.receive(exactly: H.ackBytes, timeout: stepLimit()),
              let status = H.verifiedStatus(ofAck: ack, key: keys.ack, phoneKey: phoneKey, macKey: macKey)
        else { throw .unconfirmed }
        switch status {
        case H.statusReceived: return
        case H.statusRejected: throw .rejectedByPhone
        default: throw .unconfirmed
        }
    }
}
