# Atlassian Media Fetch

How ADFReader loads the images (Confluence attachments) that ADF `media`
nodes reference, using the scoped API token from
[Atlassian-Auth.md](Atlassian-Auth.md). Code: `Sources/ADFAtlassianMedia`
(`AtlassianMediaFetcher`, `AtlassianMediaError`, `AtlassianAttachment`;
emoji: `AtlassianEmojiFetcher`, `AtlassianEmojiError`).
Research notes: ADF-RES5, 2026-11-19.

## TL;DR

- A `media` node's `attrs.id` is the attachment's **file ID**, and its
  `collection` is `contentId-<page id>`. There is no lookup by file ID, so the
  fetcher lists the page's attachments, matches `fileId`, then downloads by
  **attachment ID** through the v1 REST API.
- Scoped tokens only work on `https://api.atlassian.com/ex/confluence/{cloudId}/…`
  with Basic `email:token`, never on the site URL.
- The token needs **both** `read:attachment:confluence` and
  `readonly:content.attachment:confluence`. Both are now in
  `AtlassianTokenScopes.required`; **older tokens must be re-created** to show
  images.
- The download 302s to the media host. `Authorization` is stripped on any
  other host, and a non-HTTPS redirect is refused.
- Custom (site) emoji are **not** reachable through any official API or scope.
  Decision (option A): `AtlassianEmojiFetcher` uses Atlassian's undocumented
  emoji service behind its own app setting (default **off**), with
  `:shortName:` text as the fallback (section 6).
- Plug point: `AtlassianMediaFetcher(credential:).mediaFetch`, a
  `@Sendable (MediaAttrs) async throws -> Data`. It returns raw bytes;
  downsampling is the resolver's job.

```text
media(id: <fileId>, collection: "contentId-<page>")
  -> cloudId: credential.cloudId, else GET https://<site>/_edge/tenant_info (no auth), cached
  -> GET  {gw}/wiki/api/v2/pages/<page>/attachments?limit=250    cached per page, one in-flight
          follow _links.next (page cap 40)                         request chain per page
  -> attachment where fileId == media id (miss in a cached list older than 60 s -> refetch once)
  -> mediaType must be image/*, else unsupportedMediaType, nothing downloaded
  -> GET  {gw}/wiki/rest/api/content/<page>/child/attachment/<att id>/download
          302 -> media host: Authorization stripped (other host), https only
  -> raw bytes (2xx)
gw = https://api.atlassian.com/ex/confluence/{cloudId}
```

## 1. Endpoints

| Step | Request | Auth | Scope | Source |
|---|---|---|---|---|
| Cloud ID | `GET https://<site>.atlassian.net/_edge/tenant_info` → `{"cloudId":"…"}` | none | none | [Atlassian KB: retrieve a site's cloud ID](https://support.atlassian.com/jira/kb/retrieve-my-atlassian-sites-cloud-id/) |
| Gateway | `https://api.atlassian.com/ex/confluence/{cloudId}/…` instead of the site URL | Basic `email:token` | | [Manage API tokens (scoped tokens)](https://support.atlassian.com/atlassian-account/docs/manage-api-tokens-for-your-atlassian-account/) |
| List | `GET {gw}/wiki/api/v2/pages/{id}/attachments?limit=250` (`getPageAttachments`; `limit` 1–250, default 50) | Basic | `read:attachment:confluence` | [Confluence v2 OpenAPI](https://dac-static.atlassian.com/cloud/confluence/openapi-v2.v3.json) |
| Download | `GET {gw}/wiki/rest/api/content/{id}/child/attachment/{attachmentId}/download` (`downloadAttatchment`) → 302 | Basic | `readonly:content.attachment:confluence` (current) + `read:attachment:confluence` (beta) | [Confluence v1 OpenAPI](https://dac-static.atlassian.com/cloud/confluence/swagger.v3.json) |

List response (`MultiEntityResult<Attachment>`): `results[]` of `AttachmentBulk`
(`id` = `att…`, `title`, `pageId`, `mediaType`, `fileId`, `fileSize`,
`downloadLink`, `_links.download`) and `_links.{next, base}`. The spec says
`fileId` "is the ID referenced in `atlas_doc_format` bodies and is distinct
from the attachment ID". The v2 API has no full-file download (thumbnails
only), hence the v1 endpoint.

**Pagination.** `_links.next` is documented as "the relative URL for the next
set of results, using a cursor query parameter"; the `Link` header example is
`</wiki/api/v2/pages/<id>/attachments?cursor=…>; rel="next"`. So it is
site-relative (`/wiki/…`) and the fetcher puts it after the gateway prefix.
Only its path and query are used, never its host: `/wiki/…` → `{gw}/wiki/…`,
`/ex/confluence/…` → `{apiBase}/ex/…`, `/api/v2/…` (relative to
`_links.base` = `<site>/wiki`) → `{gw}/wiki/api/v2/…`. A repeated link or 40
pages (10 000 attachments) stops the loop.

**Not used:** `downloadLink` / `_links.download` (`/download/attachments/…` on
the site). It is deprecated for token use
([community thread](https://community.developer.atlassian.com/t/94448)) and an
unauthenticated probe redirected to the login page.

## 2. Scopes, and why both

The v1 download endpoint's `x-atlassian-oauth2-scopes` lists the classic
`readonly:content.attachment:confluence` as **Current** and the granular
`read:attachment:confluence` as **Beta**; the v2 list endpoint needs the
granular one. A third-party live report (confluence2md PR #98) found that
granting only one of the two let listing succeed but downloads fail, so
ADFReader asks for both
([scopes reference](https://developer.atlassian.com/cloud/confluence/scopes-for-oauth-2-3LO-and-forge-apps/)).

`AtlassianTokenScopes.attachment` and `.attachmentDownload` are in `required`,
so `adf-auth login`, the token-page link and the manual steps all include them.
Scopes can't be added to an existing token: a token created before this change
lists titles fine but gets `forbidden` for images. Re-create it with
`adf-auth rotate <site>` (or Add Manually in the app). `AtlassianMediaError.forbidden`
says exactly that.

## 3. Redirects and credentials

`URLSession` follows the download's 302 itself; each request runs with a
per-task delegate (`session.data(for:delegate:)`, `AuthRedirectGuard`):

| Redirect target | Result |
|---|---|
| `https`, same host as the original request | followed, headers unchanged |
| `https`, any other host (the media host) | followed, `Authorization` and `X-Client-Id` removed |
| not `https` | refused; the fetch throws `insecureRedirect` |

The redirect target is unverified (expected `api.media.atlassian.com` or
`<site>/media-api/…` with a signed token in the URL, which needs no Basic
auth). Basic `email:token` must never reach a host it was not sent to. The
same guard wraps the list and `tenant_info` requests.

## 4. Errors

`AtlassianMediaError` (`Equatable`, `Sendable`, user-facing `message`, never
the email, token or header):

| Case | When |
|---|---|
| `missingPageId(collection:)` | collection is not `contentId-<digits>` (the page ID always comes from the collection) |
| `attachmentNotFound(fileId:)` | no attachment with that `fileId`; a miss in a cached list refetches it once, at most once a minute (`attachmentListMinRefetchInterval`) |
| `unsupportedMediaType(_:)` | the attachment's listed `mediaType` is not `image/*` (video, PDF, none); thrown before any download request |
| `unauthorized` | HTTP 401 |
| `forbidden` | HTTP 403: most likely the two attachment scopes are missing |
| `notFound` | HTTP 404 (v1 also uses it when the account can't see the attachment) |
| `http(status:)` | any other non-2xx |
| `invalidResponse` | undecodable list or `tenant_info` body, non-HTTP response |
| `unsupportedSource` | `.external(url:)` media (not Atlassian's job here) |
| `insecureRedirect` | a redirect to a non-HTTPS URL |

`URLError` and `CancellationError` are rethrown unchanged. Unauthenticated
probes on 2026-11-19: v2 list → 404 `NOT_FOUND`, v1 download → 403 "caller
cannot access Confluence".

## 5. Plug point and wiring

```swift
let fetcher = AtlassianMediaFetcher(credential: credential)   // one per account
let fetch: @Sendable (MediaAttrs) async throws -> Data = fetcher.mediaFetch
// resolver design §3.4/§4.5: CacheFirstMediaProvider(fetch: fetch)
```

- Module boundary: `ADFAtlassianMedia` depends on `ADFAtlassianAuth` and
  `ADFModel` only. `ADFRendering` and `ADFResolvers` never import
  `ADFAtlassianAuth`; they only see the closure.
- Keep one fetcher per account for the reader session: it caches the cloud ID
  and each page's attachment list, and coalesces concurrent requests (one
  list chain per page, one `tenant_info` call).
- Emoji is wired into the Demo (Lane A): `EmojiResolvers` passes
  `AtlassianEmojiFetcher.emojiFetch` to `CacheFirstEmojiResolver` for
  Confluence pages behind its own setting, using
  `AccountStore.credential(for:)`; the rule and the `-emoji` launch flag are
  in `docs/Architecture-Decisions.md` §23. Media is not wired yet: the
  cache-first media provider with its mock fetch and `-media` launch setting
  belongs to Lane B. When it lands, the live closure goes where the mock one
  is passed, behind the same setting, with the mock kept for tests and
  fixtures.

## 6. Custom emoji

ADF `emoji` nodes carry `attrs.{id, shortName, text}` but no image
(`ADFModel` keeps `shortName`, `id` and `text`; an `id` that is not hex code
points marks a custom emoji). Custom panel icons carry the same ID in `panel.attrs.panelIconId`.

**No official route.** The OAuth/scoped-token scopes list has no emoji or
media scope
([scopes reference](https://developer.atlassian.com/cloud/confluence/scopes-for-oauth-2-3LO-and-forge-apps/)).
The public GraphQL schema has no emoji query (only `ConfluenceContentTitleEmoji`
and reaction `emojiId`); the media-token fields need the internal scope
`confluence:atlassian-external`. Feature request CONFCLOUD-73225 ("no way to
download image behind this emoji id") is Gathering Interest since 2021;
ECO-1375 says `imagePath` has no documented usable URL. Going through the
scoped-token gateway (`api.atlassian.com/ex/confluence/{cloudId}/…emoji…`)
returns 401 "scope does not match".

### Decision (option A, 2026-11-19)

- Use the **undocumented emoji service** that Atlassian's own editor uses
  (`@atlaskit/emoji` 73.7.0: `SiteEmojiResource.findEmoji`, `TokenManager`,
  `MediaImageLoader`). It may change without notice.
- Keep it behind **its own app setting** (for example "Load custom emoji
  images from Atlassian", separate from the media/attachment setting),
  **default off** until a real site emoji on the user's site is verified
  (see the probe results: not yet). The setting lives in the app, not in
  this module.
- Whenever the setting is off or the fetcher throws, render the short name
  as authored (`attrs.text` is ignored for a custom emoji).

### Flow (`AtlassianEmojiFetcher`)

```text
emoji(id?, shortName)
  -> cloudId: credential.cloudId, else GET https://<site>/_edge/tenant_info (no auth), cached
  -> id:  GET {api}/emoji/{cloudId}/{id}?preferredRepresentation=IMAGE         (no auth, cached by id)
     no id, or 404 -> shortName in GET {api}/emoji/{cloudId}/site?preferredRepresentation=IMAGE
                      (no auth; cached, one in flight; a miss refetches a list older than 60 s)
  -> representation.imagePath
     https + host *.atl-paas.net / *.atlassian.com  (standard, Atlassian emoji) -> GET, no credentials
     https + api.media.atlassian.com or <site>/media-api/…  (site emoji)        -> GET with
        Authorization: Bearer <jwt>, X-Client-Id: <clientId>, Accept: image/*
        token: meta.mediaApiToken of any service response, else
               GET {api}/emoji/{cloudId}/site/token/read (no auth)
               cached until expiresAt - 60 s, one refresh in flight,
               refreshed once on 401/403 and the image retried
     anything else -> unsupportedHost / insecureURL, nothing sent
  -> raw bytes (2xx); redirects: https only, Authorization + X-Client-Id dropped on another host
api = https://api.atlassian.com   (https://<site>/gateway/api answers identically)
```

The service answers **without credentials and ignores Basic auth** (same
bodies and headers with and without it), so the scoped API token is never
sent: the credential only supplies the site and cloud ID. The read token
(`aud: media`, `access: {"urn:filestore:collection:emoji-site-<cloudId>": ["read"]}`,
`anonId: anon-user`, 59 min) is anonymous and goes only to the media hosts.

| Endpoint | Response |
|---|---|
| `GET /emoji/{cloudId}/{id}` | `{emojis:[{id, shortName, type: STANDARD/ATLASSIAN/SITE, category, representation:{imagePath, mediaFileId?, width, height}}], meta:{mediaApiToken}}`; unknown ID → 404, empty body |
| `GET /emoji/{cloudId}/site` | same shape, the site's custom emoji |
| `GET /emoji/{cloudId}/site/token/read` | `{clientId, jwt, collectionName: "emoji-site-<cloudId>", url: "https://<site>/media-api", expiresAt (s), expiresIn (ms), maxFileSizeInBytes}` |
| `GET /emoji/standard`, `/emoji/atlassian`, `/emoji/{cloudId}/` | full lists (1 890 standard, 590 Atlassian; the last is all of them); list form uses sprite sheets unless `preferredRepresentation=IMAGE` |
| `GET imagePath` (site emoji) | `https://<site>/media-api/file/<mediaFileId>/image?collection=emoji-site-<cloudId>&width=32&height=32&max-age=31536000`; also served by `api.media.atlassian.com` with the same path |

`altScale=XHDPI` (sent by the editor) made no difference; the `?ids=` bulk form
is not a filter (`/emoji/{cloudId}/?ids=…` returns the full list).

### Probe results (2026-11-19)

Saved under `firstmate/data/adf-res5-atlassian-fetch/emoji/`: `requests.tsv`
(one line per request: name, auth mode, URL, status, size, type),
`responses/NN-*.json` and `*.headers.txt` (JWTs and cookies redacted),
`images/*.png`.

| Route (test site `mycompany`, cloudId `94525a37-…`) | anon | Basic (scoped token) |
|---|---|---|
| `api.atlassian.com/emoji/{c}/0b885b7f-…` (`:Growth_purple:` panel icon, page 196704) | 404 (01) | 404 (01) |
| `<site>/gateway/api/emoji/{c}/0b885b7f-…` | 404 (02) | 404 (02) |
| same + `?altScale=XHDPI`; `/emoji/atlassian/…`, `/emoji/standard/…` | 404 (12–14) | — |
| `…/emoji/{c}/1f600` (both hosts) | 200, CDN `imagePath` (03, 04) | 200, identical |
| `…/emoji/{c}/site` (both hosts) | 200, **0 emoji** (05, 06, 50, 53; re-listed at the end) | 200, 0 emoji (05, 06, 51, 54) |
| `…/emoji/{c}/site/token/read` (both hosts) | 200 token (07, 08) | 200 token |
| `api.atlassian.com/ex/confluence/{c}/…emoji…` | — | 401 "scope does not match" (15, 16) |
| standard CDN PNG `…atl-paas.net/…/1f600.png` | 200 `image/png` 1 315 B (44, `images/standard-1f600.png`) | — |

Control on the public `ecosystem.atlassian.net` (109 site emoji, anonymous
access allowed): by-ID lookup 200 with `mediaFileId` (31), token 200 (33),
image with Bearer + `X-Client-Id` → 200 `image/png` 2 070 B, 32×32, from both
`<site>/media-api` (40) and `api.media.atlassian.com` (41); without a token →
404 (42); with another site's token → 401 (43).

**Verdict.** The flow works end to end on a site whose emoji service shares
site emoji anonymously. On the private test site the `:Growth_purple:` image
was **not** fetchable: its ID is unknown to the service and the site list is
empty with or without Basic auth, so either the site has no custom emoji
(the icon may come from a template on another site) or a private site only
shows them to a signed-in browser session, which a scoped token cannot get.
Unverified; hence the default-off setting.

### Plug point

```swift
let emoji = AtlassianEmojiFetcher(credential: credential)   // one per account
let fetch: @Sendable (String?, String) async throws -> Data = emoji.emojiFetch
// the resolver contract's closure shape (ADFEmojiReference is in ADFRendering):
let resolverFetch: @Sendable (ADFEmojiReference) async throws -> Data = { try await emoji.emojiFetch($0.id, $0.shortName) }
```

Returns raw bytes (PNG; 32×32 observed); downsampling is the resolver's job.
Keep one fetcher per account: it caches the cloud ID, emoji by ID, the site
list and the read token.

### Errors

`AtlassianEmojiError` (`Equatable`, `Sendable`, user-facing `message`, never
a token):

| Case | When |
|---|---|
| `notFound` | 404, empty `emojis`, unknown short name, or neither ID nor short name |
| `unauthorized` | 401/403 from the service, or from the media host after one token refresh |
| `invalidResponse` | undecodable body or token, emoji without `imagePath`, non-HTTP response |
| `insecureURL` | `imagePath` or a redirect that is not `https` |
| `unsupportedHost` | `imagePath` outside the allow-list (also a non-default port or user info) |
| `http(status:)` | any other non-2xx |

`URLError` and `CancellationError` are rethrown unchanged.

## 7. Testing

- `Tests/ADFAtlassianMediaTests/AtlassianMediaFetcherTests.swift`: offline,
  synthetic token, `MediaStubProtocol` (a `URLProtocol` stub that can emit a
  redirect through `wasRedirectedTo:`, so the per-task delegate decides and the
  followed request comes back through the stub and is recorded). Covers request
  URL, method and headers for list and download; cloud ID from the credential
  vs `tenant_info` (sent without `Authorization`); `fileId` matching and
  refetch-once only for a list older than a minute (injected clock); non-image
  attachments refused with no download request; pagination and next-link resolution; page ID parsing and the
  missing-page-ID error; 401/403/404/other mapping; cross-host redirect strips
  `Authorization`, same host keeps it, `http` is refused; concurrent fetches
  make one list call and one `tenant_info` call; `.external` is unsupported;
  redaction. Run `swift test --filter AtlassianMediaFetcherTests`.
- `Tests/ADFAtlassianMediaTests/AtlassianEmojiFetcherTests.swift`: offline,
  synthetic read tokens, the same stub plus an injected clock. Covers the
  lookup URL (ID percent-encoded, `preferredRepresentation=IMAGE`), no Basic
  auth / email / API token on any request, standard (CDN, no headers) vs site
  (Bearer + `X-Client-Id`, site `/media-api` and `api.media.atlassian.com`),
  token from `meta` vs `token/read`, caching, the 60 s expiry margin,
  coalesced concurrent refreshes, one refresh-and-retry on 401/403, short-name
  lookup (with/without colons, cached list, stale-list refetch, ID 404 →
  short name), error mapping, the host allow-list, cross-host redirect
  dropping `Authorization` and `X-Client-Id`, `http` refusal, `tenant_info`,
  `emojiFetch`, redaction. Run `swift test --filter AtlassianEmojiFetcherTests`.
- **Live check** (opt-in, real site), `LiveAtlassianMediaTests.swift`: skipped
  unless `ADF_LIVE_SITE` is set and adf-auth has saved an account for that
  site; it loads that credential at run time through `KeychainCredentialStore`
  (`CredentialStore.load(site:)`), so macOS may ask to allow keychain access. It fetches the page body
  (`GET {gw}/wiki/api/v2/pages/{id}?body-format=atlas_doc_format`;
  `body.atlas_doc_format.value` is a JSON string holding the ADF), parses it
  with `ADFParser`, collects every `.file` media node (whole tree, including
  `mediaSingle`/`mediaGroup`), requires at least one, fetches each and checks
  image attachments decode with ImageIO. A second test reads the raw ADF JSON
  (ADFModel has no emoji ID), collects `emoji` nodes with an `id` plus any IDs
  in `ADF_LIVE_EMOJI_IDS` (comma-separated), fetches each through
  `AtlassianEmojiFetcher` and checks it decodes; with none it prints a note and
  skips the assertion. Custom panel icons are fetched and reported but not
  asserted. It prints only counts, sizes, media types and short names.

  ```sh
  # once: create the token from the prefilled link with all six scopes;
  # adf-auth saves it in the login Keychain ("ADFReader – mycompany.atlassian.net")
  adf-auth login --site mycompany --no-open
  # each run (defaults: ADF_LIVE_SITE=mycompany, ADF_LIVE_PAGE=229377)
  Scripts/live-atlassian-fetch.sh
  ```

  The script checks that the adf-auth Keychain item exists (attributes only,
  never the secret), exits 0 with "no adf-auth account saved for … — skipping"
  when it is missing, and runs `swift test --filter LiveAtlassianMediaTests`
  from the repo root. The test itself reads the credential; neither prints the
  token or the email. The token must have been created with the six current
  scopes.

### Live result (2026-11-20)

`Scripts/live-atlassian-fetch.sh` with `ADF_LIVE_SITE=mycompany` against page
229377 (version 2: one uploaded 320×200 PNG in a `mediaSingle`, one standard
emoji `:grinning:`), using the read-only adf-auth token with the six scopes:
both live tests passed. The media node (`collection: contentId-229377`)
matched attachment `att425985` by `fileId` and downloaded through the v1
redirect as 75,173 bytes of `image/png`, byte-for-byte the uploaded size; the
emoji loaded from the public CDN (1,315 bytes). The site has no custom emoji
of its own, so the custom-emoji path is proven only on a public site (see
"Probe results"); on this site users see the `:shortName:` text fallback.
