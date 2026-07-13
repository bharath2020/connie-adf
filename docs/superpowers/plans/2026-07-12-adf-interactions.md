# Mention & Task Interactions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make @mentions tappable (open a fake profile sheet for the tapped name) and task checkboxes tappable (toggle + remember state per page across launches), keeping the renderer a pure, optional-interaction view layer.

**Architecture:** The renderer exposes one injected callback taking an `ADFInteraction` action enum, plus a read-only `taskStates` override map — both via environment (same pattern as `ADFMediaProvider`). The Demo app supplies the handler, presents the profile sheet, and persists task state in `UserDefaults`.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, UserDefaults.

## Global Constraints

- swift-tools 6.0; iOS 17 / macOS 14.
- Package tests use Swift Testing (`import Testing`), not XCTest.
- Demo app: `SWIFT_STRICT_CONCURRENCY: complete`, `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES` — warning-clean, concurrency-correct.
- Interactions are OPTIONAL: with no injected handler, mentions and tasks render read-only exactly as today. Never crash without a handler.
- Only a task's checkbox toggles; tapping task text does nothing.
- Profile data is fabricated deterministically from the name (same name → same profile). Use a stable hash (FNV-1a over UTF-8), NOT Swift's `Hasher` (its seed is randomized per launch).
- The renderer does not persist anything; the host owns persistence.

---

### Task 1: Library — interaction API and task id threading

**Files:**
- Create: `Sources/ADFRendering/ADFInteraction.swift`
- Modify: `Sources/ADFRendering/Environment.swift`
- Modify: `Sources/ADFRendering/ADFDocumentView.swift` (init + env inject)
- Modify: `Sources/ADFPreparation/RenderBlock.swift:108` (`ListMarker.task`)
- Modify: `Sources/ADFPreparation/ListPreparer.swift:52,60` (thread `item.id`)
- Test: `Tests/ADFPreparationTests/PreparerTests.swift` (add a test)

**Interfaces:**
- Produces:
  - `public enum ADFInteraction: Sendable { case mentionTapped(name: String); case taskToggled(id: String, isDone: Bool) }`
  - `EnvironmentValues.adfInteractionHandler: ((ADFInteraction) -> Void)?` (default nil)
  - `EnvironmentValues.adfTaskStates: [String: Bool]` (default `[:]`)
  - `ADFDocumentView.init(model:mediaProvider:interactionHandler:taskStates:)` (last two defaulted)
  - `ListMarker.task(id: String, done: Bool)`

- [ ] **Step 1: Write the failing preparation test**

Open `Tests/ADFPreparationTests/PreparerTests.swift`, note how existing tests build a document (follow that exact pattern — parse JSON/fixture into `ADFDocument`, then run the preparer). Add:

```swift
@Test("task list rows carry a stable non-empty task id")
func taskRowsCarryID() async throws {
    let json = """
    {"version":1,"type":"doc","content":[
      {"type":"taskList","attrs":{"localId":"tl"},"content":[
        {"type":"taskItem","attrs":{"localId":"t1","state":"DONE"},"content":[{"type":"text","text":"done one"}]},
        {"type":"taskItem","attrs":{"localId":"t2","state":"TODO"},"content":[{"type":"text","text":"todo two"}]}
      ]}
    ]}
    """
    let blocks = try await prepareBlocks(fromJSON: json)   // use the suite's existing prepare helper
    let taskRows = blocks.flatMap(taskMarkers)             // helper below
    #expect(taskRows.count == 2)
    for (id, _) in taskRows { #expect(!id.isEmpty) }
    #expect(taskRows.contains { $0.1 == true })            // the DONE item
    #expect(taskRows.contains { $0.1 == false })           // the TODO item
}
```

If the suite has no `prepareBlocks(fromJSON:)`/marker helper, add small local helpers in the test file that mirror how other tests reach `PreparedListRow`s and pattern-match `if case .task(let id, let done) = row.marker { ... }`. The point of the test: every prepared task row exposes a non-empty `id` and the correct `done` flag.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter taskRowsCarryID`
Expected: FAIL — `.task` currently has no `id` (pattern `case .task(let id, let done)` won't compile / marker lacks id).

- [ ] **Step 3: Add `id` to `ListMarker.task`**

`Sources/ADFPreparation/RenderBlock.swift` — change:
```swift
    case task(done: Bool)
```
to:
```swift
    case task(id: String, done: Bool)
```

- [ ] **Step 4: Thread the node id in `ListPreparer`**

`Sources/ADFPreparation/ListPreparer.swift` — the `.taskList` case. Change line ~52:
```swift
                        marker: .task(done: state == .done),
```
to:
```swift
                        marker: .task(id: item.id, done: state == .done),
```
and line ~60:
```swift
                    rows.append(contentsOf: itemRows(item, marker: .task(done: false), depth: depth, nestedLevels: levels))
```
to:
```swift
                    rows.append(contentsOf: itemRows(item, marker: .task(id: item.id, done: false), depth: depth, nestedLevels: levels))
```

- [ ] **Step 5: Add the interaction API file**

Create `Sources/ADFRendering/ADFInteraction.swift`:
```swift
import SwiftUI

/// A user interaction with an interactive ADF element, delivered to the host
/// via the injected `adfInteractionHandler`. Parameters ride as associated
/// values so the host switches over intent, not booleans.
public enum ADFInteraction: Sendable {
    /// A mention capsule was tapped. `name` is the mention's display text.
    case mentionTapped(name: String)
    /// A task checkbox was tapped. `id` identifies the task; `isDone` is the
    /// new state the host should record.
    case taskToggled(id: String, isDone: Bool)
}

private struct ADFInteractionHandlerKey: EnvironmentKey {
    static let defaultValue: ((ADFInteraction) -> Void)? = nil
}

private struct ADFTaskStatesKey: EnvironmentKey {
    static let defaultValue: [String: Bool] = [:]
}

public extension EnvironmentValues {
    /// Host-supplied sink for interactions. `nil` (the default) renders
    /// mentions and tasks read-only.
    var adfInteractionHandler: ((ADFInteraction) -> Void)? {
        get { self[ADFInteractionHandlerKey.self] }
        set { self[ADFInteractionHandlerKey.self] = newValue }
    }

    /// Per-task display override of the ADF `done` flag, keyed by task id.
    /// A task shows `adfTaskStates[id] ?? adfDone`.
    var adfTaskStates: [String: Bool] {
        get { self[ADFTaskStatesKey.self] }
        set { self[ADFTaskStatesKey.self] = newValue }
    }
}
```

- [ ] **Step 6: Add init params + env injection to `ADFDocumentView`**

`Sources/ADFRendering/ADFDocumentView.swift` — add stored properties and widen `init`:
```swift
    private let model: ADFDocumentModel
    private let mediaProvider: any ADFMediaProvider
    private let interactionHandler: ((ADFInteraction) -> Void)?
    private let taskStates: [String: Bool]
```
```swift
    public init(model: ADFDocumentModel,
                mediaProvider: any ADFMediaProvider,
                interactionHandler: ((ADFInteraction) -> Void)? = nil,
                taskStates: [String: Bool] = [:]) {
        self.model = model
        self.mediaProvider = mediaProvider
        self.interactionHandler = interactionHandler
        self.taskStates = taskStates
    }
```
And in `body`, add to the existing `.environment(...)` chain (near line 86-88):
```swift
        .environment(\.adfInteractionHandler, interactionHandler)
        .environment(\.adfTaskStates, taskStates)
```

- [ ] **Step 7: Run the test and full suite**

Run: `swift test --filter taskRowsCarryID` → PASS.
Then `swift test` → all suites green (existing preparation/rendering/stress tests still pass after the `ListMarker.task` signature change; if any other `case .task` switch site fails to compile, update it to `.task(let id, let done)` and ignore `id` where unused — but do NOT change rendering behavior here; that's Task 2).

- [ ] **Step 8: Commit**

```bash
git add Sources/ADFRendering/ADFInteraction.swift Sources/ADFRendering/Environment.swift Sources/ADFRendering/ADFDocumentView.swift Sources/ADFPreparation/RenderBlock.swift Sources/ADFPreparation/ListPreparer.swift Tests/ADFPreparationTests/PreparerTests.swift
git commit -m "feat: ADFInteraction API + task id threading"
```

---

### Task 2: Library — interactive mention and task views

**Files:**
- Modify: `Sources/ADFRendering/Inline/AtomViews.swift` (mention case)
- Modify: `Sources/ADFRendering/Blocks/ListBlockView.swift` (task marker)

**Interfaces:**
- Consumes: `ADFInteraction`, `adfInteractionHandler`, `adfTaskStates` (Task 1); `ListMarker.task(id:done:)` (Task 1).
- Produces: no new public API; behavior only.

- [ ] **Step 1: Make the mention capsule tappable**

`Sources/ADFRendering/Inline/AtomViews.swift` — replace the `.mention` case in `AtomView.body`:
```swift
        case .mention(let text):
            AtomCapsule(text: AtomFormatting.mentionText(text), tint: .blue)
```
with:
```swift
        case .mention(let text):
            MentionAtomView(text: text)
```
and add, in the same file:
```swift
/// Mention capsule that fires `.mentionTapped` when a host handler is present;
/// read-only otherwise.
private struct MentionAtomView: View {
    let text: String
    @Environment(\.adfInteractionHandler) private var handler

    var body: some View {
        let name = AtomFormatting.mentionText(text)
        AtomCapsule(text: name, tint: .blue)
            .contentShape(Capsule())
            .onTapGesture { handler?(.mentionTapped(name: name)) }
            .accessibilityAddTraits(handler == nil ? [] : .isButton)
    }
}
```

- [ ] **Step 2: Make the task checkbox tappable**

`Sources/ADFRendering/Blocks/ListBlockView.swift` — in `ListRowView.markerView`, replace the `.task` case:
```swift
        case .task(let done):
            // Read-only checkbox glyph per spec (§6.3).
            Text(Image(systemName: done ? "checkmark.square.fill" : "square"))
                .foregroundStyle(done ? Color.accentColor : Color.secondary)
                .accessibilityLabel(done ? "Completed task" : "Task")
```
with:
```swift
        case .task(let id, let done):
            TaskMarkerView(id: id, adfDone: done)
```
and add, in the same file:
```swift
/// Task checkbox. Shows `adfTaskStates[id] ?? adfDone`; toggles via the host
/// handler when present, read-only otherwise. Only the glyph is tappable.
private struct TaskMarkerView: View {
    let id: String
    let adfDone: Bool
    @Environment(\.adfInteractionHandler) private var handler
    @Environment(\.adfTaskStates) private var taskStates

    private var isDone: Bool { taskStates[id] ?? adfDone }

    var body: some View {
        let glyph = Image(systemName: isDone ? "checkmark.square.fill" : "square")
        if let handler {
            Button {
                handler(.taskToggled(id: id, isDone: !isDone))
            } label: {
                Text(glyph).foregroundStyle(isDone ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel(isDone ? "Completed task" : "Task")
            .accessibilityHint("Toggles the task")
        } else {
            Text(glyph)
                .foregroundStyle(isDone ? Color.accentColor : Color.secondary)
                .accessibilityLabel(isDone ? "Completed task" : "Task")
        }
    }
}
```

- [ ] **Step 3: Build the package**

Run: `swift build`
Expected: builds clean, no warnings.

- [ ] **Step 4: Run the full suite**

Run: `swift test`
Expected: all green (behavior change isn't unit-tested; the read-only default path is preserved, existing tests exercise it).

- [ ] **Step 5: Commit**

```bash
git add Sources/ADFRendering/Inline/AtomViews.swift Sources/ADFRendering/Blocks/ListBlockView.swift
git commit -m "feat: interactive mention + task views (read-only without a handler)"
```

---

### Task 3: App — FakeProfile, ProfileSheet, TaskStateStore, DocumentSource.storageKey

**Files:**
- Create: `Demo/ADFReader/FakeProfile.swift`
- Create: `Demo/ADFReader/ProfileSheet.swift`
- Create: `Demo/ADFReader/TaskStateStore.swift`
- Modify: `Demo/ADFReader/DocumentSource.swift`

**Interfaces:**
- Produces:
  - `struct FakeProfile { init(name: String); name, initials, title, team, email, status: String; color: Color }`
  - `struct ProfileSheet: View { init(name: String) }`
  - `struct TaskStateStore { func states(for docKey: String) -> [String: Bool]; func setState(_ isDone: Bool, taskId: String, docKey: String) }`
  - `DocumentSource.storageKey: String`

- [ ] **Step 1: `FakeProfile` (deterministic from name)**

Create `Demo/ADFReader/FakeProfile.swift`:
```swift
import SwiftUI

/// A fabricated-but-consistent profile derived from a mention's name.
/// Deterministic: the same name always yields the same profile.
struct FakeProfile {
    let name: String
    let initials: String
    let title: String
    let team: String
    let email: String
    let status: String
    let color: Color

    init(name rawName: String) {
        let clean = rawName.hasPrefix("@") ? String(rawName.dropFirst()) : rawName
        let trimmed = clean.trimmingCharacters(in: .whitespaces)
        name = trimmed.isEmpty ? "Unknown" : trimmed

        let words = name.split(separator: " ")
        initials = words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()

        let h = Self.stableHash(name)
        let titles = ["Product Lead", "Staff Engineer", "Design Manager", "Data Scientist",
                      "Engineering Manager", "Product Designer", "Solutions Architect", "QA Lead"]
        let teams = ["Core", "Growth", "Platform", "Payments", "Mobile", "Design Systems", "Data", "Quality"]
        let statuses = ["Available", "In a meeting", "Focusing", "Away", "On vacation"]
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .red]

        title = titles[h % titles.count]
        team = teams[(h / 3) % teams.count]
        status = statuses[(h / 7) % statuses.count]
        color = palette[(h / 11) % palette.count]

        let handle = words.map { $0.lowercased() }.joined(separator: ".")
        email = "\(handle.isEmpty ? "user" : handle)@meridian.app"
    }

    /// FNV-1a over UTF-8 — stable across launches (unlike Swift's `Hasher`).
    private static func stableHash(_ s: String) -> Int {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in s.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return Int(hash % UInt64(Int.max))
    }
}
```

- [ ] **Step 2: `ProfileSheet`**

Create `Demo/ADFReader/ProfileSheet.swift`:
```swift
import SwiftUI

/// A sample profile card for a tapped mention. Fully fabricated; no network.
struct ProfileSheet: View {
    let name: String
    @Environment(\.dismiss) private var dismiss

    private var profile: FakeProfile { FakeProfile(name: name) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Circle()
                    .fill(profile.color.gradient)
                    .frame(width: 96, height: 96)
                    .overlay {
                        Text(profile.initials)
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.top, 24)

                VStack(spacing: 4) {
                    Text(profile.name).font(.title2.weight(.bold))
                    Text("\(profile.title) · \(profile.team)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    row(icon: "envelope", text: profile.email)
                    row(icon: "circle.fill", text: profile.status, tint: profile.color)
                }
                .padding().frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
                .padding(.horizontal)

                Text("Sample profile — generated for demo purposes.")
                    .font(.footnote).foregroundStyle(.tertiary)
                Spacer()
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func row(icon: String, text: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 20)
            Text(text)
            Spacer()
        }
    }
}
```

- [ ] **Step 3: `TaskStateStore`**

Create `Demo/ADFReader/TaskStateStore.swift`:
```swift
import Foundation

/// Persists task toggle state as `[docKey: [taskId: Bool]]` in UserDefaults.
/// Read-modify-write per change; the data set is tiny.
struct TaskStateStore {
    var defaults: UserDefaults = .standard
    private let key = "adf.taskStates"

    func states(for docKey: String) -> [String: Bool] {
        all()[docKey] ?? [:]
    }

    func setState(_ isDone: Bool, taskId: String, docKey: String) {
        var map = all()
        map[docKey, default: [:]][taskId] = isDone
        if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: key)
        }
    }

    private func all() -> [String: [String: Bool]] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: [String: Bool]].self, from: data)
        else { return [:] }
        return decoded
    }
}
```

- [ ] **Step 4: Add `DocumentSource.storageKey`**

`Demo/ADFReader/DocumentSource.swift` — add inside the enum:
```swift
    /// Stable key for persisting per-document state (task toggles).
    var storageKey: String {
        switch self {
        case .fixture(let fixture): return "fixture:\(fixture.name)"
        case .remotePage(let id, _): return "page:\(id)"
        }
    }
```

- [ ] **Step 5: Build the app**

Run:
```bash
cd Demo && xcodegen generate && \
xcodebuild -project ADFReader.xcodeproj -scheme ADFReader \
  -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -4
```
Expected: `** BUILD SUCCEEDED **` (these types are unused until Task 4, but must compile warning-clean).

- [ ] **Step 6: Commit**

```bash
git add Demo/ADFReader/FakeProfile.swift Demo/ADFReader/ProfileSheet.swift Demo/ADFReader/TaskStateStore.swift Demo/ADFReader/DocumentSource.swift
git commit -m "feat: fake profile, profile sheet, task-state store, storageKey"
```

---

### Task 4: App — wire interactions into ReaderView

**Files:**
- Modify: `Demo/ADFReader/ReaderView.swift`

**Interfaces:**
- Consumes: `ADFInteraction`, `ADFDocumentView(...interactionHandler:taskStates:)` (Tasks 1-2); `FakeProfile`/`ProfileSheet`/`TaskStateStore`/`DocumentSource.storageKey` (Task 3).

- [ ] **Step 1: Read the current `ReaderView.swift`**

Open `Demo/ADFReader/ReaderView.swift` and locate: the `@State` block, the `ADFDocumentView(model: model, mediaProvider: mediaProvider)` call, and the `load()` function.

- [ ] **Step 2: Add interaction state, seeding, handler, and the sheet**

Add these `@State`s alongside the existing ones:
```swift
    @State private var taskStates: [String: Bool] = [:]
    @State private var selectedProfile: MentionProfile?
```
Add a private store and an Identifiable wrapper (put the struct at file scope, outside `ReaderView`):
```swift
    private let taskStore = TaskStateStore()
```
```swift
/// Identifiable wrapper so a tapped mention name can drive `.sheet(item:)`.
private struct MentionProfile: Identifiable {
    let id = UUID()
    let name: String
}
```
Add the handler method inside `ReaderView`:
```swift
    private func handle(_ interaction: ADFInteraction) {
        switch interaction {
        case .mentionTapped(let name):
            selectedProfile = MentionProfile(name: name)
        case .taskToggled(let id, let isDone):
            taskStore.setState(isDone, taskId: id, docKey: source.storageKey)
            taskStates[id] = isDone
        }
    }
```
Change the render call to pass the handler and state:
```swift
        ADFDocumentView(model: model,
                        mediaProvider: mediaProvider,
                        interactionHandler: handle,
                        taskStates: taskStates)
```
Add the sheet to the same view (alongside existing `.overlay`/`.toolbar` modifiers):
```swift
            .sheet(item: $selectedProfile) { ProfileSheet(name: $0.name) }
```
Seed the persisted task state when the document loads. In `load()`, before/right after kicking off the fetch, set:
```swift
        taskStates = taskStore.states(for: source.storageKey)
```
(Seeding is synchronous and independent of the async document fetch; it must run whether the source is a fixture or a remote page. If `load()` is `Task`-wrapped, set `taskStates` on the main actor before or after the `await`, not inside a background hop.)

- [ ] **Step 3: Build the app**

Run:
```bash
cd Demo && xcodegen generate && \
xcodebuild -project ADFReader.xcodeproj -scheme ADFReader \
  -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -4
```
Expected: `** BUILD SUCCEEDED **`, warning-clean.

- [ ] **Step 4: Package tests still green**

Run: `swift test 2>&1 | tail -3`
Expected: all pass (unchanged).

- [ ] **Step 5: Commit**

```bash
git add Demo/ADFReader/ReaderView.swift
git commit -m "feat: wire mention profile sheet + persistent task toggles into ReaderView"
```

---

### Task 5: Verify on simulator and ship TestFlight build 8

**Files:**
- Modify: `Demo/project.yml` (`CURRENT_PROJECT_VERSION` 7 → 8)

**Interfaces:** none; integration + verification + release.

- [ ] **Step 1: Boot, install, launch**

Reuse a booted simulator (`xcrun simctl list devices booted`), install the Debug build from Task 4's derived data (or rebuild with `-derivedDataPath build/dd`), launch `com.connie.adfreader`.

- [ ] **Step 2: Verify mention → profile sheet**

Open a remote page containing a mention (e.g. the CEO "Launch Go/No-Go Memo" or any page whose panel mentions Bharath Booshan). Tap the mention capsule; screenshot. Expected: a profile sheet with the tapped name, initials avatar, title/team/email/status. Read the screenshot to confirm.

- [ ] **Step 3: Verify task toggle + persistence**

Open a page with a task list (e.g. "Launch Go/No-Go Memo" → Conditions). Tap a checkbox; screenshot (state flips). Navigate back to the tree and reopen the page; screenshot (state retained). Terminate and relaunch the app, reopen the page; screenshot (state still retained). Read each screenshot to confirm.

- [ ] **Step 4: Bump build and archive**

```bash
# Demo/project.yml: CURRENT_PROJECT_VERSION "7" -> "8", commit
cd Demo && xcodegen generate
xcodebuild -project ADFReader.xcodeproj -scheme ADFReader -configuration Release \
  -destination 'generic/platform=iOS' -archivePath <scratch>/ADFReader8.xcarchive archive 2>&1 | tail -3
```
Expected: `** ARCHIVE SUCCEEDED **`.

- [ ] **Step 5: Export + upload to TestFlight**

Export with the existing `ExportOptions.plist`, then:
```bash
asc publish testflight --app 6789955057 --ipa <scratch>/export8/ADFReader.ipa \
  --group dace4f3b-1d30-4c0c-9bcf-a1c67613649d \
  --test-notes "Tap an @mention to see a sample profile; tap a task checkbox to toggle it — task state is remembered per page across relaunches." \
  --locale en-US --wait --timeout 30m
```
Expected: `processingState":"VALID"`.

- [ ] **Step 6: Commit the build bump**

```bash
git add Demo/project.yml
git commit -m "chore: build 8 (mention + task interactions)"
```

---

## Self-Review

- **Spec coverage:** interaction API + action enum (Task 1), task id threading (Task 1), interactive mention/task views with read-only fallback (Task 2), fake profile + sheet + task store + storageKey (Task 3), ReaderView wiring + sheet + persistence seeding (Task 4), simulator verification + TestFlight (Task 5). Error/edge cases (no handler → read-only, UserDefaults decode failure → empty) are in the code (`handler?`, `try?` decode). All spec sections mapped.
- **Placeholder scan:** none — every code step is complete. `<scratch>` in Task 5 is a path the executor fills with the session scratchpad, consistent with prior release tasks.
- **Type consistency:** `ADFInteraction.mentionTapped(name:)` / `.taskToggled(id:isDone:)`, `adfInteractionHandler`, `adfTaskStates`, `ListMarker.task(id:done:)`, `ADFDocumentView(...interactionHandler:taskStates:)`, `FakeProfile(name:)`, `ProfileSheet(name:)`, `TaskStateStore.states(for:)` / `.setState(_:taskId:docKey:)`, `DocumentSource.storageKey` are used identically across tasks.
- **Verified against code:** `ListMarker.task(done:)` at `RenderBlock.swift:108`; two construction sites at `ListPreparer.swift:52,60`; `ADFDocumentView` env chain at `ADFDocumentView.swift:86-88`; mention/task read sites at `AtomViews.swift` (`.mention`) and `ListBlockView.swift` (`.task`). One risk noted in Task 1 Step 7: other `case .task` switch sites (if any) must be updated to the new signature — the compiler will surface them.
