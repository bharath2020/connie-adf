#if os(macOS)
import ADFAtlassianAuth
import Foundation

/// Help text for `adf-auth help [command]` and `<command> --help`.
enum Help {
    static let version = "adf-auth 1.0.0 (pairing link v\(PairingLink.version))"

    private static var scopes: String { AtlassianTokenScopes.required.joined(separator: ", ") }

    static let main = """
        adf-auth — sign in to Atlassian for ADFReader and hand the sign-in to your phone

        Usage: adf-auth <command> [options]

        Commands:
          login            Create a read-only Confluence API token, check it, save it in the keychain
          list             List saved accounts and when their tokens expire
          push             Show a one-time QR code that sends a saved account to ADFReader
          rotate <site>    Replace a site's token, send it to the phone, revoke the old one
          remove <site>    Delete a saved account from the keychain
          probe-graphql    Look up page titles over GraphQL with a saved account
          help [command]   Show help for a command

        Options:
          -h, --help       Show help (also after any command)
          --version        Show the version

        The token is read with echo off (or as one line of stdin with --token-stdin).
        It is never printed, logged, taken as an argument, or written anywhere except
        your login keychain ("ADFReader – <site>" items). The QR code holds a one-time
        key for a sealed copy, not the token.

        Install:
          swift build -c release --product adf-auth
          codesign -s "<identity>" .build/release/adf-auth     (optional)
          An unsigned binary gets a new identity on every rebuild, so macOS asks again
          before it reads a saved token. Signing with a stable identity stops that.

        Testing (stub servers only):
          ADF_AUTH_KEYCHAIN_SERVICE=<name>  Use this keychain service instead of
                                            \(KeychainCredentialStore.defaultService)
          --gateway <url>                   (login, rotate, probe-graphql) Send GraphQL to
                                            <url> instead of https://<site>/gateway/api/graphql.
                                            Prints a warning; plain http only for loopback.

        Exit status: 0 success, 1 failure, 2 usage error,
                     3 the gateway rejected the scoped token (probe-graphql).
        """

    static var login: String {
        """
        Usage: adf-auth login [--site <site>] [--email <email>] [--expiry-days <n>]
                              [--token-stdin] [--no-open] [--dry-run]

        Creates a Confluence API token with read-only scopes, checks it against the
        site's GraphQL gateway, and saves it in your login keychain.

          1. Asks for the site and email unless given.
          2. Opens Atlassian's API token page and prints the click-by-click steps.
             Scopes: \(scopes)
          3. Reads the token with echo off (or one line of stdin with --token-stdin).
          4. Sends one GraphQL query (AdfAuthCheck) to get the site's cloud ID.
          5. Asks for the expiry you chose (terminal only) and saves the account.
             Logging in again for the same site replaces its token.

        Options:
          --site <site>       acme, acme.atlassian.net, or any URL on the site
          --email <email>     The email of your Atlassian account
          --expiry-days <n>   The expiry you pick on Atlassian's page (1-365, default \(AtlassianTokenScopes.defaultExpiryDays))
          --token-stdin       Read the token as one line of stdin (needs --site and --email)
          --no-open           Don't open the token page in the browser
          --dry-run           Show what would happen; no network, browser, token or keychain
          -h, --help          Show this help

        Testing: --gateway <url> sends GraphQL to a stub server (see adf-auth help).
        """
    }

    static let list = """
        Usage: adf-auth list

        Lists the saved accounts: site, email and token expiry. Reads only the
        non-secret summary of each keychain item, never a token.

        Options:
          -h, --help   Show this help
        """

    static let push = """
        Usage: adf-auth push [--site <site>] [--host <ipv4>] [--port <n>]
                             [--timeout <seconds>] [--print-link] [--dry-run]

        Sends a saved account to ADFReader on your phone over the local network,
        once. Shows a QR code; in ADFReader open Settings → Accounts → Scan from Mac.

        The QR code holds the Mac's address, a session ID and a one-time key. The
        Mac serves one sealed (ChaChaPoly) copy of the credential at that session's
        path, asks you to confirm each request, then stops. Every other request gets
        404 and a warning. If the phone gives up before you answer, nothing is sent
        and the code stays valid. Nothing is sent after the timeout.

        Reading the saved token may show a macOS keychain prompt after a rebuild.

        Options:
          --site <site>         The account to send (asked when several are saved)
          --host <ipv4>         The address to listen on (default: this Mac's Wi-Fi/LAN IPv4).
                                The phone only accepts private-network addresses
                                (10/8, 172.16/12, 192.168/16, 100.64/10).
          --port <n>            The port (default 0: any free port)
          --timeout <seconds>   How long the code stays valid (5-120, default 120; the
                                phone waits at most 130 s for your answer)
          --print-link          Also print the pairing link, for the iOS Simulator or a
                                device without a camera. Anyone on the network who
                                sees it before it expires can fetch the credential.
          --dry-run             Show what would happen; no keychain read, no listener
          -h, --help            Show this help
        """

    static var rotate: String {
        """
        Usage: adf-auth rotate <site> [--expiry-days <n>] [--token-stdin] [--no-open]

        Replaces the token for a saved site: runs login with the saved email, offers
        to push the new token to your phone, then opens Atlassian's token page so
        you can revoke the old token.

        Options:
          --expiry-days <n>   The expiry you pick on Atlassian's page (1-365, default \(AtlassianTokenScopes.defaultExpiryDays))
          --token-stdin       Read the new token as one line of stdin
          --no-open           Don't open Atlassian's pages in the browser
          -h, --help          Show this help

        Testing: --gateway <url> sends GraphQL to a stub server (see adf-auth help).
        """
    }

    static let remove = """
        Usage: adf-auth remove <site> [--no-open]

        Deletes the saved account for <site> from the keychain, then opens
        Atlassian's token page so you can revoke the token there too.
        ADFReader on your phone keeps its own copy: remove it in Settings → Accounts.

        Options:
          --no-open    Don't open the token page in the browser
          -h, --help   Show this help
        """

    static let probe = """
        Usage: adf-auth probe-graphql --page <id> [--page <id> ...] [--site <site>] [--raw]

        Looks up pages over the site's GraphQL gateway with a saved account (the
        same AdfProbePages query ADFReader uses for titles). Prints each page's
        title, space and title emoji, and any GraphQL errors verbatim.

        Title emoji needs the \(AtlassianTokenScopes.contentMetadata) scope, which
        ADFReader's token doesn't ask for; that error is reported, not fatal.

        Options:
          --page <id>     A numeric page ID (repeat for more pages)
          --site <site>   The account to use (asked when several are saved)
          --raw           Print the gateway's JSON response instead (never contains the token)
          -h, --help      Show this help

        Exits 3 if the gateway rejects the scoped API token for the query.

        Testing: --gateway <url> sends GraphQL to a stub server (see adf-auth help).
        """

    /// Help for a command name, or nil if there is no such command.
    static func text(for command: String) -> String? {
        switch command {
        case "login": return login
        case "list": return list
        case "push": return push
        case "rotate": return rotate
        case "remove": return remove
        case "probe-graphql": return probe
        case "help": return main
        default: return nil
        }
    }
}
#endif
