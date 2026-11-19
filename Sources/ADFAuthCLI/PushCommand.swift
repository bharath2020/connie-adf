#if os(macOS)
import ADFAtlassianAuth
import Foundation

/// `adf-auth push`: one-time handoff of a saved account to the phone, either
/// as a QR code the phone scans (the Mac listens) or, with `--to`, by
/// connecting out to the phone (the phone listens).
@MainActor
enum PushCommand {
    static let spec = CommandSpec("push", options: [
        OptionSpec("--site", value: "site"),
        OptionSpec("--host", value: "ipv4"),
        OptionSpec("--port", value: "n"),
        OptionSpec("--timeout", value: "seconds"),
        OptionSpec("--to", value: "ipv4:port"),
        OptionSpec("--code", value: "code"),
    ])

    static let defaultTimeout = 120
    /// The phone waits ``HandoffClient/defaultTimeout`` (130 s) for an answer;
    /// the code must expire before that, so a phone never gives up first.
    static let maxTimeout = min(defaultTimeout, Int(HandoffClient.defaultTimeout) - 10)

    struct Options {
        var site: AtlassianSite?
        var host: String?
        var port: UInt16 = 0
        var timeout = 120
    }

    static func run(_ arguments: [String]) async throws -> Int32 {
        let parsed = try ArgumentParser.parse(arguments, for: spec)
        if parsed.helpRequested {
            Terminal.out(Help.push)
            return ExitCode.success
        }
        if parsed.value("--to") != nil {
            return try await ToPhone.run(parsed)
        }
        if parsed.value("--code") != nil {
            throw CLIError.usage("--code only goes with --to <ipv4:port> (the address the phone shows).", command: spec.name)
        }
        var options = Options()
        if let site = parsed.value("--site") { options.site = try Context.site(site, command: spec.name) }
        if let host = parsed.value("--host") {
            guard PairingLink.isValidHost(host), !host.contains(":") else {
                throw CLIError.usage("--host must be an IPv4 address such as 192.168.1.20 (no port; use --port).", command: spec.name)
            }
            options.host = host
        }
        options.port = UInt16(try ArgumentParser.integer(parsed, "--port", in: 0...65_535, default: 0, command: spec.name))
        options.timeout = try ArgumentParser.integer(parsed, "--timeout", in: 5...maxTimeout, default: defaultTimeout, command: spec.name)
        return try await perform(options)
    }

    static let noAddressMessage = "No Wi-Fi/LAN IPv4 address; connect to the same network as the phone, or add the account on the phone with Add Manually"

    /// ADFReader only fetches from private-range hosts.
    static let notLocalNetworkWarning = "warning: the phone only accepts private-network addresses (10/8, 172.16/12, 192.168/16, 100.64/10), so the phone won't fetch from this address"

    // MARK: Push

    static func perform(_ options: Options) async throws -> Int32 {
        // The QR holds the one-time key: draw it only on a terminal, never
        // into a file or pipe (`push | tee log` would keep a usable code).
        guard isatty(STDOUT_FILENO) == 1 else {
            throw CLIError.usage("stdout is not a terminal, so push won't draw the QR code: it holds the one-time key and would end up in a file or pipe. Run push in a terminal.", command: spec.name)
        }
        let store = Context.store()
        let summary = try Context.savedSite(explicit: options.site, store: store, command: spec.name)
        let site = summary.site
        guard let host = options.host ?? LANAddress.primaryIPv4() else {
            throw CLIError.failure(noAddressMessage)
        }
        guard PairingLink.isValidHost(host) else {
            throw CLIError.failure("\(host) is not a usable IPv4 address. Pass --host <ipv4>.")
        }
        if !PairingLink.isLocalNetworkHost(host) {
            Terminal.err(notLocalNetworkWarning)
        }

        // The only secret read.
        let credential = try loadCredential(site, store: store)

        // The session ID and key are fixed now; the port is known after start().
        let draft = PairingLink.generate(host: host)
        let sealed: Data
        do {
            sealed = try HandoffSeal.seal(credential, link: draft)
        } catch {
            throw CLIError.failure(error.message)
        }

        let promptLine = PromptLine()
        let server = HandoffServer(
            sealed: sealed,
            sessionId: draft.sessionId,
            bindHost: host,
            port: options.port,
            timeout: .seconds(options.timeout),
            confirm: makeConfirm(site: site.host, promptLine: promptLine),
            onEvent: makeEventHandler(promptLine: promptLine)
        )
        let port: UInt16
        do {
            port = try await server.start()
        } catch {
            throw CLIError.failure(error.message)
        }
        let link: PairingLink
        do {
            link = try PairingLink(host: "\(host):\(port)", sessionId: draft.sessionId, key: draft.key)
        } catch {
            server.cancel()
            throw CLIError.failure(error.message)
        }
        let deadline = Date().addingTimeInterval(TimeInterval(options.timeout))

        Terminal.out("Account:   \(site.host) (\(summary.email))")
        promptLine.setDeadline(deadline)
        Terminal.out("Listening: \(host):\(port) until \(Format.time(deadline))")
        Terminal.out()
        guard let qr = QRTerminalRenderer.lines(for: link.url.absoluteString) else {
            server.cancel()
            throw CLIError.failure("Couldn't draw the QR code.")
        }
        qr.forEach { Terminal.out($0) }
        Terminal.out()
        Terminal.out("Scan with ADFReader → Settings → Atlassian Accounts → Scan from Mac. Expires in \(options.timeout) s. The code contains a one-time key, not your token.")
        Terminal.out("Waiting for the phone… (Ctrl-C to cancel)")

        let outcome = await server.waitForCompletion()
        promptLine.close()
        switch outcome {
        case .served(let peer, let date):
            Terminal.out("Sent to \(peer) at \(Format.time(date)). The code is now spent.")
            return ExitCode.success
        case .timedOut:
            Terminal.out("Expired after \(options.timeout) s; nothing was sent.")
            return ExitCode.failure
        case .declined(let peer):
            Terminal.out("Expired after \(options.timeout) s; nothing was sent (you declined \(peer)).")
            return ExitCode.failure
        case .cancelled:
            Terminal.out("Cancelled; nothing was sent.")
            return ExitCode.failure
        case .failed(let detail):
            throw CLIError.failure("The handoff listener stopped: \(detail). Nothing was sent.")
        }
    }

    /// Built outside the main actor: the server calls these on its own queue.
    ///
    /// The server cancels the confirmation task when the phone disconnects
    /// (or time runs out) while the question is open; the stdin wait then
    /// returns `.cancelled` and the answer, if any, is ignored.
    nonisolated static func makeConfirm(site: String, promptLine: PromptLine) -> @Sendable (String) async -> Bool {
        { peer in
            // Sending needs an explicit y/yes; Enter, end of input or anything else is no.
            switch await promptLine.ask("Phone \(peer) is asking for \(site) — send? [y/N] ") {
            case .cancelled:
                promptLine.phoneLeft(peer)
                return false
            case .line(let answer) where Terminal.isYes(answer, defaultYes: false):
                return true
            case .line, .endOfInput:
                Terminal.err("Not sent to \(peer). Still waiting for a scan.")
                return false
            }
        }
    }

    // MARK: --to (the phone listens)

    /// `push --to <ipv4:port> [--code <code>]`: connect out to ADFReader's
    /// "Mac connects to phone" screen. For Macs that block incoming connections.
    @MainActor
    enum ToPhone {
        static let defaultTimeout = Int(PhoneHandoffSender.defaultTimeout.components.seconds)
        static let maxTimeout = 300

        static func run(_ parsed: ParsedArguments) async throws -> Int32 {
            let command = spec.name
            if parsed.value("--host") != nil || parsed.value("--port") != nil {
                throw CLIError.usage("--to replaces --host and --port: give the phone's address as --to <ipv4:port>.", command: command)
            }
            let address: PhoneHandoffAddress
            do {
                address = try PhoneHandoffAddress(parsing: parsed.value("--to") ?? "")
            } catch {
                throw CLIError.usage("--to: \(error.message)", command: command)
            }
            var code: PhonePairingCode?
            if let text = parsed.value("--code") {
                do {
                    code = try PhonePairingCode(parsing: text)
                } catch {
                    throw CLIError.usage("--code: \(error.message)", command: command)
                }
            } else if !Terminal.stdinIsTerminal {
                throw CLIError.usage("stdin is not a terminal, so adf-auth won't prompt for the code shown on your phone. Pass --code <code>.", command: command)
            }
            let site = try parsed.value("--site").map { try Context.site($0, command: command) }
            let timeout = try ArgumentParser.integer(parsed, "--timeout", in: 5...maxTimeout, default: defaultTimeout, command: command)

            let store = Context.store()
            let summary = try Context.savedSite(explicit: site, store: store, command: command)
            let credential = try loadCredential(summary.site, store: store)

            Terminal.out("Account:   \(summary.site.host) (\(summary.email))")
            Terminal.out("Phone:     \(address)")
            let pairingCode = try code ?? askForCode(command: command)
            Terminal.out("Connecting to the phone…")
            do {
                try await PhoneHandoffSender.send(credential, to: address, code: pairingCode, timeout: .seconds(timeout))
            } catch {
                throw CLIError.failure(error.message)
            }
            Terminal.out("Sent \(summary.site.host) (\(summary.email)). Confirm on your phone: tap Add.")
            return ExitCode.success
        }

        /// Prompts until the code parses. The code is echoed (it is shown on
        /// the phone anyway) but stays out of the shell history.
        static func askForCode(command: String) throws(CLIError) -> PhonePairingCode {
            while true {
                guard let line = Terminal.prompt("Code shown on your phone: ") else {
                    throw .usage("no code given. Pass --code <code>.", command: command)
                }
                do {
                    return try PhonePairingCode(parsing: line)
                } catch {
                    Terminal.err(error.message)
                }
            }
        }
    }

    /// Reads and validates the saved credential (the only secret read).
    static func loadCredential(_ site: AtlassianSite, store: KeychainCredentialStore) throws(CLIError) -> AtlassianCredential {
        // May show a macOS keychain prompt after a rebuild.
        guard let credential = try Context.keychain({ try store.load(site: site) }) else {
            throw .failure("No saved account for \(site.host). Run: adf-auth login --site \(site.host)")
        }
        do {
            try credential.validate()
        } catch {
            throw .failure("The saved account for \(site.host) is unusable: \(error.message) Run: adf-auth login --site \(site.host)")
        }
        return credential
    }

    nonisolated static func makeEventHandler(promptLine: PromptLine) -> @Sendable (HandoffServer.Event) -> Void {
        { event in
            guard case .rejected(let peer, let path) = event else { return }
            if path == HandoffServer.redactedPath {
                promptLine.warn("warning: ignored another request from \(peer) while waiting for your answer")
            } else {
                promptLine.warn("warning: ignored request from \(peer) for an unknown path")
            }
        }
    }
}
#endif
