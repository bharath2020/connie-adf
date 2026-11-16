# Atlassian Auth

How ADFReader gets a read-only Atlassian API token. Code: `Sources/ADFAtlassianAuth`
(shared module), `Sources/ADFAuthCLI` (`adf-auth`; help text in `Help.swift`),
`Demo/ADFReader/{AccountStore,AccountsView,AddAccountView,PairScanView,SettingsView}.swift`.

## 1. What it is

ADFReader calls a Confluence Cloud site's GraphQL gateway with Basic `email:token`
auth, using a scoped API token the user creates at Atlassian. There is one
credential per site (`<name>.atlassian.net` only): site, email, cloudId, token,
scopes, created and expiry dates. `adf-auth` creates and checks it on the Mac and
keeps it in the login keychain; `adf-auth push` hands it to the phone once over
the local network. The app can also take the token by hand.

```text
Mac (adf-auth)                                   iPhone (ADFReader)
login: token page in browser -> paste token (echo off)
       AdfAuthCheck -> cloudId -> login keychain "ADFReader – <site>"
push:  QR adfreader://pair?v=1&h=<ip:port>&s=<sid>#k=<key>
                       ---- scan ---->           Settings → Atlassian Accounts → Scan from Mac
       listener <---- GET http://<ip:port>/h/<sid> (one fetch)
       "Phone <ip> is asking for <site> — send? [y/N]"
       200 sealed box ---------------->          open with key -> "Add <site> as <email>?"
                                                 AdfAuthCheck -> iOS keychain
Manual path (no Mac):                            Add Manually -> Open Token Page -> paste
                                                 -> AdfAuthCheck -> iOS keychain
```

## 2. Setup with the CLI (macOS)

```sh
swift build -c release --product adf-auth          # -> .build/release/adf-auth
codesign -s "<identity>" .build/release/adf-auth   # optional
```

An unsigned binary gets a new identity on every rebuild, so macOS asks again
before it reads a saved token. Signing with a stable identity stops that.

| Command | What it does |
|---|---|
| `login [--site <site>] [--email <email>] [--expiry-days <n>] [--token-stdin] [--no-open]` | Opens the token page, reads the token (`readpassphrase`, or one stdin line), offers to clear it from the clipboard, runs `AdfAuthCheck`, asks the expiry you picked, saves. Same site again replaces the token. It never prompts from a piped stdin: there `--site` and `--email` are required. |
| `list` | Site, email, expiry, from the non-secret summary only. Suggests `rotate` at 14 days or fewer. |
| `push [--site <site>] [--host <ipv4>] [--port <n>] [--timeout <seconds>]` | One-time QR handoff (section 4). Timeout 5–120 s, default 120; port 0 = any free port. The QR is drawn only on a terminal; with stdout piped, `push` exits 2. |
| `rotate <site> [--expiry-days <n>] [--token-stdin] [--no-open]` | `login` with the saved email, offers `push`, then points to the token page to revoke the old token. |
| `remove <site> [--no-open]` | Deletes the Mac item, opens the token page to revoke it. The phone keeps its own copy. |
| `probe-graphql --page <id> [--page <id> …] [--site <site>] [--raw]` | Runs `AdfProbePages`: title, space, emoji, link, and GraphQL errors verbatim. |

- Exit status: 0 success, 1 failure, 2 usage error, 3 scoped token rejected
  (`probe-graphql`). The token is never taken as an argument (`--token` exits 2).
- **Scopes** (app "Confluence", exactly these): `read:page:confluence`,
  `read:space:confluence`, `read:blogpost:confluence`,
  `read:content.metadata:confluence` (the last one is for page-title emoji).
  Default expiry 90 days
  (`--expiry-days` 1–365). Scopes can't be added to a token; a new one means a new token.
- **Token page:** `https://id.atlassian.com/manage-profile/security/api-tokens?autofillToken&expiryDays=<n>&appId=confluence&selectedScopes=<percent-encoded JSON array>`.
  Atlassian does not document these preselection parameters, so they are
  unverified. `login` always prints the seven manual steps and the scope list.

## 3. Setup in ADFReader

- Space list → gear (Settings) → **Atlassian Accounts**.
- **Add Manually:** Site, Email, **Open Token Page** (same URL, 90 days), paste the
  token into a `SecureField`, set **Expires** to the date you picked (default
  +90 days), **Connect**. Nothing is saved if `AdfAuthCheck` fails.
- **Scan from Mac:** run `adf-auth push`, scan, answer on the Mac, then **Add** on
  "Add <site> as <email>?" (it warns when it replaces another email). Pairing is
  QR-scan only; without a camera (Simulator) use Add Manually. A code counts as
  used only once the Mac has served it: after a cancelled or failed fetch (network,
  timeout, the Mac declined), **Try Again** / **Scan Again** works with the same
  code. Cancel on "Add …?" discards the credential; that code is spent, so push again.
- **Expiry banner:** at 14 days or fewer, or expired, with **Replace Token** (manual
  form, site and email filled in). The row's context menu has it too.
- **Remove:** swipe or context menu. Deletes the token from this device only;
  also revoke it at Atlassian (**Manage API Tokens** link in the list footer).

## 4. Security model

**Storage.** One generic-password item per site, same on both sides
(`KeychainCredentialStore`). macOS uses the legacy login keychain (no
entitlements needed); iOS uses the app's keychain.

| Attribute | Value |
|---|---|
| service / account | `com.connie.adfreader.atlassian` / site host |
| label | `ADFReader – <site>` |
| accessible | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |
| synchronizable / access group | `false` (never iCloud Keychain) / none |
| `kSecAttrGeneric` | summary JSON (site, email, cloudId, scopes, dates), no token; listing reads only this |
| data | credential JSON, including the token |

**Handoff.**

- Link: `adfreader://pair?v=1&h=<ipv4:port>&s=<sid>#k=<key>`; `sid` = 16 random
  bytes, `key` = 32 random bytes, both base64url. The key is in the fragment; the
  link never holds the token.
- Seal: CryptoKit `ChaChaPoly` (RFC 8439), key `k`, authenticated data = `sid`.
- Mac: one-shot IPv4 listener on the Wi-Fi/LAN address (`en0` first, or `--host`).
  Only `GET /h/<sid>` matches; anything else gets 404 and a warning. Each match
  asks `send? [y/N]`; only `y`/`yes` sends (Enter or end of input = no), and
  keys typed before the question appears are discarded. Yes → one 200, then the
  listener stops; no → 403, keeps listening. If the phone disconnects while you decide, nothing is
  sent and the code stays valid. Valid 120 s by default; at most 8 connections;
  the request head must arrive within 10 s and fit in 8 KiB; the sealed copy is
  zeroed when the listener finishes.
- Phone: strict parse; fetches only from private-range IPv4 hosts (10/8,
  172.16/12, 192.168/16, 100.64/10). One GET on an ephemeral `URLSession`,
  redirects refused, body capped at 64 KiB, waits up to 130 s. Info.plist has
  `NSLocalNetworkUsageDescription` and `NSAllowsLocalNetworking`.

**A photo of the QR** leaks the Mac's address, `sid` and the key, not the token.
Until the code is used or expires, someone on the same network could request it,
but the Mac shows their IP and asks you first. The photo plus a capture of that
one plain-HTTP response would open the box. After that the listener is gone.

**Logging.** The credential, GraphQL client and pairing link redact the token,
`sid` and key in `description`, `debugDescription` and `dump`. Server events
show `/h/<redacted>`; `--raw`
prints the gateway's response, never the request.

**Known limits.** Guest or client-isolated Wi-Fi, VPNs, cellular, or denied Local
Network access break the fetch: use Add Manually. Zeroing is best-effort.
Future work (hardening option C): an X25519 exchange with a confirmation code
shown on both screens before the Mac encrypts.

## 5. GraphQL only

Every call is a POST to `https://<site>/gateway/api/graphql` with
`Authorization: Basic base64(email:token)`, JSON, `User-Agent: adf-auth/1`, 30 s
timeout. There is no REST fallback and no `_edge/tenant_info`; the cloudId comes
from `tenantContexts`. Documents (`GraphQL/GraphQLDocuments.swift`):

```graphql
query AdfAuthCheck($hostNames: [String!]!) {
  tenantContexts(hostNames: $hostNames) { cloudId hostName }
}
```

```graphql
query AdfProbePages($ids: [ID!]!) {
  confluence {
    pages(ids: $ids) {
      id pageId title
      links { base webUi }
      space { id key name icon { path } }
      metadata { titleEmojiPublished { id key value } }
    }
  }
}
```

Variables: `{"hostNames": ["<site host>"]}` (only the entry whose `hostName`
matches counts) and `{"ids": ["ari:cloud:confluence:<cloudId>:page/<pageId>"]}`.
Only `probe-graphql` runs `AdfProbePages` today; the app does not look up titles yet.

| Gateway response | `AtlassianAuthError` |
|---|---|
| "scoped" (or API/container token, not on a 401) in an HTTP 401/403 body or a GraphQL error; checked first | `scopedTokenRejected(field:detail:)`; `probe-graphql` exits 3 |
| HTTP 401, or GraphQL status 401 / unauthorized | `unauthorized` (wrong email or token, or not a Confluence token) |
| HTTP 403, or GraphQL status 403 / forbidden / permission | `forbidden` (message lists the four scopes) |
| HTTP 404, `CloudIdNotFoundException`, or no matching tenant | `siteNotFound` |
| HTTP 429 | `rateLimited` (`Retry-After` seconds or HTTP date) |
| 200 with pages and errors | Normal result, errors listed verbatim; a `metadata` error only marks the emoji unavailable. Errors are mapped only when no pages come back. |
| Anything else | `graphQL(messages:)`, `server(status:)`, `invalidResponse`, `network` |

## 6. Unverified until a real token is tried

Introspection on 2026-11-15 showed `tenantContexts(hostNames: [String!])` and
`confluence.pages(ids: [ID]!)` carry no `@scopedApiTokenUnavailable`, but how the
gateway treats a scoped token at runtime is unknown. Take a page ID from a page
URL (`/wiki/spaces/KEY/pages/<id>/Title`) and run:

```sh
adf-auth login                      # items 1-2
adf-auth probe-graphql --page <id>  # items 3-5 (--site <site> if several; --raw for JSON)
```

| # | Question | Answer |
|---|---|---|
| 1 | Does the token-page URL preselect Confluence, the scopes and 90 days? | Look at the page `login` opens. |
| 2 | Does `tenantContexts` accept a scoped token? (Reportedly 403 without auth; we always send it.) | `login` saves = yes; a scoped-token, 401 or 403 message = no. |
| 3 | Does `confluence.pages` accept a scoped token? | Exit 0 with titles = yes; exit 3 = no. |
| 4 | Emoji: `ConfluenceContentMetadata` needs `read:content.metadata:confluence`, which `login` now asks for. Whether the gateway honours it for a scoped token is unverified. | Expect the emoji in the probe output. A token created without the scope shows `Emoji: not available` plus the scope error; replace it with `adf-auth rotate`. |
| 5 | Batch cap for `pages(ids:)` | Repeat `--page` with 100, then 250 distinct IDs; look for a limit error. |

## 7. Export compliance

`ITSAppUsesNonExemptEncryption` stays `false` in `Demo/project.yml` (a comment
there records why). This is the project's reasoning, not legal advice: all crypto
is Apple OS-provided (CryptoKit, Security, URLSession TLS) with no proprietary or
custom algorithms, and ChaChaPoly (RFC 8439) only protects an authentication
credential (email + API token) during the one-time local handoff. Encryption
limited to authentication, and encryption within Apple's OS, are exempt under EAR
Category 5 Part 2 (Apple's "limited to authentication" and "only uses encryption
within Apple's operating system" answers). Revisit if the app ever encrypts other
data or ships its own crypto.

## 8. Testing

- `Tests/ADFAtlassianAuthTests/`: site, credential and redaction, store, GraphQL
  parsing and error mapping, pairing link, seal, handoff client and server. Only
  synthetic tokens (`ATATT3xFfGF0-synthetic-…`), a `URLProtocol` stub
  (`AuthStubProtocol`) and `127.0.0.1` listeners; nothing calls Atlassian.
  Run `swift test --filter ADFAtlassianAuthTests`.
- Real keychain round-trip: opt-in with `ADF_AUTH_KEYCHAIN_TESTS=1` (unique
  `com.connie.adfreader.atlassian.tests.<UUID>` service, cleaned up).
- `Demo/ADFReaderUITests/AccountsUITests.swift`: offline, `-openAccounts` (opens
  Settings on Atlassian Accounts; ignored with `-fixture`). It never saves an
  account.
- The CLI target has no unit tests. Neither the CLI nor the app has a GraphQL
  endpoint override: the token only goes to `https://<site>/gateway/api/graphql`.
  Stub servers are reached only from unit tests, through
  `AtlassianGraphQLClient`'s `endpoint:` and `session:` parameters.
