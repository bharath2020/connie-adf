# ADF Beam — Firefox port

## Goal

Make the ADF Beam extension load and work in Firefox as well as Chrome, from a
single unpacked folder with no build step, and prove it end-to-end: a real
Confluence page beamed from Firefox and rendered in ADFReader.

## Constraints

- One folder (`Tools/adf-beam-extension`), one `manifest.json`, no build step,
  vendored libraries — the existing philosophy, and what the public mirror
  (`git subtree split`) copies verbatim.
- No protocol change. `shared/protocol.js` and `Sources/ADFBeam` stay
  byte-compatible; ADFReader needs no work.
- Chrome must keep working exactly as it does today.

## Firefox facts the design rests on

Confirmed against MDN and Extension Workshop, not assumed:

- **`background.service_worker` is not supported in Firefox**
  ([bug 1573659](https://bugzil.la/1573659)). Firefox MV3 uses non-persistent
  event pages via `background.scripts`. Specifying **both** keys is the
  documented cross-browser pattern: Chrome uses `service_worker`, Firefox uses
  `scripts`. Firefox 121+ starts the event page correctly even when
  `service_worker` is also present.
- `browser_specific_settings.gecko.id` is required for Firefox.
- Firefox MV3 supports promises on the `chrome.*` namespace, so
  `await chrome.scripting.…` works. A `browser ?? chrome` shim is still used —
  it costs one line and removes the question.
- From Firefox 127 `host_permissions` are shown and granted at install, but a
  user can revoke them ad hoc. `activeTab` remains the load-bearing grant on
  toolbar click, which is how the extension already works.

## Design

### 1. `manifest.json`

- Add `background.scripts: ["background.js"]` next to the existing
  `service_worker`. The same file serves both: `background.js` uses no
  service-worker-only API.
- Add `browser_specific_settings.gecko` with an `id` and a `strict_min_version`
  of at least 121 (event page + `service_worker` coexistence).
- Add `clipboardWrite` to `permissions` for the content script's
  `navigator.clipboard.writeText`. Chrome accepts it harmlessly.

Chrome ignores `browser_specific_settings` and `background.scripts`; Firefox
ignores `background.service_worker`.

### 2. `background.js`

`const api = globalThis.browser ?? globalThis.chrome;` and call
`api.action.onClicked` / `api.scripting.*`. Behavior unchanged.

### 3. `content.js` and the vendored libraries

Unchanged in the happy case. The one real Firefox risk: `background.js` injects
`lib/pako.min.js`, `lib/qrcode.js`, `shared/protocol.js`, and `content.js` as
separate files that communicate through globals (`pako`, `qrcode`,
`ADFBeamProtocol`). Firefox shares one sandbox global across an extension's
injected scripts, so this should hold — but a UMD that binds to the page
`window` through Xrays would fail silently. Validation targets this directly
(step 2 below asserts all three globals resolve). If it breaks, the fix is an
explicit global export in the affected file, not a bundler.

### 4. `README.md`

A Firefox install section (`about:debugging#/runtime/this-firefox` → Load
Temporary Add-on → pick `manifest.json`, or `web-ext run`), and a note that the
same folder loads in both browsers.

Out of scope: signing/AMO submission, `beam.html`, the bookmarklet (both already
browser-agnostic), and any change to the Swift side.

## Validation

The chain, in order — each step gates the next:

1. **Firefox loads the extension and beams a real page.** Firefox runs under
   geckodriver + `selenium-webdriver` against a persistent profile logged into
   Confluence; `installAddon(dir, temporary=true)` loads the unpacked folder.
   The toolbar button is clicked through Marionette's chrome context (WebDriver
   has no extension-action API); fallback is a `cliclick` on the icon's
   coordinates with a screenshot to confirm.
2. **Assert the overlay actually worked**, not merely appeared: title populated
   from the API response; `<canvas>` visible and not blank; the frame counter
   advances across a tick (proves `setInterval` + `drawFrame`); and `pako`,
   `qrcode`, `ADFBeamProtocol` all resolve. Any Firefox console error fails the
   run.
3. **"Copy all frames" → macOS clipboard**, `pbpaste` to a file, validate every
   line is `ADF1|<docId>|<index>|<total>|<data>` and that indices `0..n-1` are
   complete.
4. **Cross-check against Swift before the simulator.** Feed the
   Firefox-produced frames through `ADFBeam`'s decode path and confirm they
   inflate to the JSON the Confluence API returned. This is the real
   correctness gate: if Firefox's `deflateRaw` output round-trips through
   `BeamAssembler`, the port is sound.
5. **Simulator end-to-end.** `xcodegen generate`, build, install, launch
   ADFReader; `xcrun simctl pbcopy booted` the frames from step 3; AXe-tap
   **Scan → Paste → Paste from Clipboard → Add Frames**; screenshot the
   resulting `ReaderView` showing the real page rendered. Taps are label-based —
   `Demo/ADFReader/ScanView.swift` has no accessibility identifiers, and adding
   them is app-side churn a browser port shouldn't incur. No new launch argument
   for the scan path; driving the real UI is the point.
6. **Regression.** `node test-roundtrip.mjs` and `swift test --filter
   ADFBeamTests` stay green, and Chrome still loads the shared folder unpacked
   and beams.

## Validation results (Firefox 134.0.1, 2026-07-13)

Ran end to end against `bharath2020.atlassian.net`, page *Getting started in
Confluence* (id 163936, 19,150 bytes of ADF):

- Real toolbar click in Firefox → overlay with the page title, a live QR canvas,
  the counter cycling **Frame 1/5 → 3/5**, and **"Copied 5 frames"**.
- The copied frames are well-formed: 5 frames, one docId (`163936-1`), indices
  0–4 complete.
- Those frames decode **byte-identically** (19,194 bytes) through Swift's
  `ChunkCollector` / `BeamAssembler`.
- ADFReader on the simulator: pasteboard → Scan → Paste → Paste from Clipboard →
  Add Frames → the real Confluence page renders.
- Chrome (Chrome for Testing): service worker starts, manifest parses with both
  background keys, injection works and `encodeFrames` produces frames. No
  regression from the shared manifest.

### The `globalThis` fix was load-bearing (A/B tested)

With the original `self`-based global resolution, Firefox shows the overlay and
the correct page title, but `root.pako` is `undefined`, so deflate throws, no
frames are built, and the QR canvas stays **blank** — a silent failure with no
visible error. With `globalThis`, all three globals resolve and the beam works.
Worth noting: a "canvas has dark pixels" assertion **false-passes** here, because
an untouched canvas reads as fully transparent-black. The frame counter is the
assertion that catches it.

### Two harness traps (not extension bugs)

Both cost real time and will bite the next person automating this:

1. **`geckodriver`/WebDriver `installAddon` breaks file-based injection.** It
   zips the folder into a temporary XPI, after which *every*
   `scripting.executeScript({files})` and `insertCSS({files})` fails with
   `Unable to load script: moz-extension://…`, while `func:`/`css:` injection and
   `fetch()` of the same files still work. Reproduced with a 20-line stock MV3
   extension containing none of our code. Load the extension the way users do —
   `web-ext run` / `about:debugging` (unpacked, `rootURI` is a `file://` dir) —
   and drive it by attaching geckodriver with `--connect-existing` to a Firefox
   launched by `web-ext --arg=-marionette`.
2. **The toolbar button's clickable node is not the `-browser-action` id.** That
   id belongs to a `toolbaritem` *wrapper*; clicking it does nothing. The real
   button is the child `toolbarbutton#adf-beam_connie-adf-BAP`. Firefox also
   parks extension buttons in the unified-extensions panel, where the DOM node
   does not exist until the panel opens — pin it first with
   `CustomizableUI.addWidgetToArea(widget, CustomizableUI.AREA_NAVBAR)`.

Also: stable Chrome now restricts `--load-extension` for automation; use Chrome
for Testing.

## Success criteria

- The unpacked `Tools/adf-beam-extension` folder loads in both Firefox and
  Chrome with no console errors.
- Clicking the action on a real Confluence page in Firefox produces a cycling
  QR overlay with a correct title and complete frame set.
- Frames copied from the Firefox overlay assemble, in ADFReader on the
  simulator, into the same document the Confluence API returned.
- Existing JS and Swift tests still pass.
