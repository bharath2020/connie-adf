# ADFReader Confluence bundle (Cloudflare Pages)

A static, Confluence-REST-v2-shaped snapshot of the `ADFTB` ("ADFReader Test
Bed") Confluence space, served to ADFReader as a read-only Confluence source.

## Layout

```
public/
  api/v2/spaces.json                    { "results": [ { id, key, name } ] }
  api/v2/spaces/<spaceId>/pages.json    { "results": [ { id, title, parentId, spaceId, position } ] }  (flat, ordered)
  api/v2/pages/<pageId>.json            { id, title, spaceId, parentId, body: { atlas_doc_format: { value, representation } } }
  _headers                              JSON content type + permissive CORS
```

`body.atlas_doc_format.value` is a JSON-encoded ADF string, exactly as the
Confluence REST API returns it. The app decodes it to `Data` and renders it
with the existing `ADFParser`. The page tree is built client-side from the flat
`pages.json` (`parentId` + `position`).

Space `ADFTB` id: `15171586`.

## Re-exporting (refresh the snapshot)

The export runs through an authenticated Confluence browser session (no API
token needed). In a logged-in `bharath2020.atlassian.net` tab:

1. Fetch the space record and the flat page list
   (`/wiki/api/v2/spaces/15171586` and
   `/wiki/api/v2/spaces/15171586/pages?limit=100`, following `_links.next`).
2. For each page, fetch `/wiki/api/v2/pages/<id>?body-format=atlas_doc_format`.
3. Assemble `{ space, pages, bodies }`, gzip + base64 it, and pull it out of the
   browser, then split into the files above (see
   `docs/superpowers/plans/2026-07-12-confluence-remote-source.md`, Task 1).
4. Validate: every `pages/*.json` body parses as JSON with `type == "doc"`.

## Deploy

```
wrangler pages deploy cloudflare/public --project-name adfreader-confluence
```

Copy the printed `*.pages.dev` URL into `Demo/ADFReader/AppConfig.swift`
(`confluenceBaseURL`).
