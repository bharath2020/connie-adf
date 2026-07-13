# ADFReader — Mention & Task Interactions

**Status:** approved (2026-07-12)
**Branch:** `feat/adf-interactions`

## Goal

Make two ADF inline/block elements interactive in the reader:

1. **@mention** — tapping a mention capsule opens a sheet showing a fake but
   consistent profile for the tapped name.
2. **Task item** — tapping a task's checkbox toggles it done/undone, and the
   toggled state is remembered per page across app launches.

The renderer stays a pure view layer; the host app owns presentation and
persistence. Interactions are optional — with no host handler, mentions and
tasks render read-only exactly as today.

## Non-goals

- No real profile data, avatars, or network lookups (profiles are fabricated).
- No editing of the ADF document; task toggles are a local overlay.
- No syncing task state back to Confluence.
- Tapping a task's *text* does nothing; only the checkbox toggles.

## Architecture

The renderer exposes a single injected callback that receives an action enum,
plus a read-only task-state override map. The Demo app supplies the handler,
presents the profile sheet, and persists task state.

```
ADFDocumentView(model:, mediaProvider:, interactionHandler:, taskStates:)
   │  injects into environment
   ▼
AtomView(.mention)  ── tap ──▶ handler(.mentionTapped(name:))
ListRowView(.task)  ── tap ──▶ handler(.taskToggled(id:, isDone:))
                       shows taskStates[id] ?? adfDone
   ▲
ReaderView (Demo): builds handler → presents ProfileSheet / writes TaskStateStore
```

## Library changes (`Sources/ADFRendering`, `Sources/ADFPreparation`)

### Interaction API (`Sources/ADFRendering/ADFInteraction.swift`, new)

```swift
public enum ADFInteraction: Sendable {
    case mentionTapped(name: String)
    case taskToggled(id: String, isDone: Bool)
}
```

Environment keys (in `Environment.swift`):
- `adfInteractionHandler: ((ADFInteraction) -> Void)?` — default `nil`.
- `adfTaskStates: [String: Bool]` — default `[:]`; per-task override of the ADF
  `done` flag, keyed by task id.

### `ADFDocumentView`
`init` gains two defaulted params, injected into the environment:
```swift
public init(model: ADFDocumentModel,
            mediaProvider: any ADFMediaProvider,
            interactionHandler: ((ADFInteraction) -> Void)? = nil,
            taskStates: [String: Bool] = [:])
```

### Task id threading (`Sources/ADFPreparation`)
`ListMarker.task` (`RenderBlock.swift`) becomes `case task(id: String, done: Bool)`.
`ListPreparer` passes the task item node's structural `id` (`item.id`) at both
`.task(...)` construction sites. The frozen snapshot makes structural ids stable.

### Mention rendering (`Inline/AtomViews.swift`)
`AtomView` for `.mention`: when `adfInteractionHandler != nil`, wrap the capsule
so a tap fires `.mentionTapped(name:)` with the mention's text (via
`AtomFormatting.mentionText`), with a brief press highlight and
`contentShape`. When the handler is `nil`, render read-only as today.

### Task rendering (`Blocks/ListBlockView.swift`)
`ListRowView` task marker: resolve `isDone = taskStates[id] ?? adfDone`. When a
handler exists, the checkbox is a `Button` (`.borderless`/plain, `contentShape`
limited to the marker glyph) that fires `.taskToggled(id:, isDone: !isDone)`;
otherwise read-only. Only the marker column is tappable — not the row text.

## App changes (`Demo/ADFReader`)

### `FakeProfile.swift`
Deterministic profile from a display name:
- Strip a leading `@`; derive initials (first letters of up to two words).
- Stable color: hash the name → pick from a fixed palette.
- Fabricated title, team, email (`first.last@meridian.app`), and a status,
  chosen deterministically from the name hash so the same name always maps to
  the same profile.

### `ProfileSheet.swift`
A sheet: initials avatar (stable color), the name as-is, title, team, email,
status; a small "Sample profile" footnote. Dismissable.

### `TaskStateStore.swift`
`@Observable` (or plain) store persisting `[docKey: [taskId: Bool]]` in
`UserDefaults` under one key (`adf.taskStates`, JSON-encoded).
- `states(for docKey: String) -> [String: Bool]`
- `setState(_ isDone: Bool, taskId: String, docKey: String)` — writes through to
  `UserDefaults`.

### `DocumentSource`
Add `var storageKey: String` — `.remotePage` → page id; `.fixture` → fixture
name. Used as `docKey`.

### `ReaderView`
- Owns `@State taskStates: [String: Bool]` seeded from the store for this doc's
  `storageKey`, and `@State profileName: String?` for the sheet.
- Builds the handler:
  - `.mentionTapped(name)` → `profileName = name` (presents sheet).
  - `.taskToggled(id, isDone)` → `store.setState(...)`; `taskStates[id] = isDone`.
- Passes `interactionHandler:` and `taskStates:` to `ADFDocumentView`.
- `.sheet(item:)` presents `ProfileSheet(name:)`.

## Error handling / edge cases

- No handler injected (previews, tests, other hosts) → read-only, no crashes.
- A task with no resolvable id still renders; toggling a same-id task updates all
  instances (acceptable — ids are unique per node).
- `UserDefaults` decode failure → treat as empty state (no toggles remembered),
  never crash.

## Testing

The package (`swift test`) is the only automated test surface — the Demo app
has no test target. Keep testable logic in the package where practical; verify
app-only pieces on the simulator.

- **Preparation (package unit test):** a prepared task row's marker carries a
  non-empty `id`, and the ADF `done`/`todo` state maps to the marker correctly.
- **Regression (package):** existing preparation/rendering/stress tests stay
  green after the `ListMarker.task` signature change.
- **`FakeProfile` / `TaskStateStore` (simulator):** same name → identical
  profile (tap the same mention twice); task toggle persists across navigating
  away/back and across an app relaunch; distinct pages keep independent task
  state.
- **Manual (simulator):** tap a mention → profile sheet with the tapped name;
  tap a task checkbox → toggles; tapping task *text* does nothing; a document
  with no handler (e.g. a preview) still renders read-only.

## Deliverable

Interactive mentions (profile sheet) and tasks (persisted toggle) in ADFReader,
verified on the simulator, shipped to TestFlight as the next build.
