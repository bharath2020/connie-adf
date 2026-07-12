# ADF Beam — Execution Plan

## Approach

Two components joined by a tiny frame protocol: `ADF1|<docId>|<index>|<total>|<data>`, where `data` is a base64 chunk (default 800 bytes) of the **raw-deflate**-compressed ADF JSON.

- **Swift side**: a new SPM target `ADFBeam` (Foundation-only, testable via `swift test` on macOS) holds frame parsing, the chunk collector, and decompression. The ADFReader demo app adds a `ScanView` (camera + paste dev path) on top of it.
- **Extension side**: `Tools/adf-beam-extension/` — Manifest V3, vanilla JS, no build step; `pako` and `qrcode` vendored locally (CSP-safe, no CDN). A shared `protocol.js` implements compress/chunk/encode and its inverse for the round-trip test page.
- **Cross-impl proof**: a Node script generates chunk-payload fixtures from `Fixtures/kitchen-sink.json`; the same fixture files are verified by a Swift test and the browser test page.

**Critical compatibility note**: pako's default `deflate()` emits zlib-wrapped data, but Apple's `Compression` framework `COMPRESSION_ZLIB` is *raw* deflate. Both sides must use raw deflate (`pako.deflateRaw`/`inflateRaw` ↔ `COMPRESSION_ZLIB`). This is asserted by the shared-fixture tests.

**Acceptance path** (per facts): the overlay includes a **"Copy all frames"** button that puts every frame payload (one per line) on the clipboard; pasting that into the simulator's ScanView paste sheet must render the document.

## Steps

### 1. `ADFBeam` SPM target — protocol core
Files: `Package.swift` (add `ADFBeam` target + `ADFBeamTests` test target), `Sources/ADFBeam/BeamFrame.swift` (parse `ADF1|…` payload → docId/index/total/data, reject malformed), `Sources/ADFBeam/ChunkCollector.swift` (out-of-order accept, duplicate ignore, docId-mismatch reset, progress reporting, completion), `Sources/ADFBeam/BeamAssembler.swift` (join → base64-decode → raw-inflate → `Data`).
Tests: `Tests/ADFBeamTests/` — frame parsing (valid/malformed), collector behavior (order, dupes, reset), assembler round-trip against synthetic deflated data.
**Verify**: `swift test --filter ADFBeamTests` passes; `swift build` clean.

### 2. Extension protocol library + round-trip test page
Files: `Tools/adf-beam-extension/lib/pako.min.js`, `lib/qrcode.js` (vendored), `shared/protocol.js` (encode: JSON → deflateRaw → base64 → chunks → frame strings; decode: inverse), `test.html` (loads `kitchen-sink.json` content, runs encode→decode round-trip in the browser, prints PASS/FAIL and asserts byte-identical JSON).
**Verify**: `node Tools/adf-beam-extension/test-roundtrip.mjs` (same assertions headlessly) exits 0; opening `test.html` shows PASS.

### 3. Shared protocol fixtures — cross-implementation agreement
Files: `Tools/adf-beam-extension/make-fixture.mjs` (reads `Fixtures/kitchen-sink.json`, emits `Tests/ADFBeamTests/Fixtures/kitchen-sink.chunks.txt` — one frame payload per line, fixed docId), Swift test `CrossImplementationTests.swift` (feeds every line through `ChunkCollector` + `BeamAssembler`, asserts result is byte-identical to `Fixtures/kitchen-sink.json`).
**Verify**: `node make-fixture.mjs && swift test --filter CrossImplementation` passes — proving JS encoder ↔ Swift decoder agree.

### 4. Chrome extension UI
Files: `manifest.json` (MV3; `action`, `scripting` + `activeTab` permissions, host permission `https://*.atlassian.net/*`), `background.js` (action click → inject content script), `content.js` + `overlay.css` (extract page ID from URL — both `/pages/<id>/…` and `?pageId=<id>` forms; fetch `/wiki/api/v2/pages/{id}?body-format=atlas_doc_format` with `credentials: include`; note the ADF arrives as a JSON *string* in `body.atlas_doc_format.value`; render fullscreen overlay: large cycling QR canvas, page title, frame i/n, fps slider, chunk-size selector (regenerates frames live), "Copy all frames" button, close button; error states for non-Confluence URL / fetch failure / non-OK response).
**Verify**: load unpacked via `chrome://extensions` with no errors (manual); on the meeting-notes page the overlay cycles QR frames and "Copy all frames" fills the clipboard; on a non-Confluence tab the action shows the error state. (Chrome MCP tools can drive parts of this check.)

### 5. ADFReader ScanView (camera + paste + progress + success)
Files: `Demo/ADFReader/ScanView.swift` (AVCaptureSession + AVCaptureMetadataOutput QR scanning feeding `ChunkCollector`; segmented per-chunk progress bar + "n of total" label; `UIImpactFeedbackGenerator` tick per new chunk; idle-timeout "Keep the code in frame" hint; on completion `UINotificationFeedbackGenerator` success + checkmark overlay, write assembled JSON to a temp file named `Scanned Document.json`, navigate to `ReaderView` via `Fixture(url:)` — no ReaderView changes; on assembly/parse failure, error state with "Scan again" resetting the collector; paste sheet accepting multi-line frame payloads driving the identical collector path), `FixtureListView.swift` (add "Scan" entry above fixtures), `Demo/project.yml` (add `NSCameraUsageDescription`), regenerate with `xcodegen`.
**Verify**: `cd Demo && xcodegen && xcodebuild -project ADFReader.xcodeproj -scheme ADFReader -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build` succeeds with warnings-as-errors.

### 6. End-to-end acceptance
Run the extension on the real meeting-notes Confluence page → "Copy all frames" → boot simulator, launch ADFReader → Scan → paste sheet → paste → progress fills → success haptic/checkmark → document renders correctly (compare headings/content against the Confluence page). Also exercise: mismatched-docId reset (paste frames from two different copies), corrupted-frame failure → "Scan again".
**Verify**: manual walkthrough on simulator (screenshots via `simctl io screenshot`); camera path checked opportunistically on a physical device if available — not gating.

### 7. Docs + commit hygiene
`Tools/adf-beam-extension/README.md` (install-unpacked steps, usage, protocol spec); brief §17 note in `docs/Architecture-Decisions.md` (protocol + raw-deflate decision). Commit in reviewable slices per step.

## Risks / open questions

- **QR-off-monitor readability**: dense frames may misread depending on monitor PPI/refresh; mitigated by fps + chunk-size live controls (facts) — and irrelevant to the paste-path acceptance bar.
- **Confluence URL variants**: page ID extraction covers the two known URL shapes; unknown shapes fall into the explicit error state rather than failing silently.
- **`swift test` currently green?** Assumed; step 1 starts from a clean `swift test` baseline to avoid attributing pre-existing failures to new work.
- **Node availability** for fixture generation (steps 2–3); if absent, fall back to generating fixtures from the browser test page and saving the file manually.
