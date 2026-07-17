# PROTOTYPE — throwaway

**Question**: can a custom read-only `UITextInput` container +
`UITextInteraction(.nonEditable)` deliver native continuous selection
(start/end grab handles, system highlight, copy) across the SwiftUI block
stack, using the search index as the text model?

**Verdict (2026-07-17): YES** — handles, highlight, handle drags, Select
All, and document-ordered Copy all work over real prepared blocks; scroll
coexists. Main gap: shadow-TextKit geometry drifts on mark-heavy paragraphs
(fix: dual-scope attributes at preparation time).

Full assessment: `docs/Text-Selection-Assessment.md`. Tracking: issue #5;
this prototype is preserved on the `selection-prototype` branch.

Run: `xcrun simctl launch <udid> com.connie.adfreader -selectionPrototype kitchen-sink`
(demo hook in `Demo/ADFReader/ADFReaderApp.swift`).

Delete this directory (and the demo hook) once a production decision is
made, or absorb the pieces the production design keeps.
