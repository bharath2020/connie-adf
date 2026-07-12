# Goal: ADF Beam — Confluence page → animated QR → ADFReader

## Objective

Build a two-part, server-less pipeline that moves a Confluence page's ADF onto ADFReader: a dev-mode (unpacked) Chrome extension that fetches the current Confluence Cloud page's ADF via the browser session, compresses and chunks it, and displays a cycling animated QR overlay; and an ADFReader scanner screen that collects the chunks (camera or pasted payloads) with live progress and haptics, then renders the assembled document through the existing ADF pipeline.

## Shared understanding

`facts.md` in this directory is the reviewed, accepted fact sheet — every fact is an acceptance criterion, with `facts.meta.json` recording which are automated checks.

## Execution plan

`plan.md` in this directory is the approved step-by-step plan, with a concrete verification per step.

## Done condition

All facts in `facts.md` hold. Specifically gating:

1. Automated: `swift test` (ADFBeam frame/collector/assembler tests + cross-implementation fixture test) and the extension round-trip check (`node test-roundtrip.mjs` / `test.html` PASS) all green.
2. End-to-end: frame payloads produced by the extension from a real Confluence page ("Copy all frames"), pasted into ADFReader's scanner on the iOS simulator, show per-chunk progress, complete with success feedback, and render the document correctly.
3. The extension loads unpacked in Chrome with no errors and shows its overlay (QR cycling, fps + chunk-size controls, error states) on Confluence pages.

Physical-device camera scanning is verified opportunistically and does not gate completion.
