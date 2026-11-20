# Atlassian Auth

How ADFReader gets a read-only Atlassian API token. Code: `Sources/ADFAtlassianAuth`
(shared module), `Sources/ADFAuthCLI` (`adf-auth`; help text in `Help.swift`),
`Demo/ADFReader/{AccountStore,AccountsView,AddAccountView,PairScanView,SettingsView}.swift`.
Using the token to load images (attachments) in pages:
[Atlassian-Media-Fetch.md](Atlassian-Media-Fetch.md) (`Sources/ADFAtlassianMedia`).

## 1. What it is

ADFReader calls a Confluence Cloud site's GraphQL gateway with Basic `email:token`
auth, using a scoped API token the user creates at Atlassian. There is one
credential per site (`<name>.atlassian.net` only): site, email, cloudId, token,
scopes, created and expiry dates. `adf-auth` creates and checks it on the Mac and
keeps it in the login keychain; `adf-auth push` hands it to the phone once over
the local network, in one of two directions: the Mac listens and the phone scans
a QR code, or (`push --to`) the phone listens and the Mac connects out. The app
can also take the token by hand.

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
push --to (Mac blocks incoming):                 Settings → Atlassian Accounts → Mac connects to phone
                                                 shows "adf-auth push --to <ip:port>" + code XXXX-XXXX-XXXX-XXXX
       adf-auth push --to <ip:port>; type code
       TCP connect --------------------->        listener (one-shot, 5 min)
       X25519 handshake, phone proves code first (section 4)
       sealed box ---------------------->        open -> "Add <site> as <email>?" -> iOS keychain
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
| `push --to <ipv4:port> [--site <site>] [--timeout <seconds>]` | The phone listens, the Mac connects out (section 4, "Mac connects to phone"). For a Mac that blocks incoming connections. Prompts "Code shown on your phone: " (needs a terminal; the code is never taken as an argument, so it stays out of `ps` and shell history). Prints the account (site + email) and the result. Timeout 5–300 s, default 30, for connect + send. Not with `--host`/`--port`. |
| `rotate <site> [--expiry-days <n>] [--token-stdin] [--no-open]` | `login` with the saved email, offers `push` (the QR code, Mac listens), then points to the token page to revoke the old token. On a Mac that blocks incoming connections, answer no and run `push --to <ipv4:port>` afterwards: the new token is already saved. Rotate says so before the question and whenever the token wasn't sent. |
| `remove <site> [--no-open]` | Deletes the Mac item, opens the token page to revoke it. The phone keeps its own copy. |
| `probe-graphql --page <id> [--page <id> …] [--site <site>] [--raw]` | Runs `AdfProbePages`: title, space, emoji, link, and GraphQL errors verbatim. |

- Exit status: 0 success, 1 failure, 2 usage error, 3 scoped token rejected
  (`probe-graphql`). The token is never taken as an argument (`--token` exits 2).
- **Scopes** (app "Confluence", exactly these, all read-only): `read:page:confluence`,
  `read:space:confluence`, `read:blogpost:confluence`,
  `read:content.metadata:confluence` (page-title emoji),
  `read:attachment:confluence` and `readonly:content.attachment:confluence`
  (images in pages: list and download attachments; see
  [Atlassian-Media-Fetch.md](Atlassian-Media-Fetch.md)).
  Default expiry 90 days
  (`--expiry-days` 1–365). Scopes can't be added to a token; a new one means a new token.
  **Tokens created before the two attachment scopes were added still work for
  titles but can't show images; re-create them (`adf-auth rotate`).**
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
- **Mac connects to phone** (for a company-managed Mac that blocks incoming
  connections): the screen shows `adf-auth push --to <phone-ip>:<port>` and a code
  `XXXX-XXXX-XXXX-XXXX`, with a countdown and Cancel. It listens only while the
  screen is open (5 min, one credential), on Wi-Fi/wired/bridge addresses only
  (never cellular or a VPN), and keeps the screen awake meanwhile so Auto-Lock
  doesn't stop it. Run the command on the Mac, type the code, then
  **Add** on "Add <site> as <email>?" as with a scan. A mistyped code sends
  nothing and the phone keeps waiting (it shows the failed attempt; only boxes
  that don't open count toward the limit, see section 4). Leaving
  the screen, Cancel, or the app going to the background stops the listener; on a
  timeout or after Cancel, **Try Again** starts over with a new code. Without a
  Wi-Fi/private IPv4 address it says to join Wi-Fi instead of showing a command.
  The screen's hint names the Local Network permission, same Wi-Fi, and VPN
  caveats (section 4). Cancel on "Add …?" discards the credential. The app calls
  `PhoneHandoffListener` (`start()`, `code.formatted`,
  `PhoneHandoffAddress.local(port:)?.pushCommand`, `waitForCredential()`,
  `cancel()`).
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

**Mac connects to phone** (`push --to`, `PhoneHandoffListener` /
`PhoneHandoffSender`, `Sources/ADFAtlassianAuth/Handoff/PhoneHandoff*.swift`).
The phone listens on TCP (IPv4, any port by default, never on cellular) and
shows its private Wi-Fi/wired/bridge address (`en*`, `bridge*`; never
`pdp_ip*` or `utun*`) and a code C: 80 random bits as 16 Crockford base32 symbols
(`XXXX-XXXX-XXXX-XXXX`; typing ignores case, `-` and spaces, reads I/L as 1 and
O as 0, rejects U). The Mac only accepts a private `ipv4:port` (same ranges as
the QR path; loopback only through a test-only initializer). Raw TCP,
length-prefixed binary, no HTTP. A, B = ephemeral X25519 public keys (32 bytes,
raw; a fresh A for every connection).

```text
Mac (adf-auth push --to)                         iPhone (PhoneHandoffListener)
1. "ADFH2" || B  ---------------------------->
2.               <----------------------------   0x00 || A || T   (or 0x03 busy, then close)
                                                 T  = HMAC-SHA256(Kt, "adf-handoff-v2 phone" || A || B)
                                                 Kt = HKDF-SHA256(ikm C, salt empty, info "adf-handoff-v2 tag")
3. check T (constant time); wrong -> close, "Wrong code", nothing sent
4. u32 len || box --------------------------->   open, decode, validate
   box = ChaChaPoly(K, aad "adf-handoff-v2" || A || B)
   K   = HKDF-SHA256(ikm X25519(b, A), salt C, info "adf-handoff-v2 seal" || A || B)
5.               <----------------------------   s || M   s = 0x01 received (stop listening) | 0x02 rejected
                                                 M  = HMAC-SHA256(Ka, s || A || B)
                                                 Ka = HKDF-SHA256(ikm X25519(b, A), salt C, info "adf-handoff-v2 ack" || A || B)
6. check M (constant time): 0x01 -> done; 0x02 -> "couldn't open";
   missing or wrong M -> "couldn't confirm the phone received it"
```

- Limits: box ≤ 64 KiB. Mac: each step ≤ 15 s, the whole exchange ≤ 30 s
  (`--timeout`). Phone: one overall deadline of 20 s per connection, from
  accept to the box.
- Availability: the phone runs up to 4 handshakes at once (at most 2 from one
  peer address), each with its own ephemeral key, so a stalled or junk
  connection can't hold the only slot. A connection beyond that has its
  greeting read and gets the busy byte (at most 8 such replies in flight, 3 s
  each; beyond that it is just closed); the Mac reports "the phone is busy, try
  again". Only private-range peers are accepted, and only on one of the phone's
  own Wi-Fi/wired/bridge addresses: the listener prohibits cellular, and a
  connection whose local address is anything else (a VPN tunnel, for example)
  is closed at once.
- Failures: a failed connection is closed and the phone keeps listening. Only a
  box that doesn't open counts toward the limit of 20 (each one is an online
  guess of C); junk, a bad greeting, timeouts and a Mac that hangs up after a
  wrong T (a mistyped code) don't. The first box that opens ends the session
  (one-shot): the listener stops and every other in-flight connection is
  closed before the acknowledgement is sent. The listener also stops after
  5 minutes or on Cancel.
- Start: a `.waiting` listener (network not ready yet, Local Network permission
  pending) gets 20 s before `start()` fails; cancelling the task that calls
  `start()` cancels the listener.
- Plaintext buffers are zeroed on a best-effort basis (Swift and Foundation
  may keep copies).

Why this construction:

- K is a fresh full-strength 256-bit key from an ephemeral X25519 exchange. The
  typed code never crosses the network and is never the cipher key itself.
- C authenticates both ways. The phone proves it knows C with T before the Mac
  sends anything; the Mac proves it knows C because only a K salted with C
  opens the box.
- A passive eavesdropper gets nothing (ECDH). An active attacker posing as the
  phone must forge T without C; one posing as the Mac must produce a box under a
  C-salted key.
- T is visible to anyone who connects to the phone, so C only has to resist an
  *offline* search for its lifetime (≤ 5 min, one-shot). Finding C after the
  session gives nothing, because the credential was sealed under the ECDH key
  shared with the genuine phone. 80 bits is far beyond any search feasible in
  minutes (about 2^42 HMACs per GPU in 5 min). The Mac sends nothing that
  depends on C before T verifies, so a fake phone gets no offline oracle on C.
- The acknowledgement is authenticated, so an on-path attacker can't fake
  "received" after dropping the box: M needs Ka, which needs both the X25519
  secret and C. Ka has its own HKDF label, so it is independent of K. The phone
  sends M only after a box arrived, and the Mac checks M only after T passed;
  a fake Mac without C learns nothing from a "rejected" M that T (which anyone
  who connects gets) doesn't already give it.
- Why not a PAKE (SPAKE2/CPace): CryptoKit has no curve point arithmetic, and
  hand-rolling one is riskier than this commit-first construction. No
  third-party dependency.
- Caveats: a company VPN that blocks local-network access (common on managed
  Macs), guest or client-isolated Wi-Fi, and a denied iOS Local Network
  permission (Settings → Privacy & Security → Local Network → ADFReader) all
  prevent this path. Then use the QR direction or Add Manually.

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
With `push --to`, someone on the same network can keep the phone's handshake
slots busy (20 s at a time); the Mac then reports "busy" and the user retries.
The QR direction still uses a plain-HTTP fetch of a box sealed with the QR key;
`push --to` is the X25519 path.

**Out of scope (follow-ups).** A cloud relay for networks where neither side can
reach the other.

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
| HTTP 403, or GraphQL status 403 / forbidden / permission | `forbidden` (message lists the six scopes) |
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
- `PhoneHandoffTests.swift` (Mac connects to phone): code generate/format/parse,
  known vectors, aliases, bad characters and lengths, redaction; address parsing
  (private IPv4:port only); handshake crypto (both sides derive the same K, K
  matches an independent HKDF, T only verifies with the right code and
  transcript, the box only opens with the right code and transcript and
  untampered, Ka matches an independent HKDF and the acknowledgement verifies
  only untampered); interface names (only `en*`/`bridge*` offered); loopback
  end-to-end: the credential arrives intact, a wrong code is reported on the
  Mac while the phone keeps listening (not counted) and a correct retry
  succeeds, one-shot (also with other connections in flight, which are
  closed), listener timeout, cancel (also of `start()`), the cap counts only
  boxes that don't open (junk never), a stalled connection is closed at the
  deadline and doesn't block a real Mac, the busy reply (total and per-peer
  limits), a missing, forged, wrong-key, truncated or bare-status
  acknowledgement is rejected, a fake phone gets only the greeting, a silent
  server times out; and the real (non-loopback) binding on this Mac's LAN
  address when it has one.
  Loopback is reachable only through test-only initializers
  (`PhoneHandoffAddress(loopbackForTestingPort:)`, the listener's
  `.loopbackForTesting` binding), never through parsing, and both are
  compiled only in debug builds (`#if DEBUG`).
- Real keychain round-trip: opt-in with `ADF_AUTH_KEYCHAIN_TESTS=1` (unique
  `com.connie.adfreader.atlassian.tests.<UUID>` service, cleaned up).
- `Demo/ADFReaderUITests/AccountsUITests.swift`: offline, `-openAccounts` (opens
  Settings on Atlassian Accounts; ignored with `-fixture`). It never saves an
  account.
- The CLI target has no unit tests. Neither the CLI nor the app has a GraphQL
  endpoint override: the token only goes to `https://<site>/gateway/api/graphql`.
  Stub servers are reached only from unit tests, through
  `AtlassianGraphQLClient`'s `endpoint:` and `session:` parameters.
