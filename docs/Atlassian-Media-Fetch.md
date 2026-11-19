# Atlassian Media Fetch

How ADFReader loads the images (Confluence attachments) that ADF `media`
nodes reference, using the scoped API token from
[Atlassian-Auth.md](Atlassian-Auth.md). Code: `Sources/ADFAtlassianMedia`
(`AtlassianMediaFetcher`, `AtlassianMediaError`, `AtlassianAttachment`).
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
  Status: pending a decision (section 6).
- Plug point: `AtlassianMediaFetcher(credential:).mediaFetch`, a
  `@Sendable (MediaAttrs) async throws -> Data`. It returns raw bytes;
  downsampling is the resolver's job.

```text
media(id: <fileId>, collection: "contentId-<page>")
  -> cloudId: credential.cloudId, else GET https://<site>/_edge/tenant_info (no auth), cached
  -> GET  {gw}/wiki/api/v2/pages/<page>/attachments?limit=250    cached per page, one in-flight
          follow _links.next (page cap 40)                         request chain per page
  -> attachment where fileId == media id (miss in a cached list -> refetch once)
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
| `https`, any other host (the media host) | followed, `Authorization` removed |
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
| `missingPageId(collection:)` | collection is not `contentId-<digits>` and no `pageId` was given |
| `attachmentNotFound(fileId:)` | no attachment with that `fileId`, also after one refetch of a cached list |
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
  `ADFModel` only. `ADFRendering` and the future `ADFResolvers` never import
  `ADFAtlassianAuth`; they only see the closure.
- Keep one fetcher per account for the reader session: it caches the cloud ID
  and each page's attachment list, and coalesces concurrent requests (one
  list chain per page, one `tenant_info` call).
- Not wired into the Demo yet. `ReaderView` waits for the resolver Step 0
  contracts (adf-res2) and Lane B. The Demo also needs
  `AccountStore.credential(for: site) -> AtlassianCredential?`, a thin wrapper
  around `store.load(site:)` (today it only exposes summaries), to build the
  fetcher.

## 6. Custom emoji (pending decision)

ADF `emoji` nodes for site (custom) emoji carry an `id` but no image
(`ADFModel` keeps only `shortName` and `text` today). Findings:

- **No official route.** The OAuth/scoped-token scopes list has no emoji or
  media scope
  ([scopes reference](https://developer.atlassian.com/cloud/confluence/scopes-for-oauth-2-3LO-and-forge-apps/)).
  The public GraphQL schema has no emoji query (only
  `ConfluenceContentTitleEmoji` and reaction `emojiId`); the media-token fields
  need the internal scope `confluence:atlassian-external`.
- **Open feature request** CONFCLOUD-73225 ("no way to download image behind
  this emoji id"), Gathering Interest since 2021; ECO-1375 says `imagePath` has
  no documented usable URL.
- **Undocumented emoji service** (used by Atlassian's own editor), which
  answers without auth and ignores Basic auth:
  `GET https://api.atlassian.com/emoji/{cloudId}/{emojiId}` →
  `representation.{imagePath, mediaFileId, width, height}`;
  `GET https://api.atlassian.com/emoji/{cloudId}/site/token/read` → an
  anonymous read token (`clientId`, `jwt`, ~1 h); then `GET imagePath` with
  `Authorization: Bearer <jwt>` + `X-Client-Id` → PNG. Verified end to end on
  the public `ecosystem.atlassian.net` (108 custom emoji). On the test site the
  anonymous list came back empty: either no custom emoji or the private site
  blocks anonymous listing (unverified).
- **Official fallback:** render `attrs.text` / `shortName`.

Status: **pending a decision** on whether to depend on the undocumented
service. There is no emoji fetch code; the live test only counts `emoji`
nodes (marked TODO).

## 7. Testing

- `Tests/ADFAtlassianMediaTests/AtlassianMediaFetcherTests.swift`: offline,
  synthetic token, `MediaStubProtocol` (a `URLProtocol` stub that can emit a
  redirect through `wasRedirectedTo:`, so the per-task delegate decides and the
  followed request comes back through the stub and is recorded). Covers request
  URL, method and headers for list and download; cloud ID from the credential
  vs `tenant_info` (sent without `Authorization`); `fileId` matching and
  refetch-once; pagination and next-link resolution; page ID parsing and the
  missing-page-ID error; 401/403/404/other mapping; cross-host redirect strips
  `Authorization`, same host keeps it, `http` is refused; concurrent fetches
  make one list call and one `tenant_info` call; `.external` is unsupported;
  redaction. Run `swift test --filter AtlassianMediaFetcherTests`.
- **Live check** (opt-in, real site), `LiveAtlassianMediaTests.swift`: skipped
  unless `ADF_LIVE_TOKEN` is set. It fetches the page body
  (`GET {gw}/wiki/api/v2/pages/{id}?body-format=atlas_doc_format`;
  `body.atlas_doc_format.value` is a JSON string holding the ADF), parses it
  with `ADFParser`, collects every `.file` media node (whole tree, including
  `mediaSingle`/`mediaGroup`), requires at least one, fetches each and checks
  image attachments decode with ImageIO. It prints only counts, sizes and media
  types.

  ```sh
  # once: prompts for the token, nothing on screen or in history
  security add-generic-password -s adf-live-test -a <your-atlassian-email> -U -w
  # each run (defaults: ADF_LIVE_SITE=mycompany.atlassian.net, ADF_LIVE_PAGE=229377)
  Scripts/live-atlassian-fetch.sh
  ```

  The script reads the email from `$ADF_LIVE_EMAIL` or the Keychain item's
  account and the token with `security … -w` into a variable (never echoed),
  exits 0 with "no token stored in Keychain item adf-live-test — skipping" when
  the item is missing, and runs `swift test --filter LiveAtlassianMediaTests`
  from the repo root. The token must have been created with the six current
  scopes.
