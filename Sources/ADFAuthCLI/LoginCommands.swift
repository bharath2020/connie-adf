#if os(macOS)
import ADFAtlassianAuth
import Foundation

/// `adf-auth login` and `adf-auth rotate`.
@MainActor
enum LoginCommand {
    static let spec = CommandSpec("login", options: [
        OptionSpec("--site", value: "site"),
        OptionSpec("--email", value: "email"),
        OptionSpec("--expiry-days", value: "n"),
        OptionSpec("--token-stdin"),
        OptionSpec("--no-open"),
    ])

    struct Options {
        var site: AtlassianSite?
        var email: String?
        var expiryDays = AtlassianTokenScopes.defaultExpiryDays
        var tokenFromStdin = false
        var openBrowser = true
        /// `rotate`: the site is known to be saved already; skip the "Next" hint.
        var rotating = false
    }

    static func run(_ arguments: [String]) async throws -> Int32 {
        let parsed = try ArgumentParser.parse(arguments, for: spec)
        if parsed.helpRequested {
            Terminal.out(Help.login)
            return ExitCode.success
        }
        var options = Options()
        if let site = parsed.value("--site") { options.site = try Context.site(site, command: spec.name) }
        if let email = parsed.value("--email") { options.email = try Context.email(email, command: spec.name) }
        options.expiryDays = try ArgumentParser.integer(parsed, "--expiry-days", in: 1...365, default: AtlassianTokenScopes.defaultExpiryDays, command: spec.name)
        options.tokenFromStdin = parsed.has("--token-stdin")
        options.openBrowser = !parsed.has("--no-open")
        return try await perform(options, command: spec.name)
    }

    // MARK: Login

    static func perform(_ options: Options, command: String) async throws -> Int32 {
        // With a piped token, stdin can't also answer prompts.
        if options.tokenFromStdin, !Terminal.stdinIsTerminal, options.site == nil || options.email == nil {
            throw CLIError.usage("--token-stdin with piped input needs --site and --email.", command: command)
        }
        let site = try options.site ?? Context.askForSite(command: command)
        let email = try options.email ?? Context.askForEmail(command: command)
        let store = Context.store()
        if !options.rotating, let existing = try Context.keychain({ try store.summaries() }).first(where: { $0.site == site }) {
            Terminal.out("A token for \(site.host) (\(existing.email)) is already saved; the new one will replace it.")
        }

        printTokenPage(site: site, expiryDays: options.expiryDays, open: options.openBrowser)

        let token = try Terminal.readSecret(prompt: "Paste the API token (input hidden): ", from: options.tokenFromStdin ? .standardInput : .terminal)
        guard !token.isEmpty else {
            throw CLIError.failure("No token was entered. Nothing was saved.")
        }
        let createdAt = Date()
        var credential = AtlassianCredential(
            site: site,
            email: email,
            token: token,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(TimeInterval(options.expiryDays) * 86_400)
        )
        do {
            try credential.validate()
        } catch {
            throw CLIError.failure("\(error.message) Nothing was saved.")
        }

        if Terminal.stdinIsTerminal, Terminal.clipboardHolds(credential.token) {
            if Terminal.askYesNo("The token is still on the clipboard. Clear the clipboard?") {
                Terminal.clearClipboard()
                Terminal.out("Clipboard cleared.")
            }
        }

        Terminal.out("Checking the token with \(site.host) (GraphQL AdfAuthCheck)…")
        let check: TokenCheckResult
        do {
            let session = Context.makeSession()
            defer { session.finishTasksAndInvalidate() }
            check = try await AtlassianGraphQLClient(credential: credential, session: session).checkToken()
        } catch {
            throw CLIError.failure("\(error.message) Nothing was saved.")
        }
        Terminal.out("Token accepted for \(site.host).")

        var expiryDays = options.expiryDays
        if Terminal.stdinIsTerminal {
            expiryDays = askExpiryDays(defaultDays: options.expiryDays, createdAt: createdAt)
        }
        credential = AtlassianCredential(
            site: site,
            email: email,
            token: credential.token,
            cloudId: check.cloudId,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(TimeInterval(expiryDays) * 86_400)
        )
        do {
            try credential.validate()
        } catch {
            throw CLIError.failure("\(error.message) Nothing was saved.")
        }

        try Context.keychain { try store.save(credential) }
        let expires = credential.expiresAt.map(Format.day) ?? "never"
        Terminal.out("Saved \(site.host) (\(email)), cloudId \(check.cloudId), expires \(expires).")
        if !options.rotating {
            Terminal.out("Next: adf-auth push")
        }
        return ExitCode.success
    }

    static func printTokenPage(site: AtlassianSite, expiryDays: Int, open: Bool) {
        let url = AtlassianTokenPage.createURL(expiryDays: expiryDays)
        Terminal.out("Create an API token for \(site.host) at:")
        Terminal.out("  \(url.absoluteString)")
        if open {
            Terminal.out(Terminal.open(url) ? "  (opened in your browser)" : "  (couldn't open the browser; open the link yourself)")
        }
        Terminal.out("Atlassian may not preselect everything, so check each step:")
        for (index, step) in AtlassianTokenPage.manualSteps(expiryDays: expiryDays).enumerated() {
            Terminal.out("  \(index + 1). \(step)")
        }
        Terminal.out("Scopes (exactly these \(AtlassianTokenScopes.required.count)):")
        for scope in AtlassianTokenScopes.required {
            Terminal.out("  - \(scope)")
        }
        Terminal.out()
    }

    /// "Press Enter to accept or type the number of days you chose".
    static func askExpiryDays(defaultDays: Int, createdAt: Date) -> Int {
        let expiry = Format.day(createdAt.addingTimeInterval(TimeInterval(defaultDays) * 86_400))
        while true {
            guard let line = Terminal.prompt("Token expiry: \(expiry) (\(defaultDays) days). Press Enter to accept or type the number of days you chose: ") else {
                return defaultDays
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return defaultDays }
            if let days = Int(trimmed), (1...365).contains(days) { return days }
            Terminal.err("Enter a number of days from 1 to 365, or press Enter.")
        }
    }
}

/// `adf-auth rotate <site>`.
@MainActor
enum RotateCommand {
    static let spec = CommandSpec("rotate", options: [
        OptionSpec("--expiry-days", value: "n"),
        OptionSpec("--token-stdin"),
        OptionSpec("--no-open"),
    ], positionals: ["site"])

    static func run(_ arguments: [String]) async throws -> Int32 {
        let parsed = try ArgumentParser.parse(arguments, for: spec)
        if parsed.helpRequested {
            Terminal.out(Help.rotate)
            return ExitCode.success
        }
        let site = try Context.site(parsed.positionals[0], command: spec.name)
        var options = LoginCommand.Options()
        options.site = site
        options.expiryDays = try ArgumentParser.integer(parsed, "--expiry-days", in: 1...365, default: AtlassianTokenScopes.defaultExpiryDays, command: spec.name)
        options.tokenFromStdin = parsed.has("--token-stdin")
        options.openBrowser = !parsed.has("--no-open")
        options.rotating = true

        let store = Context.store()
        let summary = try Context.savedSite(explicit: site, store: store, command: spec.name)
        options.email = summary.email
        Terminal.out("Rotating the token for \(site.host) (\(summary.email)). The old token keeps working until you revoke it.")
        Terminal.out()

        _ = try await LoginCommand.perform(options, command: spec.name)
        Terminal.out()

        let toPhone = "adf-auth push --to <ipv4:port> --site \(site.host)"
        var pushed = false
        var status = ExitCode.success
        Terminal.out("Sending now shows a QR code for Scan from Mac (this Mac listens). If this Mac blocks incoming connections (for example a company-managed Mac), answer n and run '\(toPhone)' afterwards (ADFReader → Mac connects to phone); the new token is already saved.")
        if Terminal.askYesNo("Send the new token to your phone now?") {
            var push = PushCommand.Options()
            push.site = site
            do {
                status = try await PushCommand.perform(push)
                pushed = status == ExitCode.success
            } catch let error as CLIError {
                status = CLI.report(error)
            }
        }
        if !pushed {
            Terminal.out("Not sent. The new token is already saved: run 'adf-auth push --site \(site.host)' when your phone is ready, or '\(toPhone)' if this Mac blocks incoming connections.")
        }

        Terminal.out()
        if pushed {
            Terminal.out("Revoke the old ADFReader token there: \(AtlassianTokenPage.manageURL.absoluteString)")
            if options.openBrowser, Terminal.open(AtlassianTokenPage.manageURL) {
                Terminal.out("  (opened in your browser)")
            }
        } else {
            // Revoking now would sign the phone out; say when instead.
            Terminal.out("Once your phone has the new token, revoke the old ADFReader token at:")
            Terminal.out("  \(AtlassianTokenPage.manageURL.absoluteString)")
        }
        return status
    }
}
#endif
