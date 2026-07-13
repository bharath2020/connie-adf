# ADFReader — Confluence Remote Source (Cloudflare-hosted)

**Status:** approved (2026-07-12)
**Branch:** `feat/confluence-remote-source`

## Goal

Host the exported `ADFTB` Confluence space as a static, Confluence-shaped JSON
bundle on Cloudflare Pages, and update ADFReader to browse it **as if it were a
Confluence client** — preserving the **Space → page tree → page** terminology
and navigation. The existing ADF renderer is unchanged; the app gains a remote
content source alongside the bundled fixtures.

## Non-goals

- No live Confluence dependency at runtime (the hosted copy is a frozen
  snapshot; refresh by re-running the export).
- No write/edit of Confluence content from the app (read-only).
- No persistent offline sync of remote content in v1. Bundled fixtures remain
  the offline story.
- No auth on the hosted content — it is fictional test data, served public.

## Architecture

Three units with well-defined interfaces:

1. **Export tool** (`Tools/`) — pulls a Confluence space via the existing
   authenticated browser session and writes the static bundle. Run manually.
2. **Cloudflare bundle** (`cloudflare/public/`) — static JSON files at
   Confluence-shaped paths. Deployed by the user via `wrangler`.
3. **App client + UI** (`Demo/ADFReader/`) — a `ConfluenceClient` reading the
   bundle over HTTPS, plus space/tree navigation. `ReaderView` is refactored to
   load from a `DocumentSource` rather than a bundled file.

```
Confluence (ADFTB)  --export-->  cloudflare/public/**.json  --wrangler-->  *.pages.dev
                                                                              |
                                                          ConfluenceClient (URLSession GET)
                                                                              |
                                            SpaceListView -> PageTreeView -> ReaderView -> ADFDocumentView
```

## Cloudflare bundle layout (static REST mimic)

Faithful to Confluence REST v2, flattened to static objects (no query params):

```
public/
  api/v2/spaces.json                    -> { "results": [ { "id", "key", "name", "description" } ] }
  api/v2/spaces/<spaceId>/pages.json    -> { "results": [ { "id", "title", "parentId", "spaceId", "position" } ] }
  api/v2/pages/<pageId>.json            -> { "id", "title", "spaceId", "parentId",
                                             "body": { "atlas_doc_format": { "value": "<ADF as JSON string>",
                                                                             "representation": "atlas_doc_format" } } }
  _headers                              -> Content-Type: application/json
                                           Access-Control-Allow-Origin: *
```

Notes:
- `pages.json` is a **flat, ordered** list. The app builds the tree from
  `parentId` + `position`. No per-page children endpoint (YAGNI).
- `body.atlas_doc_format.value` is a **JSON-encoded string** — exactly as real
  Confluence returns it. The client decodes it to `Data` and passes it to the
  existing `ADFParser`.
- Page ids and space ids are the real Confluence ids (stable, opaque strings).

## Export tool

`Tools/export-space` (driven through the authenticated browser session, so no
API token is required):

1. Input: a space key (default `ADFTB`), generalizing beyond this space.
2. Fetch: the space record, the flat page list (id, title, parentId,
   position), and each page's `atlas_doc_format` body.
3. Write: the bundle under `cloudflare/public/` in the layout above. Page ADF
   is written in small batches to avoid oversized responses.
4. Validate: every exported page's ADF is parsed through `ADFModel`; a parse
   failure or `.unknown` node fails the export loudly.

Output is deterministic given the same Confluence state (stable ids, sorted
keys) so re-exports diff cleanly.

## App changes (`Demo/ADFReader/`)

- **`AppConfig`** — `confluenceBaseURL: URL` constant, set to the deployed
  `*.pages.dev` URL after deploy.
- **`ConfluenceClient`** — async API mirroring Confluence:
  - `spaces() async throws -> [Space]`
  - `pages(inSpace: String) async throws -> [PageSummary]`
  - `page(id: String) async throws -> RemotePage`  (title + decoded ADF `Data`)
  - Uses `URLSession` against `confluenceBaseURL`; default `URLCache`.
- **Models** — `Space { id, key, name }`, `PageSummary { id, title, parentId,
  position }`, and a `PageNode` tree built from the flat list (ordered by
  `position`, then title).
- **`DocumentSource`** (targeted refactor) — `ReaderView` currently binds to
  `Fixture` (a file URL). Replace with:
  ```swift
  enum DocumentSource { case fixture(URL); case remotePage(id: String, title: String) }
  ```
  exposing `title` and `func loadData() async throws -> Data`. This decouples
  the reader from local files so remote pages reuse it verbatim. Launch-argument
  automation (`-fixture`) keeps working via the `.fixture` case.
- **Views**:
  - `SpaceListView` — new root. Remote Spaces on top; a **"Local"** section
    retaining Scan + bundled fixtures.
  - `PageTreeView` — expandable outline of a space's page tree, Confluence-style
    (`DisclosureGroup`/`OutlineGroup`), ordered.
  - `ReaderView` — unchanged rendering; loads from `DocumentSource`.

## Error handling

- Network / decode failures surface a `ContentUnavailableView` with a **Retry**
  action (reusing the reader's existing load-failure overlay pattern).
- A space or page that 404s shows a not-found state rather than crashing.
- Offline with no cache: the remote sections show an unavailable state; Local
  fixtures still work.

## Testing

- **Client** — decode a checked-in **sample bundle** (`Tests/.../Fixtures/`
  mirror of the `api/v2` files) and assert: spaces parse, the flat list builds
  the expected tree (parent/child, order), and a page's ADF `Data` parses via
  `ADFModel`.
- **Export** — a validation step (part of the tool) parses every exported page
  via `ADFModel`; CI-checkable script assertion that the bundle has the space,
  the expected page count, and zero parse issues.
- **Regression** — existing fixture/stress/preparer tests stay green;
  `-fixture` launch automation still opens bundled fixtures.

## Deploy

- Bundle committed under `cloudflare/public/`; a minimal `_headers` sets JSON
  content type and permissive CORS.
- User deploys interactively:
  `! wrangler pages deploy cloudflare/public --project-name adfreader-confluence`
- The returned `*.pages.dev` URL is wired into `AppConfig.confluenceBaseURL`.

## Open risks

- External media/cards in the ADF resolve per the app's existing
  `PlaceholderMediaProvider` and card handling; remote hosting doesn't change
  that behavior.
- If Confluence page ids change (e.g., space recreated), re-export regenerates
  the bundle; the app holds no hardcoded ids.
