#if os(macOS)
import ADFAtlassianAuth
import Foundation

/// `adf-auth list`.
@MainActor
enum ListCommand {
    static let spec = CommandSpec("list")

    static func run(_ arguments: [String]) throws -> Int32 {
        let parsed = try ArgumentParser.parse(arguments, for: spec)
        if parsed.helpRequested {
            Terminal.out(Help.list)
            return ExitCode.success
        }
        let store = try Context.store()
        let summaries = try Context.keychain { try store.summaries() }
        guard !summaries.isEmpty else {
            Terminal.out("No accounts. Run: adf-auth login")
            return ExitCode.success
        }
        let now = Date()
        var rows = [["SITE", "EMAIL", "TOKEN EXPIRES"]]
        rows += summaries.map { [$0.site.host, $0.email, Format.expiry($0, now: now)] }
        Format.table(rows).forEach { Terminal.out($0) }
        let attention = summaries.filter { $0.expiryStatus(now: now).needsAttention }
        for summary in attention {
            Terminal.out()
            Terminal.out("Replace the token for \(summary.site.host): adf-auth rotate \(summary.site.host)")
        }
        return ExitCode.success
    }
}

/// `adf-auth remove <site>`.
@MainActor
enum RemoveCommand {
    static let spec = CommandSpec("remove", options: [OptionSpec("--no-open")], positionals: ["site"])

    static func run(_ arguments: [String]) throws -> Int32 {
        let parsed = try ArgumentParser.parse(arguments, for: spec)
        if parsed.helpRequested {
            Terminal.out(Help.remove)
            return ExitCode.success
        }
        let site = try Context.site(parsed.positionals[0], command: spec.name)
        let store = try Context.store()
        let removed = try Context.keychain { try store.remove(site: site) }
        let manage = AtlassianTokenPage.manageURL
        if removed {
            Terminal.out("Removed \(site.host) from the keychain.")
            Terminal.out("Also revoke its token at Atlassian so it stops working: \(manage.absoluteString)")
            if !parsed.has("--no-open"), Terminal.open(manage) {
                Terminal.out("  (opened in your browser)")
            }
            Terminal.out("ADFReader on your phone keeps its own copy: remove it there in Settings → Atlassian Accounts.")
            return ExitCode.success
        }
        Terminal.err("error: no saved account for \(site.host); nothing was removed.")
        Terminal.out("If a token for it still exists, revoke it at: \(manage.absoluteString)")
        return ExitCode.failure
    }
}
#endif
