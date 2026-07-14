# ADF Beam — Chrome and Firefox extension

Beams the current Confluence Cloud page's ADF to the ADFReader iOS app as an
animated QR code, with no server in between. The extension fetches the page's
Atlas Document Format over your existing browser session, compresses it, and
cycles it as QR frames; ADFReader's **Scan** screen collects the frames
(camera, or pasted payloads) and renders the document.

The same unpacked folder loads in both browsers — there is no build step and no
per-browser variant. `manifest.json` declares both a `service_worker` (Chrome,
whose MV3 has nothing else) and a `scripts` event page (Firefox, which has no
MV3 service workers); each browser reads the key it supports and ignores the
other.

## Install (unpacked, dev mode)

Fetch the extension (no account or auth needed — it's mirrored to a public
repo, https://github.com/bharath2020/adf-beam-extension):

```bash
curl -sL https://github.com/bharath2020/adf-beam-extension/archive/main.tar.gz | tar xz
```

This leaves an `adf-beam-extension-main/` folder. Then, one time:

1. Open `chrome://extensions`.
2. Enable **Developer mode** (top right).
3. Click **Load unpacked** and select the `adf-beam-extension-main` folder
   (or `Tools/adf-beam-extension` if you work in the main repo).

To update later, re-run the fetch command in the same place and press the
reload arrow on the extension's card in `chrome://extensions`.

### Firefox

1. Open `about:debugging#/runtime/this-firefox`.
2. Click **Load Temporary Add-on…** and pick the `manifest.json` inside the
   extension folder.
3. The **ADF Beam** button appears in the toolbar (pin it from the extensions
   puzzle-piece menu if you don't see it).

A temporary add-on is unloaded when Firefox quits, so repeat this after a
restart — or run `npx web-ext run --source-dir Tools/adf-beam-extension`, which
launches Firefox with the extension installed and reloads it on file changes.
Requires Firefox 121 or newer.

Maintainers: this directory lives in the (private) `connie-adf` repo and is
mirrored to the public repo with

```bash
git subtree split --prefix=Tools/adf-beam-extension -b extension-public main
git push https://github.com/bharath2020/adf-beam-extension.git extension-public:main
```

## Usage

1. Open a Confluence Cloud page (`https://<site>.atlassian.net/wiki/...`).
2. Click the **ADF Beam** toolbar action.
3. The overlay shows the page title and a cycling QR code:
   - **Speed** slider: 1–15 frames per second.
   - **Chunk size**: 300–1200 bytes per frame (smaller = denser cycle of
     easier-to-scan codes). Changing it regenerates frames live.
   - **Copy all frames**: puts every frame payload (one per line) on the
     clipboard — paste into ADFReader's Scan → Paste sheet as the no-camera
     path.
4. In ADFReader: **Scan**, point the camera at the QR (or use **Paste**),
   watch the per-chunk progress fill, and the document opens on completion.

Clicking the toolbar action again closes the overlay. On a non-Confluence
page, an unrecognized URL, or a failed API fetch, the overlay shows an error
message instead of a QR.

## No-extension mode (`beam.html`)

Where a managed browser blocks extensions (a corporate `ExtensionSettings`
policy), `beam.html` does the same job with no install and no scripting of the
Confluence page:

1. Get the page's ADF onto your clipboard. Either:
   - **One click (bookmarklet):** drag `bookmarklet.txt`'s contents onto your
     bookmarks bar (see *Bookmarklet* below). On any Confluence page, click it
     — it fetches that page's ADF under your session and copies it. Or
   - **Manual:** open
     `https://<site>.atlassian.net/wiki/api/v2/pages/<PAGE_ID>?body-format=atlas_doc_format`
     in the address bar (uses your session — no token, no auth flow;
     `<PAGE_ID>` is the number in the page URL's `/pages/<id>/` segment), then
     select all and copy.
2. Open `beam.html` in any browser, press **Paste from clipboard** (or paste
   manually), then **Beam**. It renders the same cycling QR with fps +
   chunk-size controls and "Copy all frames".
3. Scan with ADFReader (or use Copy all frames → Scan → Paste).

### Bookmarklet

`bookmarklet.js` is the readable source; `bookmarklet.txt` is the built,
draggable `javascript:` URL (regenerate with `node build-bookmarklet.mjs`).
To install: create a new bookmark and paste the `bookmarklet.txt` line as its
URL. One click on a Confluence page fetches that page's ADF and copies it —
then paste into `beam.html`.

Why it works where the extension is blocked: a bookmarklet is not an
extension, so a corporate `ExtensionSettings` policy doesn't restrict it, and
Chrome exempts bookmarklets from the page's CSP. Its `fetch` is same-origin,
so it rides your existing Confluence session. (Same data-handling caveat as
above — use it for content you're entitled to move.)

`beam.html` accepts either the full API response (it unwraps
`body.atlas_doc_format.value`) or a bare ADF document. It runs entirely
locally — the same `shared/protocol.js` + vendored `pako`/`qrcode`, no
extension APIs — so it works from a `file://` path on a locked-down browser.

Note: this is for content you're entitled to move. On a managed device the
extension block often reflects a deliberate data-handling policy; clear
corp-Confluence use with IT rather than routing around it.

## Protocol

Each frame payload is a single line:

```
ADF1|<docId>|<index>|<total>|<data>
```

- `docId` — identifies one copy of one document (`<pageId>-<version>`); a
  frame with a different docId (or total) resets the scanner's collector.
- `index` / `total` — zero-based chunk index and chunk count, so frames can
  arrive in any order and duplicates are ignored.
- `data` — base64 of one ≤ chunk-size slice of the **raw-deflate**-compressed
  ADF JSON. Raw deflate is load-bearing: pako's default `deflate()` is
  zlib-wrapped, while Apple's `COMPRESSION_ZLIB` is raw deflate — both sides
  use `deflateRaw`/`inflateRaw` semantics.

`shared/protocol.js` implements encode/decode; `Sources/ADFBeam` is the Swift
counterpart. `make-fixture.mjs` generates the shared fixture that both
implementations must decode byte-identically (`CrossImplementationTests`).

## Tests

- `node test-roundtrip.mjs` — headless encode→decode round-trip (exits 0 on PASS).
- `test.html` — the same round-trip in a real browser; open it and look for **PASS**.
  Requires `test-fixture.js`, generated by `node make-fixture.mjs`.
- `swift test --filter ADFBeamTests` — Swift-side frame/collector/assembler +
  cross-implementation fixture tests.

Vendored libraries (no build step, CSP-safe): `lib/pako.min.js` (pako 2.1.0),
`lib/qrcode.js` (qrcode-generator 1.4.4).
