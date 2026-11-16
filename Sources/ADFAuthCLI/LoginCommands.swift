#if os(macOS)
import ADFAtlassianAuth
import Foundation
import Security

/// `adf-auth login` and `adf-auth rotate`.
@MainActor
enum LoginCommand {
    static let spec = CommandSpec("login", options: [
        OptionSpec("--site", value: "site"),
        OptionSpec("--email", value: "email"),
        OptionSpec("--expiry-days", value: "n"),
        OptionSpec("--token-stdin"),
        OptionSpec("--no-open"),
        OptionSpec("--dry-run"),
        OptionSpec("--gateway", value: "url"),
    ])

    struct Options {
        var site: AtlassianSite?
        var email: String?
        var expiryDays = AtlassianTokenScopes.defaultExpiryDays
        var tokenFromStdin = false
        var openBrowser = true
        var gateway: URL?
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
        options.gateway = try Context.gateway(parsed, command: spec.name)
        if parsed.has("--dry-run") {
            return try dryRun(options)
        }
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
        let store = try Context.store()
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
            check = try await AtlassianGraphQLClient(credential: credential, endpoint: options.gateway, session: session).checkToken()
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

    // MARK: Dry run

    static func dryRun(_ options: Options) throws -> Int32 {
        let site: AtlassianSite
        if let given = options.site {
            site = given
        } else if Terminal.stdinIsTerminal, !options.tokenFromStdin {
            site = try Context.askForSite(command: spec.name)
        } else {
            throw CLIError.usage("--dry-run needs --site when stdin is not a terminal.", command: spec.name)
        }
        let service = try Context.keychainService()
        let endpoint = options.gateway ?? site.graphQLEndpoint
        let createURL = AtlassianTokenPage.createURL(expiryDays: options.expiryDays)
        let expiry = Date().addingTimeInterval(TimeInterval(options.expiryDays) * 86_400)

        Terminal.out("Dry run: no network, no browser, no token read, nothing saved.")
        Terminal.out()
        for line in Format.table([
            ["Site:", site.host],
            ["Email:", options.email ?? "(asked when you run it)"],
            ["GraphQL endpoint:", endpoint.absoluteString + (options.gateway == nil ? "" : "  (--gateway override)")],
            ["Token page:", createURL.absoluteString],
            ["Browser:", options.openBrowser ? "would open the token page" : "not opened (--no-open)"],
            ["Token:", "not read in a dry run; a real run reads it " + (options.tokenFromStdin ? "as one line of stdin (--token-stdin)" : "with echo off from the terminal (readpassphrase)")],
            ["Expiry:", "\(Format.day(expiry)) (\(options.expiryDays) days)"],
        ]) {
            Terminal.out(line)
        }
        Terminal.out()
        Terminal.out("Manual steps on the token page:")
        for (index, step) in AtlassianTokenPage.manualSteps(expiryDays: options.expiryDays).enumerated() {
            Terminal.out("  \(index + 1). \(step)")
        }
        Terminal.out("Scopes: \(AtlassianTokenScopes.required.joined(separator: ", "))")
        Terminal.out()
        Terminal.out("Token check it would send (\(GraphQLDocuments.authCheckOperationName)):")
        Terminal.out(Format.indent(AtlassianGraphQLClient.requestPreview(GraphQLOperation.authCheck(site: site), endpoint: endpoint)))
        Terminal.out()
        Terminal.out("Keychain item it would write (login keychain):")
        for line in Format.table(keychainRows(site: site, service: service.name, overridden: service.overridden)) {
            Terminal.out("  " + line)
        }
        return ExitCode.success
    }

    /// The would-be keychain attributes, read from the store's own attribute
    /// dictionary so the dry run can't drift from what `save` writes.
    static func keychainRows(site: AtlassianSite, service: String, overridden: Bool) -> [[String]] {
        let attributes = KeychainCredentialStore.baseAttributes(site: site, service: service)
        func string(_ key: CFString) -> String { (attributes[key as String] as? String) ?? "?" }
        let itemClass = string(kSecClass) == (kSecClassGenericPassword as String) ? "generic password" : string(kSecClass)
        let accessible = string(kSecAttrAccessible) == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            ? "kSecAttrAccessibleWhenUnlockedThisDeviceOnly" : string(kSecAttrAccessible)
        let synchronizable = (attributes[kSecAttrSynchronizable as String] as? Bool) == false
            ? "false (never synced to iCloud Keychain)" : "\(attributes[kSecAttrSynchronizable as String] ?? "?")"
        return [
            ["class:", itemClass],
            ["service:", string(kSecAttrService) + (overridden ? "  (from \(Context.keychainServiceVariable))" : "")],
            ["account:", string(kSecAttrAccount)],
            ["label:", string(kSecAttrLabel)],
            ["accessible:", accessible],
            ["synchronizable:", synchronizable],
            ["access group:", "none"],
            ["generic:", "summary JSON (site, email, cloudId, scopes, createdAt, expiresAt), no token"],
            ["data:", "credential JSON, including the token"],
        ]
    }
}

/// `adf-auth rotate <site>`.
@MainActor
enum RotateCommand {
    static let spec = CommandSpec("rotate", options: [
        OptionSpec("--expiry-days", value: "n"),
        OptionSpec("--token-stdin"),
        OptionSpec("--no-open"),
        OptionSpec("--gateway", value: "url"),
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
        options.gateway = try Context.gateway(parsed, command: spec.name)
        options.rotating = true

        let store = try Context.store()
        let summary = try Context.savedSite(explicit: site, store: store, command: spec.name)
        options.email = summary.email
        Terminal.out("Rotating the token for \(site.host) (\(summary.email)). The old token keeps working until you revoke it.")
        Terminal.out()

        _ = try await LoginCommand.perform(options, command: spec.name)
        Terminal.out()

        var pushed = false
        var status = ExitCode.success
        if Terminal.askYesNo("Send the new token to your phone now?") {
            var push = PushCommand.Options()
            push.site = site
            do {
                status = try await PushCommand.perform(push)
                pushed = status == ExitCode.success
            } catch let error as CLIError {
                status = CLI.report(error)
            }
        } else {
            Terminal.out("Not sent. Run 'adf-auth push --site \(site.host)' when your phone is ready.")
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
