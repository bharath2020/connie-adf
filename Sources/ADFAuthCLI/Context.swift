#if os(macOS)
import ADFAtlassianAuth
import Darwin
import Foundation

/// Shared plumbing for the commands: the keychain store, site and email
/// input, the testing-only gateway override, and keychain error mapping.
@MainActor
enum Context {
    /// Testing only: the keychain service to use instead of the default.
    static let keychainServiceVariable = "ADF_AUTH_KEYCHAIN_SERVICE"

    /// The keychain service name and whether it came from the environment.
    static func keychainService() throws(CLIError) -> (name: String, overridden: Bool) {
        guard let raw = ProcessInfo.processInfo.environment[keychainServiceVariable] else {
            return (KeychainCredentialStore.defaultService, false)
        }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw .usage("\(keychainServiceVariable) is set but empty.", command: nil)
        }
        return (name, true)
    }

    private static var notedServiceOverride = false

    /// The login-keychain store (service overridable for tests, noted once).
    static func store() throws(CLIError) -> KeychainCredentialStore {
        let service = try keychainService()
        if service.overridden, !notedServiceOverride {
            notedServiceOverride = true
            Terminal.err("note: using keychain service \(service.name) (from \(keychainServiceVariable))")
        }
        return KeychainCredentialStore(service: service.name)
    }

    /// Runs a keychain call and turns its error into a message.
    static func keychain<T>(_ body: () throws -> T) throws(CLIError) -> T {
        do {
            return try body()
        } catch let error as KeychainError {
            throw .failure(error.message)
        } catch {
            throw .failure("Keychain error: \(error.localizedDescription)")
        }
    }

    // MARK: Site and email

    static func site(_ input: String, command: String) throws(CLIError) -> AtlassianSite {
        do {
            return try AtlassianSite(parsing: input)
        } catch {
            throw .usage(siteMessage(error), command: command)
        }
    }

    /// Why a site was rejected, without repeating the input (it might be a
    /// pasted token).
    static func siteMessage(_ error: AtlassianSite.ParseError) -> String {
        switch error {
        case .empty:
            return "Enter your Atlassian site, for example acme or acme.atlassian.net."
        case .unsupportedHost:
            return "That isn't an atlassian.net site. Only <name>.atlassian.net sites are supported for now."
        case .invalidName:
            return "That isn't a valid atlassian.net site name. Use letters, digits and hyphens, for example acme or acme.atlassian.net."
        }
    }

    /// Refuses to prompt when stdin is not a terminal: piped input (say, a
    /// token from `pbpaste`) must never be read as an answer and echoed.
    static func requireTerminal(for missing: String, command: String) throws(CLIError) {
        guard Terminal.stdinIsTerminal else {
            throw .usage("stdin is not a terminal, so adf-auth won't prompt for \(missing). Pass it as an option (and use --token-stdin if you are piping the token).", command: command)
        }
    }

    /// Prompts on the terminal until the site parses.
    static func askForSite(command: String) throws(CLIError) -> AtlassianSite {
        try requireTerminal(for: "the site (--site <site>)", command: command)
        while true {
            guard let line = Terminal.prompt("Atlassian site (e.g. acme or acme.atlassian.net): ") else {
                throw .usage("no site given. Pass --site <site>.", command: command)
            }
            do {
                return try AtlassianSite(parsing: line)
            } catch {
                Terminal.err(siteMessage(error))
            }
        }
    }

    static func isPlausibleEmail(_ email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
            && !email.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }
    }

    static func email(_ input: String, command: String) throws(CLIError) -> String {
        let email = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPlausibleEmail(email) else {
            throw .usage("That isn't an email address.", command: command)
        }
        return email
    }

    /// Prompts on the terminal until the email looks valid.
    static func askForEmail(command: String) throws(CLIError) -> String {
        try requireTerminal(for: "the email (--email <email>)", command: command)
        while true {
            guard let line = Terminal.prompt("Atlassian account email: ") else {
                throw .usage("no email given. Pass --email <email>.", command: command)
            }
            let email = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if isPlausibleEmail(email) { return email }
            Terminal.err("That isn't an email address. Enter the email of your Atlassian account.")
        }
    }

    /// `--site`, or the only saved account, or a choice when several are saved.
    /// Reads summaries only (never a token).
    static func savedSite(explicit: AtlassianSite?, store: KeychainCredentialStore, command: String) throws(CLIError) -> AtlassianAccountSummary {
        let summaries = try keychain { try store.summaries() }
        if let explicit {
            guard let summary = summaries.first(where: { $0.site == explicit }) else {
                throw .failure("No saved account for \(explicit.host). Run: adf-auth login --site \(explicit.host)")
            }
            return summary
        }
        switch summaries.count {
        case 0:
            throw .failure("No accounts. Run: adf-auth login")
        case 1:
            return summaries[0]
        default:
            guard Terminal.stdinIsTerminal else {
                throw .usage("several accounts are saved; pass --site <site> (\(summaries.map(\.site.host).joined(separator: ", "))).", command: command)
            }
            for (index, summary) in summaries.enumerated() {
                Terminal.err("  \(index + 1). \(summary.site.host) (\(summary.email))")
            }
            while true {
                guard let line = Terminal.prompt("Which account? [1-\(summaries.count)] ") else {
                    throw .usage("no account chosen. Pass --site <site>.", command: command)
                }
                if let choice = Int(line.trimmingCharacters(in: .whitespaces)), (1...summaries.count).contains(choice) {
                    return summaries[choice - 1]
                }
                Terminal.err("Enter a number from 1 to \(summaries.count).")
            }
        }
    }

    // MARK: Testing override

    /// Hosts `--gateway` may point at.
    static let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "localhost"]

    /// `--gateway <url>`: GraphQL endpoint override for local stub servers.
    /// Loopback only (127.0.0.1, ::1, localhost; http or https), so the
    /// saved token can never be sent to another machine. Warns when used.
    static func gateway(_ parsed: ParsedArguments, command: String) throws(CLIError) -> URL? {
        guard let raw = parsed.value("--gateway") else { return nil }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              url.user == nil, url.password == nil else {
            throw .usage("--gateway needs an http(s) URL on 127.0.0.1, ::1 or localhost.", command: command)
        }
        guard loopbackHosts.contains(host) else {
            throw .usage("--gateway only accepts 127.0.0.1, ::1 or localhost (it is for local stub servers; the token must never go anywhere else).", command: command)
        }
        Terminal.err("warning: --gateway is for stub servers only: sending GraphQL to \(url.absoluteString) instead of the site's gateway.")
        return url
    }

    /// A fresh ephemeral session for one command: no shared cookies, cache
    /// or credential storage.
    static func makeSession() -> URLSession {
        URLSession(configuration: .ephemeral)
    }
}

/// Date and table formatting.
enum Format {
    /// `yyyy-MM-dd` in the local time zone.
    static func day(_ date: Date) -> String {
        formatter("yyyy-MM-dd").string(from: date)
    }

    /// `HH:mm:ss` in the local time zone.
    static func time(_ date: Date) -> String {
        formatter("HH:mm:ss").string(from: date)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter
    }

    static func expiry(_ summary: AtlassianAccountSummary, now: Date = Date()) -> String {
        switch summary.expiryStatus(now: now) {
        case .noExpiry:
            return "unknown"
        case .valid(let days):
            return "\(day(summary.expiresAt ?? now)) (in \(days) days)"
        case .expiringSoon(let days):
            return "\(day(summary.expiresAt ?? now)) (in \(days) day\(days == 1 ? "" : "s"), rotate soon)"
        case .expired:
            return "\(day(summary.expiresAt ?? now)) (EXPIRED)"
        }
    }

    /// Left-aligned columns separated by two spaces.
    static func table(_ rows: [[String]]) -> [String] {
        guard let columns = rows.map(\.count).max() else { return [] }
        var widths = [Int](repeating: 0, count: columns)
        for row in rows {
            for (index, cell) in row.enumerated() { widths[index] = max(widths[index], cell.count) }
        }
        return rows.map { row in
            row.enumerated().map { index, cell in
                index == row.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
    }

    static func indent(_ text: String, by spaces: Int = 2) -> String {
        let pad = String(repeating: " ", count: spaces)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "" : pad + $0 }.joined(separator: "\n")
    }
}
#endif
