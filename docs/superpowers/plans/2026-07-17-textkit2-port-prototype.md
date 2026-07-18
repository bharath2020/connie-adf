# TextKit 2 Port Assessment Prototype — Implementation Plan (Phases 1–3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove (or kill) per-row TextKit 2 rendering of ADFReader's text blocks — the foundation for character-level cross-block selection — against the full perf-gate suite, per `docs/superpowers/specs/2026-07-17-textkit2-port-design.md`.

**Architecture:** Dual-scope `FontSpec` attribute baked at preparation; platform-agnostic conversion + TK2 measurement core (testable under `swift test` on macOS); iOS `TextKit2RowView` (UIView drawing `NSTextLayoutFragment`s) behind a `-textkit2` launch toggle branched inside `SegmentedTextView`/`CodeBlockView`; a UIKit spike proving `UITextInteraction` works from an ancestor view before any selection code is written.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI + UIKit, TextKit 2 (`NSTextContentStorage`/`NSTextLayoutManager`), Swift Testing, xcodegen, axe (simulator automation).

**Scope note:** This plan covers spec phases 1–3 (spike → bare TK2 rows + perf verdict → fidelity + parity). Phases 4–5 (selection engine, final verdict) get their own plan, written at Task 14's checkpoint — the selection controller's shape depends on the spike's answers, and writing its code now would encode guesses (spec §11 kill-fast rationale).

## Global Constraints

Copied from the spec and `docs/Architecture-Decisions.md` — every task implicitly includes these:

- Platform floor iOS 17 / macOS 14; TK2 + selection glue `#if os(iOS)`; the package must keep building and all existing tests passing via bare `swift test` on macOS.
- Never branch on `#available` (or introduce `AnyView`) at any per-row position; a constant-Bool `if/else` at a leaf is safe (§18, §20).
- No string allocation, AttributedString scanning, or TextKit layout inside SwiftUI `body` beyond O(1) memoized lookups (§2, §5.3).
- `TextKit2RowUIView` never calls `invalidateIntrinsicContentSize`; `sizeThatFits` is synchronous, deterministic (`ensureLayout` to end), memoized per width; exactly one geometry commit per materialization (§16 livelock class).
- Fonts resolve at the view layer from `context.environment.dynamicTypeSize` via `UIFont.preferredFont(forTextStyle:compatibleWith:)` + descriptor traits — **never** `UIFontMetrics` scaling of a base point size, never trait-argument-less calls (red-team measured 37 vs 40pt at AX3). Nothing size-dependent is baked at preparation time (§19).
- `RenderBlock`/segment payloads stay closure-free `Sendable + Hashable`; the `[InlineSegment]` array shape (indices, word-chunk splits) must not change — `SearchHighlightSpan.segmentIndex` and the SearchIndexer parts map index it (§18).
- Search's zero-work idle gate: with no active session a leaf reads exactly one observable Bool (`search.isActive`).
- Perf verification for any scrolling change: `-autoscroll` vs a freshly measured same-build baseline **plus** a real fling burst with instantaneous CPU settling to ~0 (`top -l 2`, not `ps`) — the autoscroll gate provably misses livelocks. Debug-sim autoscroll baseline is ~10.3 ms/s, not the ADR's release figure.
- Git: commit at the end of every task; branch `textkit2-port-prototype`; never merge to main within this plan.
- Simulator etiquette: `axe` + `notifyutil -p com.connie.adfreader.rotate` for rotation (`RotationHook`); `AXRaise` the target Simulator window by name before rotating (shared-sim gotcha).

**Demo build reference (used by Tasks 1, 7, 8, 13):**

```bash
cd /Users/bharath2020/Documents/projects/connie-adf/Demo
xcodegen generate                      # after adding any Demo source file
xcodebuild -list -project ADFReader.xcodeproj   # confirm scheme name (expect: ADFReader)
xcodebuild -project ADFReader.xcodeproj -scheme ADFReader \
  -destination "platform=iOS Simulator,name=iPhone 16" build
D=$(xcrun simctl list devices booted | awk -F '[()]' '/iPhone 16/{print $2; exit}')  # boot one first if empty
xcrun simctl install $D <path-to-built .app>
```

---

### Task 0: Branch + plan commit

**Files:** none (git only)

- [ ] **Step 1: Create the branch and commit this plan**

```bash
cd /Users/bharath2020/Documents/projects/connie-adf
git checkout -b textkit2-port-prototype
git add docs/superpowers/plans/2026-07-17-textkit2-port-prototype.md
git commit -m "docs: TextKit 2 port prototype implementation plan (phases 1-3)"
```

---

## Phase 1 — Ancestor-attachment spike (kill question #1)

### Task 1: UITextInteraction-on-ancestor spike screen

Answers the spec's feasibility question #1: does `UITextInteraction(.nonEditable)` deliver selection when attached to an **ancestor** whose hit-tested descendants are interactive views? The prototype's sibling overlay swallowed every content touch; this spike must show long-press selection AND native descendant behavior coexisting. Geometry may be crude (whole-paragraph rects + linear interpolation) — gesture arbitration is the question, not rect fidelity.

**Files:**
- Create: `Demo/ADFReader/SelectionSpike.swift`
- Modify: `Demo/ADFReader/ADFReaderApp.swift` (route `-selectionSpike`)

**Interfaces:**
- Produces: `SpikeScreen: UIViewControllerRepresentable` shown when launch args contain `-selectionSpike`. Findings recorded in `docs/TextKit2-Port-Assessment.md` §"Spike".

- [ ] **Step 1: Write the spike**

`Demo/ADFReader/SelectionSpike.swift` — complete file:

```swift
import SwiftUI
import UIKit

/// Feasibility spike (spec §11 step 1): UITextInteraction attached to an
/// ANCESTOR of interactive content. Not production code — delete or absorb.
struct SpikeScreen: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SpikeViewController { SpikeViewController() }
    func updateUIViewController(_ vc: SpikeViewController, context: Context) {}
}

final class SpikeViewController: UIViewController {
    private let scrollView = UIScrollView()
    private let container = SpikeTextContainer()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scrollView)

        container.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 900)
        scrollView.addSubview(container)
        scrollView.contentSize = container.bounds.size
        container.buildContent()

        // THE spike: interaction on the container (ancestor of every
        // paragraph, the button, and the nested scroll view). No hitTest
        // override anywhere.
        let interaction = UITextInteraction(for: .nonEditable)
        interaction.textInput = container
        container.addInteraction(interaction)
    }
}

/// Ancestor view: hosts three paragraph labels, a button, and a nested
/// horizontal scroll view, and conforms to read-only UITextInput over the
/// concatenated paragraph text. Geometry is deliberately crude.
final class SpikeTextContainer: UIView, UITextInput {
    private(set) var paragraphs: [UILabel] = []
    private(set) var button = UIButton(type: .system)
    private(set) var hScroll = UIScrollView()
    private var texts: [String] = [
        "First paragraph of the ancestor spike. Long-press me to start a selection.",
        "Second paragraph with an emoji 😄 so drags cross it during the spike.",
        "Third paragraph after the interactive content, to drag handles into.",
    ]
    private var joined: String { texts.joined(separator: "\n") }

    func buildContent() {
        var y: CGFloat = 20
        for (i, text) in texts.enumerated() {
            let label = UILabel(frame: CGRect(x: 16, y: y, width: bounds.width - 32, height: 0))
            label.numberOfLines = 0
            label.font = .preferredFont(forTextStyle: .body)
            label.text = text
            label.sizeToFit()
            addSubview(label)
            paragraphs.append(label)
            y = label.frame.maxY + 16
            if i == 0 {
                button.frame = CGRect(x: 16, y: y, width: 160, height: 44)
                button.setTitle("Tap counter: 0", for: .normal)
                button.addAction(UIAction { [weak self] _ in
                    guard let self else { return }
                    self.tapCount += 1
                    self.button.setTitle("Tap counter: \(self.tapCount)", for: .normal)
                }, for: .touchUpInside)
                addSubview(button)
                y = button.frame.maxY + 16
            }
            if i == 1 {
                hScroll.frame = CGRect(x: 16, y: y, width: bounds.width - 32, height: 60)
                hScroll.showsHorizontalScrollIndicator = true
                let wide = UILabel(frame: CGRect(x: 0, y: 0, width: 1200, height: 60))
                wide.text = "wide horizontally scrolling content — pan me sideways — " +
                            "wide horizontally scrolling content"
                hScroll.addSubview(wide)
                hScroll.contentSize = wide.bounds.size
                addSubview(hScroll)
                y = hScroll.frame.maxY + 16
            }
        }
    }

    private var tapCount = 0

    // MARK: - Crude text model (offsets are UTF-16 into `joined`)

    final class Position: UITextPosition {
        let offset: Int
        init(_ offset: Int) { self.offset = offset }
    }
    final class Range_: UITextRange {
        let s: Position; let e: Position
        init(_ s: Position, _ e: Position) { self.s = s; self.e = e }
        override var start: UITextPosition { s }
        override var end: UITextPosition { e }
        override var isEmpty: Bool { s.offset == e.offset }
    }

    var selection: Range_?
    weak var inputDelegate: UITextInputDelegate?
    lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    private func clamp(_ o: Int) -> Int { max(0, min(o, (joined as NSString).length)) }
    private func paragraphIndex(forOffset o: Int) -> Int {
        var start = 0
        for (i, t) in texts.enumerated() {
            let len = (t as NSString).length
            if o <= start + len { return i }
            start += len + 1
        }
        return texts.count - 1
    }
    private func paragraphStart(_ i: Int) -> Int {
        texts.prefix(i).reduce(0) { $0 + ($1 as NSString).length + 1 }
    }

    // MARK: UITextInput (read-only minimum)

    func text(in range: UITextRange) -> String? {
        guard let r = range as? Range_ else { return nil }
        let ns = joined as NSString
        return ns.substring(with: NSRange(location: r.s.offset, length: r.e.offset - r.s.offset))
    }
    func replace(_ range: UITextRange, withText text: String) {}
    var selectedTextRange: UITextRange? {
        get { selection }
        set { selection = newValue as? Range_ }
    }
    var markedTextRange: UITextRange? { nil }
    var markedTextStyle: [NSAttributedString.Key: Any]? { get { nil } set {} }
    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {}
    func unmarkText() {}
    var beginningOfDocument: UITextPosition { Position(0) }
    var endOfDocument: UITextPosition { Position((joined as NSString).length) }
    func textRange(from f: UITextPosition, to t: UITextPosition) -> UITextRange? {
        guard let f = f as? Position, let t = t as? Position else { return nil }
        return f.offset <= t.offset ? Range_(f, t) : Range_(t, f)
    }
    func position(from p: UITextPosition, offset: Int) -> UITextPosition? {
        guard let p = p as? Position else { return nil }
        return Position(clamp(p.offset + offset))
    }
    func position(from p: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        position(from: p, offset: direction == .left ? -offset : offset)
    }
    func compare(_ a: UITextPosition, to b: UITextPosition) -> ComparisonResult {
        guard let a = a as? Position, let b = b as? Position else { return .orderedSame }
        return a.offset < b.offset ? .orderedAscending : a.offset > b.offset ? .orderedDescending : .orderedSame
    }
    func offset(from f: UITextPosition, to t: UITextPosition) -> Int {
        ((t as? Position)?.offset ?? 0) - ((f as? Position)?.offset ?? 0)
    }
    func position(within range: UITextRange, farthest direction: UITextLayoutDirection) -> UITextPosition? {
        direction == .left ? range.start : range.end
    }
    func characterRange(byExtending p: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? { nil }
    func baseWritingDirection(for p: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .leftToRight }
    func setBaseWritingDirection(_ w: NSWritingDirection, for range: UITextRange) {}

    // Crude geometry: per-paragraph linear interpolation.
    func caretRect(for p: UITextPosition) -> CGRect {
        guard let p = p as? Position else { return .zero }
        let i = paragraphIndex(forOffset: p.offset)
        let label = paragraphs[i]
        let start = paragraphStart(i)
        let len = max((texts[i] as NSString).length, 1)
        let fraction = CGFloat(p.offset - start) / CGFloat(len)
        return CGRect(x: label.frame.minX + fraction * label.frame.width,
                      y: label.frame.minY, width: 2, height: label.frame.height)
    }
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        guard let r = range as? Range_ else { return [] }
        let si = paragraphIndex(forOffset: r.s.offset)
        let ei = paragraphIndex(forOffset: r.e.offset)
        return (si...ei).map { i in
            SpikeSelectionRect(rect: paragraphs[i].frame,
                               containsStart: i == si, containsEnd: i == ei)
        }
    }
    func closestPosition(to point: CGPoint) -> UITextPosition? {
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (i, label) in paragraphs.enumerated() {
            let clamped = CGPoint(x: max(label.frame.minX, min(point.x, label.frame.maxX)),
                                  y: max(label.frame.minY, min(point.y, label.frame.maxY)))
            let d = hypot(clamped.x - point.x, clamped.y - point.y)
            if d < bestDistance {
                bestDistance = d
                let len = (texts[i] as NSString).length
                let fraction = (clamped.x - label.frame.minX) / max(label.frame.width, 1)
                best = paragraphStart(i) + Int(fraction * CGFloat(len))
            }
        }
        return Position(clamp(best))
    }
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        closestPosition(to: point)
    }
    func characterRange(at point: CGPoint) -> UITextRange? {
        guard let p = closestPosition(to: point) as? Position else { return nil }
        return Range_(p, Position(clamp(p.offset + 1)))
    }
    var hasText: Bool { true }
    func insertText(_ text: String) {}
    func deleteBackward() {}
    override var canBecomeFirstResponder: Bool { true }
}

final class SpikeSelectionRect: UITextSelectionRect {
    private let r: CGRect; private let s: Bool; private let e: Bool
    init(rect: CGRect, containsStart: Bool, containsEnd: Bool) {
        r = rect; s = containsStart; e = containsEnd
    }
    override var rect: CGRect { r }
    override var writingDirection: NSWritingDirection { .leftToRight }
    override var containsStart: Bool { s }
    override var containsEnd: Bool { e }
    override var isVertical: Bool { false }
}
```

- [ ] **Step 2: Route the launch arg**

In `Demo/ADFReader/ADFReaderApp.swift`, add to `LaunchOptions`: `var selectionSpike = false`, parsed as `case "-selectionSpike": selectionSpike = true` in the argument loop; in the `WindowGroup` body, before the fixture branch:

```swift
if options.selectionSpike {
    SpikeScreen().ignoresSafeArea()
} else if let name = options.fixtureName {
```

(This branch is at app-root level, nowhere near a lazy container — the §18 rule doesn't apply here.)

- [ ] **Step 3: Build and launch**

```bash
cd Demo && xcodegen generate && xcodebuild -project ADFReader.xcodeproj -scheme ADFReader \
  -destination "platform=iOS Simulator,name=iPhone 16" build
xcrun simctl launch $D com.connie.adfreader -selectionSpike
```
Expected: spike screen with 3 paragraphs, a counter button, a horizontal scroller.

- [ ] **Step 4: Run the arbitration matrix with axe and record each result**

| # | Action | Pass condition |
|---|---|---|
| 1 | `axe tap` the button | counter increments (descendant taps alive) |
| 2 | `axe swipe` horizontally over the h-scroll row | it pans (descendant pans alive) |
| 3 | `axe touch --down/--up` long-press on paragraph 1 | word selection w/ native handles appears |
| 4 | drag a handle from ¶1 into ¶3 | selection extends across paragraphs + button region |
| 5 | with selection active, tap the button | counter increments |
| 6 | with selection active, pan the h-scroll | it pans |
| 7 | vertical swipe on ¶ text | outer scroll view scrolls |
| 8 | long-press over the emoji ¶, check Copy via edit menu | copied text matches |

- [ ] **Step 5: Record the verdict**

Create `docs/TextKit2-Port-Assessment.md` with a "Spike: UITextInteraction on an ancestor" section — table above with observed results, screenshots (`xcrun simctl io $D screenshot`), and one of: PROCEED / PROCEED-WITH-CONSTRAINTS (list them) / KILLED (selection architecture falls back per spec §10 kill criteria).

- [ ] **Step 6: Commit**

```bash
git add Demo/ADFReader/SelectionSpike.swift Demo/ADFReader/ADFReaderApp.swift docs/TextKit2-Port-Assessment.md
git commit -m "spike: UITextInteraction attached to ancestor of interactive content"
```

---

## Phase 2 — Bare TK2 rows behind `-textkit2` (kill question #2)

### Task 2: `FontSpec` + custom attributed-string key

**Files:**
- Create: `Sources/ADFPreparation/FontSpec.swift`
- Test: `Tests/ADFPreparationTests/FontSpecTests.swift`

**Interfaces:**
- Produces: `public struct FontSpec: Sendable, Hashable, Codable { var style: FontSpec.Style; var bold: Bool; var italic: Bool; var monospaced: Bool; static let body: FontSpec }` with `Style: String, CaseIterable — body, callout, title, title2, title3, headline, subheadline, footnote`; `public enum FontSpecAttribute: CodableAttributedStringKey` (`name = "com.connie.adf.fontSpec"`); `AttributeScopes.ADFAttributes` scope + dynamic-lookup subscript.

- [ ] **Step 1: Write the failing test**

`Tests/ADFPreparationTests/FontSpecTests.swift`:

```swift
import Foundation
import SwiftUI
import Testing
import ADFPreparation

@Suite("FontSpec attribute")
struct FontSpecTests {
    @Test func attributeRoundTripsThroughAttributedString() {
        var text = AttributedString("hello")
        let spec = FontSpec(style: .title2, bold: true, italic: false, monospaced: false)
        text[FontSpecAttribute.self] = spec
        #expect(text.runs.count == 1)
        #expect(text.runs.first?[FontSpecAttribute.self] == spec)  // explicit subscript — reliable regardless of dynamic-lookup wiring
    }

    @Test func specIsCodableForAttributeArchiving() throws {
        let spec = FontSpec(style: .footnote, bold: false, italic: true, monospaced: true)
        let data = try JSONEncoder().encode(spec)
        #expect(try JSONDecoder().decode(FontSpec.self, from: data) == spec)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter FontSpecTests` → FAIL: `cannot find 'FontSpec'`.

- [ ] **Step 3: Implement** — `Sources/ADFPreparation/FontSpec.swift`:

```swift
import Foundation
import SwiftUI

/// Semantic, size-independent description of a run's font — the dual-scope
/// twin of the SwiftUI `Font` baked by `InlineComposer`. Resolved to a
/// concrete platform font at the view layer per Dynamic Type size, so
/// nothing size-dependent is baked at preparation time (ADR §19).
public struct FontSpec: Sendable, Hashable, Codable {
    public enum Style: String, Sendable, Hashable, Codable, CaseIterable {
        case body, callout, title, title2, title3, headline, subheadline, footnote
    }

    public var style: Style
    public var bold: Bool
    public var italic: Bool
    public var monospaced: Bool

    public init(style: Style = .body, bold: Bool = false, italic: Bool = false, monospaced: Bool = false) {
        self.style = style
        self.bold = bold
        self.italic = italic
        self.monospaced = monospaced
    }

    public static let body = FontSpec()
}

/// Attributed-string key carrying the `FontSpec` for each styled run.
public enum FontSpecAttribute: CodableAttributedStringKey {
    public typealias Value = FontSpec
    public static let name = "com.connie.adf.fontSpec"
}

public extension AttributeScopes {
    /// ADF's attribute scope: the dual-scope font spec plus the SwiftUI and
    /// Foundation scopes the composer already writes.
    struct ADFAttributes: AttributeScope {
        public let fontSpec: FontSpecAttribute
        public let swiftUI: SwiftUIAttributes
        public let foundation: FoundationAttributes
    }

    var adf: ADFAttributes.Type { ADFAttributes.self }
}

public extension AttributeDynamicLookup {
    subscript<T: AttributedStringKey>(
        dynamicMember keyPath: KeyPath<AttributeScopes.ADFAttributes, T>
    ) -> T { self[T.self] }
}
```

- [ ] **Step 4: Run to verify pass** — `swift test --filter FontSpecTests` → 2 passed. Also `swift test` → full suite still green.

- [ ] **Step 5: Commit** — `git add Sources/ADFPreparation/FontSpec.swift Tests/ADFPreparationTests/FontSpecTests.swift && git commit -m "feat: FontSpec dual-scope font attribute"`

---

### Task 3: `InlineComposer` emits `FontSpec` on every run

**Files:**
- Modify: `Sources/ADFPreparation/InlineComposer.swift` (`compose(_:baseFont:)` → add `baseSpec:`; `attributedRun`; `placeholderRun`)
- Modify: `Sources/ADFPreparation/ADFTheme.swift` (add `headingSpec(_:)`)
- Modify: `Sources/ADFPreparation/DocumentPreparer.swift:100-104` (pass heading spec), `:116-123` (code blocks get the spec)
- Test: `Tests/ADFPreparationTests/FontSpecTests.swift` (extend)

**Interfaces:**
- Consumes: `FontSpec`, `FontSpecAttribute` (Task 2).
- Produces: `compose(_ inline: [ADFNode], baseFont: Font, baseSpec: FontSpec) -> [InlineSegment]` (the no-arg overload passes `theme.body`/`.body`); `ADFTheme.headingSpec(_ level: Int) -> FontSpec`; every `.text` run carries `FontSpecAttribute`; code-block strings carry `FontSpec(monospaced: true)`.

- [ ] **Step 1: Extend the failing test**

Append to `FontSpecTests` (uses the same fixture-parsing helper style as `InlineComposerTests` — open `Tests/ADFPreparationTests/TestHelpers.swift` and reuse its ADF JSON parse helper; the assertions below are the contract):

```swift
    @Test func composerBakesSpecsMirroringFonts() throws {
        let theme = ADFTheme.default
        let composer = InlineComposer(theme: theme)
        let nodes = try inlineNodes(json: """
        [{"type":"text","text":"plain "},
         {"type":"text","text":"bold","marks":[{"type":"strong"}]},
         {"type":"text","text":"code","marks":[{"type":"code"}]},
         {"type":"text","text":"small","marks":[{"type":"fontSize","attrs":{"size":"small"}}]},
         {"type":"text","text":"sup","marks":[{"type":"subsup","attrs":{"type":"sup"}}]}]
        """)
        let segments = composer.compose(nodes)
        guard case .text(let text) = try #require(segments.first) else {
            Issue.record("expected one merged text segment"); return
        }
        let specs = text.runs.map { $0[FontSpecAttribute.self] }
        #expect(specs[0] == FontSpec.body)
        #expect(specs[1] == FontSpec(style: .body, bold: true))
        #expect(specs[2] == FontSpec(style: .body, monospaced: true))
        #expect(specs[3] == FontSpec(style: .subheadline))
        #expect(specs[4] == FontSpec(style: .footnote))
    }

    @Test func headingSpecsMatchHeadingFonts() {
        let theme = ADFTheme.default
        #expect(theme.headingSpec(1) == FontSpec(style: .title, bold: true))
        #expect(theme.headingSpec(4) == FontSpec(style: .headline))
        #expect(theme.headingSpec(9) == FontSpec(style: .footnote, bold: true))
    }
```

(`inlineNodes(json:)`: wrap the array in `{"type":"doc","version":1,"content":[{"type":"paragraph","content": <array>}]}`, parse with `ADFParser`, return the paragraph's children — mirror `InlineComposerTests.inlineContent(of:)`.)

- [ ] **Step 2: Run to verify failure** — `swift test --filter FontSpecTests` → FAIL (`adf.fontSpec` nil / `headingSpec` missing).

- [ ] **Step 3: Implement**

`ADFTheme.swift`, after `headingFont`:

```swift
    /// Dual-scope twin of `headingFont(_:)` — must stay in lockstep with it.
    public func headingSpec(_ level: Int) -> FontSpec {
        switch min(max(level, 1), 6) {
        case 1: return FontSpec(style: .title, bold: true)
        case 2: return FontSpec(style: .title2, bold: true)
        case 3: return FontSpec(style: .title3, bold: true)
        case 4: return FontSpec(style: .headline)
        case 5: return FontSpec(style: .subheadline, bold: true)
        default: return FontSpec(style: .footnote, bold: true)
        }
    }
```

`InlineComposer.swift`:
- `compose(_ inline:)` body → `compose(inline, baseFont: theme.body, baseSpec: .body)`.
- `compose(_ inline:, baseFont:)` signature → `public func compose(_ inline: [ADFNode], baseFont: Font, baseSpec: FontSpec = .body) -> [InlineSegment]`; thread `baseSpec` into every `attributedRun(...)`/`placeholderRun(...)` call inside it.
- `attributedRun(_:marks:baseFont:)` → add `baseSpec: FontSpec` parameter; after the existing font selection block, mirror it:

```swift
        var spec: FontSpec
        if isSup != nil {
            spec = FontSpec(style: .footnote, monospaced: code)
        } else if code {
            spec = FontSpec(style: .body, monospaced: true)
        } else if small {
            spec = FontSpec(style: .subheadline)
        } else {
            spec = baseSpec
        }
        if bold { spec.bold = true }
        if italic { spec.italic = true }
        run[FontSpecAttribute.self] = spec
```

- `placeholderRun(_:baseFont:)` → add `baseSpec: FontSpec`; set `run[FontSpecAttribute.self] = { var s = baseSpec; s.italic = true; return s }()`.
- `plainAttributed` fallback call: pass `baseSpec: .body`.

`DocumentPreparer.swift:104`: `composer.compose(content, baseFont: font, baseSpec: theme.headingSpec(level))`. At the code-block site (`:116-123`), after the existing SwiftUI code-font application, also set `attributed[FontSpecAttribute.self] = FontSpec(monospaced: true)` over the whole string.

- [ ] **Step 4: Run tests** — `swift test` → full suite green (existing InlineComposer tests must not break: the new attribute doesn't disturb SwiftUI attributes; run-merging still merges only runs with identical attributes — adjacent same-mark runs carry the same spec, so merge behavior is unchanged).

- [ ] **Step 5: Commit** — `git commit -am "feat: InlineComposer bakes dual-scope FontSpec on every run"`

---

### Task 4: `FontSpecResolver` (platform-agnostic, memoized)

**Files:**
- Create: `Sources/ADFRendering/TextKit2/FontSpecResolver.swift`
- Test: `Tests/ADFRenderingTests/FontSpecResolverTests.swift`

**Interfaces:**
- Consumes: `FontSpec` (Task 2).
- Produces: `public typealias ADFPlatformFont` (UIFont/NSFont); `@MainActor public final class FontSpecResolver { static let shared; func font(for spec: FontSpec, categoryRawValue: String) -> ADFPlatformFont }` — on iOS `categoryRawValue` is a `UIContentSizeCategory.rawValue` honored via `UITraitCollection(preferredContentSizeCategory:)`; on macOS it is ignored (bare `swift test` runs at one size, documented). Also `public extension UIContentSizeCategory { init(_ size: DynamicTypeSize) }` (iOS only, exhaustive hand switch, `@unknown default: .large`).

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import SwiftUI
import Testing
import ADFPreparation
@testable import ADFRendering

@Suite("FontSpecResolver") @MainActor
struct FontSpecResolverTests {
    @Test func semanticStylesResolveDistinctly() {
        let r = FontSpecResolver.shared
        let body = r.font(for: .body, categoryRawValue: "UICTContentSizeCategoryL")
        let title = r.font(for: FontSpec(style: .title, bold: true), categoryRawValue: "UICTContentSizeCategoryL")
        #expect(title.pointSize > body.pointSize)
    }

    @Test func boldAndItalicApplyDescriptorTraits() {
        let r = FontSpecResolver.shared
        let bold = r.font(for: FontSpec(bold: true), categoryRawValue: "UICTContentSizeCategoryL")
        #expect(fontTraitsContainBold(bold))   // helper below per platform
    }

    @Test func monospacedUsesMonospacedSystemFont() {
        let r = FontSpecResolver.shared
        let mono = r.font(for: FontSpec(monospaced: true), categoryRawValue: "UICTContentSizeCategoryL")
        #expect(fontIsFixedPitch(mono))
    }

    @Test func resolutionIsMemoized() {
        let r = FontSpecResolver.shared
        let a = r.font(for: .body, categoryRawValue: "UICTContentSizeCategoryL")
        let b = r.font(for: .body, categoryRawValue: "UICTContentSizeCategoryL")
        #expect(a === b)
    }
}
```

with `fontTraitsContainBold`/`fontIsFixedPitch` helpers reading `fontDescriptor.symbolicTraits` under `#if canImport(UIKit)` / `NSFontDescriptor` otherwise.

- [ ] **Step 2: Run to verify failure** — `swift test --filter FontSpecResolverTests` → FAIL.

- [ ] **Step 3: Implement**

```swift
import Foundation
import SwiftUI
import ADFPreparation
#if canImport(UIKit)
import UIKit
public typealias ADFPlatformFont = UIFont
#elseif canImport(AppKit)
import AppKit
public typealias ADFPlatformFont = NSFont
#endif

/// Resolves semantic `FontSpec`s to concrete platform fonts.
///
/// Resolution goes through `preferredFont(forTextStyle:)` — NEVER
/// `UIFontMetrics` scaling of a base point size, which follows the
/// `@ScaledMetric` curve and diverges from semantic fonts across the
/// accessibility range (measured 37pt vs 40pt at AX3). On iOS the category
/// comes from the SwiftUI environment (per-document §19 shifts included);
/// trait-argument-less calls are forbidden in this layer.
@MainActor
public final class FontSpecResolver {
    public static let shared = FontSpecResolver()
    private struct Key: Hashable { let spec: FontSpec; let category: String }
    private var cache: [Key: ADFPlatformFont] = [:]

    public func font(for spec: FontSpec, categoryRawValue: String) -> ADFPlatformFont {
        let key = Key(spec: spec, category: categoryRawValue)
        if let hit = cache[key] { return hit }
        let resolved = resolve(spec, categoryRawValue: categoryRawValue)
        cache[key] = resolved
        return resolved
    }

    #if canImport(UIKit)
    private func resolve(_ spec: FontSpec, categoryRawValue: String) -> UIFont {
        let traits = UITraitCollection(
            preferredContentSizeCategory: UIContentSizeCategory(rawValue: categoryRawValue))
        let base = UIFont.preferredFont(forTextStyle: spec.style.uiTextStyle, compatibleWith: traits)
        var font = base
        if spec.monospaced {
            font = .monospacedSystemFont(ofSize: base.pointSize, weight: spec.bold ? .semibold : .regular)
        }
        var symbolic = font.fontDescriptor.symbolicTraits
        if spec.bold, !spec.monospaced { symbolic.insert(.traitBold) }
        if spec.italic { symbolic.insert(.traitItalic) }
        if let descriptor = font.fontDescriptor.withSymbolicTraits(symbolic) {
            font = UIFont(descriptor: descriptor, size: 0)
        }
        return font
    }
    #elseif canImport(AppKit)
    private func resolve(_ spec: FontSpec, categoryRawValue _: String) -> NSFont {
        // macOS: single-size resolution — `swift test` exercises mapping and
        // memoization; category behavior is iOS-gate territory.
        let base = NSFont.preferredFont(forTextStyle: spec.style.nsTextStyle)
        var font = base
        if spec.monospaced {
            font = .monospacedSystemFont(ofSize: base.pointSize, weight: spec.bold ? .semibold : .regular)
        }
        var traits: NSFontDescriptor.SymbolicTraits = font.fontDescriptor.symbolicTraits
        if spec.bold, !spec.monospaced { traits.insert(.bold) }
        if spec.italic { traits.insert(.italic) }
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        font = NSFont(descriptor: descriptor, size: 0) ?? font
        return font
    }
    #endif
}

extension FontSpec.Style {
    #if canImport(UIKit)
    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .body: .body
        case .callout: .callout
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .footnote: .footnote
        }
    }
    #elseif canImport(AppKit)
    var nsTextStyle: NSFont.TextStyle {
        switch self {
        case .body: .body
        case .callout: .callout
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .footnote: .footnote
        }
    }
    #endif
}

#if canImport(UIKit)
public extension UIContentSizeCategory {
    /// Exhaustive bridge from the SwiftUI environment value — the ONLY legal
    /// trait source in the TK2 layer (per-document §19 shifts ride it).
    init(_ size: DynamicTypeSize) {
        switch size {
        case .xSmall: self = .extraSmall
        case .small: self = .small
        case .medium: self = .medium
        case .large: self = .large
        case .xLarge: self = .extraLarge
        case .xxLarge: self = .extraExtraLarge
        case .xxxLarge: self = .extraExtraExtraLarge
        case .accessibility1: self = .accessibilityMedium
        case .accessibility2: self = .accessibilityLarge
        case .accessibility3: self = .accessibilityExtraLarge
        case .accessibility4: self = .accessibilityExtraExtraLarge
        case .accessibility5: self = .accessibilityExtraExtraExtraLarge
        @unknown default: self = .large
        }
    }
}
#endif
```

- [ ] **Step 4: Run tests** — `swift test --filter FontSpecResolverTests` → 4 passed; full suite green.
- [ ] **Step 5: Commit** — `git add Sources/ADFRendering/TextKit2 Tests/ADFRenderingTests/FontSpecResolverTests.swift && git commit -m "feat: platform-agnostic memoized FontSpecResolver"`

---

### Task 5: `TextRowContent` — segment → NSAttributedString conversion + offset tables

**Files:**
- Create: `Sources/ADFRendering/TextKit2/TextRowContent.swift`
- Test: `Tests/ADFRenderingTests/TextRowContentTests.swift`

**Interfaces:**
- Consumes: `FontSpecResolver.font(for:categoryRawValue:)` (Task 4), `InlineSegment`.
- Produces:

```swift
public struct TextRowContent {
    public let attributed: NSAttributedString
    public let segmentUTF16Starts: [Int]     // one entry per input segment
    public let segmentStrings: [String]      // plain text per segment ("" for atoms in phase 2)
    @MainActor public static func make(
        segments: [InlineSegment],
        categoryRawValue: String,
        alignment: NSTextAlignment,
        baselineScale: CGFloat,
        rightToLeft: Bool
    ) -> TextRowContent
    public static func utf16Range(charRange: Range<Int>, inSegment index: Int, of content: TextRowContent) -> NSRange
}
```

- [ ] **Step 1: Write the failing tests** — key cases:

```swift
import Foundation
import SwiftUI
import Testing
import ADFPreparation
@testable import ADFRendering

@Suite("TextRowContent") @MainActor
struct TextRowContentTests {
    private func textSegment(_ s: String, spec: FontSpec = .body) -> InlineSegment {
        var t = AttributedString(s)
        t[FontSpecAttribute.self] = spec
        return .text(t)
    }

    @Test func fontsResolvePerRunSpec() {
        let content = TextRowContent.make(
            segments: [textSegment("plain"), textSegment("big", spec: FontSpec(style: .title, bold: true))],
            categoryRawValue: "UICTContentSizeCategoryL",
            alignment: .natural, baselineScale: 1, rightToLeft: false)
        var fonts: [ADFPlatformFont] = []
        content.attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: content.attributed.length)) { value, _, _ in
            if let f = value as? ADFPlatformFont { fonts.append(f) }
        }
        #expect(fonts.count == 2)
        #expect(fonts[1].pointSize > fonts[0].pointSize)
    }

    @Test func utf16StartsAccountForEmoji() {
        let content = TextRowContent.make(
            segments: [textSegment("a😄b"), textSegment("tail")],
            categoryRawValue: "UICTContentSizeCategoryL",
            alignment: .natural, baselineScale: 1, rightToLeft: false)
        #expect(content.segmentUTF16Starts == [0, 4])     // 😄 is 2 UTF-16 units
    }

    @Test func charRangeToUTF16RangeCrossesEmoji() {
        let content = TextRowContent.make(
            segments: [textSegment("a😄bc")],
            categoryRawValue: "UICTContentSizeCategoryL",
            alignment: .natural, baselineScale: 1, rightToLeft: false)
        // Characters [2..4) = "bc" → UTF-16 [3..5)
        let r = TextRowContent.utf16Range(charRange: 2..<4, inSegment: 0, of: content)
        #expect(r == NSRange(location: 3, length: 2))
    }

    @Test func underlineStrikeBaselineAndLinkConvert() throws {
        var t = AttributedString("styled")
        t[FontSpecAttribute.self] = .body
        t[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] = .single
        t[AttributeScopes.SwiftUIAttributes.StrikethroughStyleAttribute.self] = .single
        t[AttributeScopes.SwiftUIAttributes.BaselineOffsetAttribute.self] = 5.1
        t[AttributeScopes.FoundationAttributes.LinkAttribute.self] = URL(string: "https://x.test")!
        let content = TextRowContent.make(
            segments: [.text(t)], categoryRawValue: "UICTContentSizeCategoryL",
            alignment: .natural, baselineScale: 2, rightToLeft: false)
        let attrs = content.attributed.attributes(at: 0, effectiveRange: nil)
        #expect(attrs[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue)
        #expect(attrs[.strikethroughStyle] as? Int == NSUnderlineStyle.single.rawValue)
        #expect(attrs[.baselineOffset] as? CGFloat == 10.2)   // scaled by baselineScale
        #expect(attrs[.link] as? URL == URL(string: "https://x.test"))
    }
}
```

- [ ] **Step 2: Run to verify failure** — FAIL: `TextRowContent` not found.

- [ ] **Step 3: Implement** — conversion walks each `.text` segment's `runs`; per run: resolve `run.adf.fontSpec ?? .body` via `FontSpecResolver`; map SwiftUI `ForegroundColorAttribute`/`BackgroundColorAttribute` via `UIColor(_: Color)` / `NSColor(_: Color)` (no attribute → omit `.foregroundColor`; the view sets `.label`/`.labelColor` as a whole-string default first so unstyled text stays dynamic); underline/strike `.single → NSUnderlineStyle.single.rawValue`; `BaselineOffsetAttribute × baselineScale → .baselineOffset`; Foundation link → `.link` **plus** `.foregroundColor: UIColor.tintColor` (SwiftUI Text tints links; custom drawing does not). `.atom` segments in phase 2: append nothing, record `segmentStrings.append("")` and the running start (Task 10 replaces this with attachments). One `NSMutableParagraphStyle` over the whole string: `alignment` as passed (caller maps `TextAlignment?` + `layoutDirection`: nil → `.natural`; `.center` → `.center`; `.trailing` → rightToLeft ? `.left` : `.right`), `baseWritingDirection = .natural`. `utf16Range` walks `segmentStrings[index]` by `Character`, summing `String.UTF16View` counts — O(segment length), used only by search/selection queries, never during idle scroll.

- [ ] **Step 4: Run tests** — `swift test --filter TextRowContentTests` → 4 passed; full suite green.
- [ ] **Step 5: Commit** — `git commit -am "feat: TextRowContent conversion with dual-scope fonts and UTF-16 offset tables"`

---

### Task 6: `TextRowLayout` — deterministic TK2 measurement core

**Files:**
- Create: `Sources/ADFRendering/TextKit2/TextRowLayout.swift`
- Test: `Tests/ADFRenderingTests/TextRowLayoutTests.swift`

**Interfaces:**
- Consumes: `TextRowContent.attributed`.
- Produces: `public final class TextRowLayout { let contentStorage: NSTextContentStorage; let layoutManager: NSTextLayoutManager; let container: NSTextContainer; func setAttributedString(_: NSAttributedString); func measure(width: CGFloat, displayScale: CGFloat) -> CGSize }` — full `ensureLayout` (never viewport-estimated), height pixel-rounded up at `displayScale`, memoized per width, `lineFragmentPadding = 0`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import ADFRendering
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@Suite("TextRowLayout") @MainActor
struct TextRowLayoutTests {
    private func layout(_ text: String, size: CGFloat = 17) -> TextRowLayout {
        let l = TextRowLayout()
        l.setAttributedString(NSAttributedString(
            string: text,
            attributes: [.font: ADFPlatformFont.systemFont(ofSize: size)]))
        return l
    }

    @Test func sameInputSameWidthMeasuresIdentically() {
        let text = String(repeating: "deterministic layout is the spacer-memo contract ", count: 40)
        let a = layout(text).measure(width: 320, displayScale: 3)
        let b = layout(text).measure(width: 320, displayScale: 3)
        #expect(a == b)
        // And re-measuring the SAME instance after another width round-trips exactly:
        let l = layout(text)
        let first = l.measure(width: 320, displayScale: 3)
        _ = l.measure(width: 640, displayScale: 3)
        #expect(l.measure(width: 320, displayScale: 3) == first)
    }

    @Test func narrowerWidthIsTaller() {
        let text = String(repeating: "reflowing text scales like h*w0/w1 ", count: 40)
        let wide = layout(text).measure(width: 600, displayScale: 3)
        let narrow = layout(text).measure(width: 300, displayScale: 3)
        #expect(narrow.height > wide.height)
    }

    @Test func heightIsPixelAlignedAtScale() {
        let size = layout("one line").measure(width: 320, displayScale: 3)
        let remainder = (size.height * 3).truncatingRemainder(dividingBy: 1)
        #expect(abs(remainder) < 0.0001 || abs(remainder - 1) < 0.0001)  // fp-tolerant pixel check
    }

    @Test func unboundedWidthYieldsNaturalWidth() {   // code-block h-scroll case
        let size = layout("short").measure(width: .greatestFiniteMagnitude, displayScale: 3)
        #expect(size.width < 200)
    }
}
```

- [ ] **Step 2: Run to verify failure** — FAIL.

- [ ] **Step 3: Implement**

```swift
import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// One row's TextKit 2 stack. Measurement is FULL layout (`ensureLayout` to
/// the document end) so a given (text, width) always yields the same height —
/// the CollapsedRowHeight exact-replay contract. Viewport-estimated layout is
/// forbidden here: an estimate-then-settle height double-commits row geometry
/// and feeds the §16 livelock loop.
@MainActor
public final class TextRowLayout {
    public let contentStorage = NSTextContentStorage()
    public let layoutManager = NSTextLayoutManager()
    public let container = NSTextContainer(size: CGSize(width: 0, height: .greatestFiniteMagnitude))
    private var lastWidth: CGFloat?
    private var lastSize: CGSize?

    public init() {
        container.lineFragmentPadding = 0
        contentStorage.addTextLayoutManager(layoutManager)
        layoutManager.textContainer = container
    }

    public func setAttributedString(_ attributed: NSAttributedString) {
        contentStorage.attributedString = attributed
        lastWidth = nil
        lastSize = nil
    }

    public func measure(width: CGFloat, displayScale: CGFloat) -> CGSize {
        if lastWidth == width, let lastSize { return lastSize }
        container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let bounds = layoutManager.usageBoundsForTextContainer
        let height = (bounds.maxY * displayScale).rounded(.up) / displayScale
        let naturalWidth = width.isFinite ? width : (bounds.maxX * displayScale).rounded(.up) / displayScale
        let size = CGSize(width: naturalWidth, height: height)
        lastWidth = width
        lastSize = size
        return size
    }
}
```

- [ ] **Step 4: Run tests** — `swift test --filter TextRowLayoutTests` → 4 passed; full suite green.
- [ ] **Step 5: Commit** — `git commit -am "feat: deterministic TextRowLayout measurement core"`

---

### Task 7: `TextKit2RowView` + toggle wiring + Demo smoke

**Files:**
- Create: `Sources/ADFRendering/TextKit2/TextKit2RowView.swift`
- Create: `Sources/ADFRendering/TextKit2/TextKit2Flags.swift`
- Modify: `Sources/ADFRendering/Inline/SegmentedTextView.swift` (toggle in the merged-text arm; `blockAlignment` param)
- Modify: `Sources/ADFRendering/Blocks/RichTextBlockView.swift:15` (pass alignment)
- Modify: `Sources/ADFRendering/Blocks/CodeBlockView.swift:42-46` (toggle)
- Modify: `Sources/ADFRendering/Blocks/TableSliceView.swift:343-347` (cell environment flag)
- Modify: `Sources/ADFRendering/Environment.swift` (add `adfInTableCell` key)
- Modify: `Demo/ADFReader/ADFReaderApp.swift` (document `-textkit2` in the launch-arg comment)

**Interfaces:**
- Consumes: `TextRowContent`, `TextRowLayout`, `FontSpecResolver`, `UIContentSizeCategory(DynamicTypeSize)`.
- Produces: `TextKit2Flags.enabled` / `.cellsEnabled` (static lets from ProcessInfo); `TextKit2RowView(segments:blockAlignment:)` (iOS-only `UIViewRepresentable`); `SegmentedTextView(segments:ownerID:blockAlignment:)`.

- [ ] **Step 1: `TextKit2Flags.swift`**

```swift
import Foundation

/// Launch-arg toggles, read ONCE — they never flip at runtime, so a
/// constant-Bool `if/else` at a leaf keeps stable view identity (§18's
/// poison is only buildLimitedAvailability/AnyView, never plain branches
/// on launch constants).
public enum TextKit2Flags {
    /// `-textkit2`: render text leaves with TextKit 2 (assessment A/B).
    public static let enabled = ProcessInfo.processInfo.arguments.contains("-textkit2")
    /// `-textkit2NoCells`: exclude table cells (giant-table gate fallback).
    public static let cellsEnabled = !ProcessInfo.processInfo.arguments.contains("-textkit2NoCells")
}
```

- [ ] **Step 2: `TextKit2RowView.swift`** (all `#if os(iOS)`)

```swift
#if os(iOS)
import SwiftUI
import UIKit
import ADFPreparation

/// One text row rendered by TextKit 2. Sizing contract (§16): synchronous,
/// deterministic, memoized per width; the view NEVER self-invalidates —
/// SwiftUI's proposal is the only sizing authority.
struct TextKit2RowView: UIViewRepresentable {
    let segments: [InlineSegment]
    var blockAlignment: TextAlignment? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.displayScale) private var displayScale

    func makeUIView(context: Context) -> TextKit2RowUIView { TextKit2RowUIView() }

    func updateUIView(_ view: TextKit2RowUIView, context: Context) {
        view.apply(TextKit2RowUIView.Inputs(
            segments: segments,
            categoryRawValue: UIContentSizeCategory(dynamicTypeSize).rawValue,
            alignment: nsAlignment,
            rightToLeft: layoutDirection == .rightToLeft,
            displayScale: displayScale))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TextKit2RowUIView, context: Context) -> CGSize? {
        uiView.measuredSize(forWidth: proposal.width)
    }

    private var nsAlignment: NSTextAlignment {
        switch blockAlignment {
        case .center: .center
        case .trailing: layoutDirection == .rightToLeft ? .left : .right
        default: .natural
        }
    }

    /// First-line ascent for enclosing `.firstTextBaseline` stacks (list
    /// markers, panel icons). Pure function of the first run's resolved font
    /// — never measured layout, so no geometry feedback (§16).
    static func firstBaseline(of segments: [InlineSegment], categoryRawValue: String) -> CGFloat {
        for segment in segments {
            if case .text(let text) = segment {
                let spec = text.runs.first?.adf.fontSpec ?? .body
                return FontSpecResolver.shared.font(for: spec, categoryRawValue: categoryRawValue).ascender
            }
        }
        return 0
    }
}

final class TextKit2RowUIView: UIView {
    struct Inputs: Equatable {
        let segments: [InlineSegment]
        let categoryRawValue: String
        let alignment: NSTextAlignment
        let rightToLeft: Bool
        let displayScale: CGFloat
    }

    private let layout = TextRowLayout()
    private var inputs: Inputs?
    private(set) var content: TextRowContent?
    private var drawnWidth: CGFloat = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    func apply(_ new: Inputs) {
        guard new != inputs else { return }
        inputs = new
        let scale = UIFontMetrics(forTextStyle: .body).scaledValue(
            for: 1,
            compatibleWith: UITraitCollection(preferredContentSizeCategory:
                UIContentSizeCategory(rawValue: new.categoryRawValue)))
        // ^ sole legal UIFontMetrics use: mirroring the @ScaledMetric curve
        //   for baked baseline offsets, matching SegmentedTextView.typeScale.
        let made = TextRowContent.make(
            segments: new.segments,
            categoryRawValue: new.categoryRawValue,
            alignment: new.alignment,
            baselineScale: scale,
            rightToLeft: new.rightToLeft)
        content = made
        layout.setAttributedString(made.attributed)
        setNeedsDisplay()
    }

    func measuredSize(forWidth width: CGFloat?) -> CGSize {
        let w = width ?? bounds.width
        guard w > 0, inputs != nil else { return .zero }
        return layout.measure(width: w, displayScale: inputs?.displayScale ?? 3)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.width != drawnWidth else { return }
        drawnWidth = bounds.width
        _ = layout.measure(width: bounds.width, displayScale: inputs?.displayScale ?? 3)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        layout.layoutManager.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
            fragment.draw(at: fragment.layoutFragmentFrame.origin, in: ctx)
            return true
        }
    }
}
#endif
```

Also in `TextRowContent.make`, set a whole-string default `.foregroundColor` of `UIColor.label` (`NSColor.labelColor`) before per-run colors so unstyled text adapts to dark mode at draw time.

- [ ] **Step 3: Wire `SegmentedTextView`**

Add `var blockAlignment: TextAlignment? = nil` after `ownerID`, and `@Environment(\.dynamicTypeSize) private var dynamicTypeSize` + `@Environment(\.adfInTableCell) private var inTableCell`. Replace the merged-text arm:

```swift
            if let merged = Self.mergedText(displayed) {
                #if os(iOS)
                if TextKit2Flags.enabled && (!inTableCell || TextKit2Flags.cellsEnabled) {
                    TextKit2RowView(segments: [.text(merged)], blockAlignment: blockAlignment)
                        .alignmentGuide(.firstTextBaseline) { _ in
                            TextKit2RowView.firstBaseline(
                                of: displayed,
                                categoryRawValue: UIContentSizeCategory(dynamicTypeSize).rawValue)
                        }
                } else {
                    Text(Self.scalingBaselineOffsets(in: merged, by: typeScale))
                }
                #else
                Text(Self.scalingBaselineOffsets(in: merged, by: typeScale))
                #endif
            } else {
```

(The atom arm stays SwiftUI in phase 2 — Task 10 extends the toggle to it. Both branches of the constant Bool have stable types; no AnyView, no `#available`.)

`Environment.swift`: add

```swift
private struct ADFInTableCellKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var adfInTableCell: Bool {
        get { self[ADFInTableCellKey.self] }
        set { self[ADFInTableCellKey.self] = newValue }
    }
}
```

`TableSliceView.swift:343-347` (the cell-content builder that recurses into `BlockView`): append `.environment(\.adfInTableCell, true)` to the cell's content container (one modifier at the cell level, not per row — locate the exact builder with `grep -n "BlockView" Sources/ADFRendering/Blocks/TableSliceView.swift`).

`RichTextBlockView.swift:15`: `SegmentedTextView(segments: segments, ownerID: ownerID, blockAlignment: textAlignment)`.

`CodeBlockView.swift:42-46`:

```swift
            ScrollView(.horizontal, showsIndicators: false) {
                #if os(iOS)
                if TextKit2Flags.enabled {
                    TextKit2RowView(segments: [.text(displayedCode)])
                        .padding(theme.spacing * 1.5)
                } else {
                    Text(displayedCode)
                        .textSelection(.enabled)
                        .padding(theme.spacing * 1.5)
                }
                #else
                Text(displayedCode)
                    .textSelection(.enabled)
                    .padding(theme.spacing * 1.5)
                #endif
            }
```

- [ ] **Step 4: Full test suite + macOS build** — `swift test` → green (TK2 view is iOS-only; core compiled and tested).

- [ ] **Step 5: Demo smoke on kitchen-sink**

Build per the reference, then:

```bash
xcrun simctl launch $D com.connie.adfreader -fixture kitchen-sink -textkit2
xcrun simctl io $D screenshot /tmp/tk2-kitchen.png
xcrun simctl launch $D com.connie.adfreader -fixture kitchen-sink
xcrun simctl io $D screenshot /tmp/swiftui-kitchen.png
```

Expected: paragraphs/headings/code/lists render with TK2 (atom paragraphs still SwiftUI); side-by-side inspection shows same text at closely matching positions (pixel-perfection is Task 13's job; gross breakage — missing text, wrong sizes, clipped rows — fails this step).

- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: TextKit2RowView behind -textkit2 in SegmentedTextView and CodeBlockView"`

---

### Task 8: Phase-2 perf gates + checkpoint

**Files:**
- Modify: `docs/TextKit2-Port-Assessment.md` (record all numbers)

- [ ] **Step 1: Fresh same-build baselines (toggle OFF), then toggle ON — autoscroll**

```bash
for args in "" "-textkit2"; do
  xcrun simctl launch --console-pty $D com.connie.adfreader \
    -fixture stress-5k -autoscroll $args | grep SCROLL_METRICS
done
```

Record both. Gate: ON ≤ 2× OFF (spec kill criterion), target: noise-equivalent.

- [ ] **Step 2: Giant-table autoscroll, both branches, plus `-textkit2 -textkit2NoCells`**

Same command with `-fixture giant-table`. If cells blow the gate but NoCells passes, record the exclusion decision (spec §6).

- [ ] **Step 3: Fling burst + CPU settle (the gate autoscroll misses)**

```bash
xcrun simctl launch $D com.connie.adfreader -fixture stress-5k -textkit2
for i in $(seq 1 12); do axe swipe --start-x 220 --start-y 800 --end-x 220 --end-y 120 --duration 0.08 --udid $D; done
sleep 3
top -l 2 -pid $(pgrep -f "ADFReader.app/ADFReader" | head -1) | tail -1
```

Expected: %CPU ~0.0 in the second sample. Any sustained CPU = livelock = stop and diagnose before proceeding.

- [ ] **Step 4: First-chunk + rotation + §19 gauntlet**

- First chunk: launch `-fixture kitchen-sink -textkit2`, confirm first-content log < 150 ms (record actual).
- Rotation: launch stress-5k `-textkit2`, scroll mid-document, then 8× `notifyutil -p com.connie.adfreader.rotate` (AXRaise the right Simulator window first); screenshot before/after — reader keeps its row.
- Type size: `-fixture kitchen-sink -textkit2 -fontSizeStep 3` → text visibly larger AND TK2 rows reflowed (fonts resolve from the shifted environment); mid-scroll size change via the text-size control holds the reader's place.
- Memory: launch `-fixture media-gallery -textkit2`, scroll through, `xcrun simctl spawn $D log` or Xcode memory gauge < 150 MB.

- [ ] **Step 5: Record + checkpoint**

Write all numbers into `docs/TextKit2-Port-Assessment.md` §"Phase 2: rendering cost". Verdict: PROCEED to phase 3, or KILLED (report to user with numbers — spec §10). Commit: `git commit -am "measure: phase-2 TK2 rendering gates"`.

---

## Phase 3 — Fidelity: search, pills, baselines, RTL, parity

### Task 9: Search highlights in the TK2 draw pass

**Files:**
- Modify: `Sources/ADFRendering/TextKit2/TextKit2RowView.swift` (span inputs + background drawing)
- Modify: `Sources/ADFRendering/Inline/SegmentedTextView.swift`, `Sources/ADFRendering/Blocks/CodeBlockView.swift` (pass spans instead of painted strings on the TK2 arm)
- Test: `Tests/ADFRenderingTests/TextRowContentTests.swift` (span→rect range conversion)

**Interfaces:**
- Consumes: `SearchOwnerHighlights` values (`spans`, `currentSpans`: `[SearchHighlightSpan]` with `segmentIndex` + Character `range`), `TextRowContent.utf16Range`.
- Produces: `TextKit2RowUIView.Inputs` gains `spans: [SearchHighlightSpan]`, `currentSpans: [SearchHighlightSpan]`, `dimCurrent: Bool`, `subtleColor: UIColor`, `currentColor: UIColor`, `currentForeground: UIColor?`.

- [ ] **Step 1: Wire span passing.** In `SegmentedTextView`'s TK2 arm, do NOT run `SearchHighlightPainter` (the painted copy is the SwiftUI arm's mechanism); instead pass `segments` (the stored, unpainted array) plus the highlight values read by the existing zero-work gate (`displayedSegments` logic splits: TK2 arm uses raw `segments` + `search.ownerHighlights(for:)` values when active, empty arrays when idle). The idle path still reads exactly one Bool. Same for `CodeBlockView`'s TK2 arm (spans with `segmentIndex == 0`).
- [ ] **Step 2: Draw.** In `draw(_:)` before glyphs: for each span, `utf16Range` → `NSTextRange` (via `contentStorage.location(documentRange.location, offsetBy:)`) → `layoutManager.enumerateTextSegments(in: range, type: .highlight)` → fill rects with subtle/current color (current drawn after subtle so it overwrites); when `currentForeground` is set, re-draw the current match's fragment glyphs clipped to those rects is NOT attempted — instead add `.foregroundColor` via a temporary rendering attribute: `layoutManager.setRenderingAttributes([.foregroundColor: fg], for: range)` before display and remove on change (rendering attributes don't touch the content storage — the conversion stays base-text-only per spec).
- [ ] **Step 3: Arrival flash.** `flashDimmed` already toggles in the wrapper; it reaches the view as `dimCurrent` through `apply(_:)` → input inequality → `setNeedsDisplay` — a redraw, never a relayout (assert: `apply` with only `dimCurrent` changed must skip `TextRowContent.make` — split `Inputs` into `content` vs `paint` sub-structs compared independently).
- [ ] **Step 4: Gates.** `-searchQuery` automation on stress-5k with `-textkit2`: match counts identical to the SwiftUI branch; navigation flashes; fling with a 73k-match query active settles to ~0 CPU. Screenshot subtle/current appearance vs SwiftUI branch.
- [ ] **Step 5: Commit** — `git commit -am "feat: TK2 draw-pass search highlights (base text never repainted)"`

### Task 10: Atom pills as vector-drawn attachments

**Files:**
- Create: `Sources/ADFRendering/TextKit2/AtomAttachment.swift`
- Modify: `Sources/ADFRendering/TextKit2/TextRowContent.swift` (atoms → attachment character)
- Modify: `Sources/ADFRendering/Inline/SegmentedTextView.swift` (extend toggle to the atom arm)
- Test: `Tests/ADFRenderingTests/AtomAttachmentTests.swift`

**Interfaces:**
- Consumes: `InlineAtom`, `AtomFormatting` (`Sources/ADFRendering/Inline/AtomViews.swift:119-127` — make `AtomFormatting` and `ADFStatusColor.tint` internal-visible to this file; they already are, same module), `FontSpecResolver`.
- Produces: `final class AtomAttachment: NSTextAttachment` — sized in `attachmentBounds` from the atom's display text measured at `.callout` weight-medium + scaled padding (mirroring `AtomCapsule`: h-padding 8, v-padding 2, both `@ScaledMetric(relativeTo: .callout)` — reproduce via `UIFontMetrics(forTextStyle: .callout).scaledValue(for:compatibleWith:)`), y-origin = `-(pillHeight - font.ascender)/2`-style baseline centering matching `WrappingInlineLayout`'s rowAscent − itemAscent placement; drawn vector-style via `image(forBounds:textContainer:characterIndex:)` override rendering with `UIGraphicsImageRenderer` **from current traits at draw time** (capsule fill `tint.opacity(0.18)`, text `tint`, per `AtomCapsule`/`AtomChip`/status-uppercase rules; emoji shortName renders `:name:` secondary-colored, no capsule).
- Atom atomicity + geometry belong to phase 4 (selection); this task is rendering only.

- [ ] **Step 1: Write the failing test** — `Tests/ADFRenderingTests/AtomAttachmentTests.swift` (iOS-only behavior compiled out on macOS, so guard the suite):

```swift
#if canImport(UIKit)
import UIKit
import SwiftUI
import Testing
import ADFPreparation
@testable import ADFRendering

@Suite("AtomAttachment") @MainActor
struct AtomAttachmentTests {
    private let large = UIContentSizeCategory.large.rawValue
    private let ax3 = UIContentSizeCategory.accessibilityExtraLarge.rawValue

    @Test func boundsAreDeterministicPerCategory() {
        let a = AtomAttachment(atom: .status(text: "done", color: .green), categoryRawValue: large)
        let b = AtomAttachment(atom: .status(text: "done", color: .green), categoryRawValue: large)
        #expect(a.pillSize == b.pillSize)
    }

    @Test func boundsGrowWithCategory() {
        let small = AtomAttachment(atom: .mention(text: "@Bharath"), categoryRawValue: large)
        let big = AtomAttachment(atom: .mention(text: "@Bharath"), categoryRawValue: ax3)
        #expect(big.pillSize.width > small.pillSize.width)
        #expect(big.pillSize.height > small.pillSize.height)
    }

    @Test func baselineOriginSitsPillOnLineBaseline() {
        let att = AtomAttachment(atom: .date(timestampMS: 1_720_000_000_000), categoryRawValue: large)
        let lineFont = UIFont.preferredFont(forTextStyle: .body)
        let bounds = att.attachmentBounds(
            for: NSTextContainer(), location: NSTextLocationStub(),
            textContainer: nil, proposedLineFragment: .zero, position: .zero)
        // Pill bottom must not hang below the line's descent (rowAscent −
        // itemAscent placement: origin.y ≥ -descent of the pill's text font).
        #expect(bounds.origin.y <= 0)
        #expect(bounds.origin.y >= -lineFont.pointSize)
        #expect(bounds.size == att.pillSize)
    }
}
#endif
```

(`NSTextLocationStub`: trivial `NSObject, NSTextLocation` conformance in the test file returning `.orderedSame` — `attachmentBounds` must not depend on location. If the chosen `attachmentBounds` override signature differs on the installed SDK, use the `attachmentBounds(for:location:textContainer:proposedLineFragment:position:)` TextKit 2 variant and keep the assertions.)

- [ ] **Step 2: Run to verify failure** — build the iOS test target via `xcodebuild test -project Demo/ADFReader.xcodeproj -scheme ADFReader -destination "platform=iOS Simulator,name=iPhone 16"` if package tests don't run iOS-only suites; otherwise `swift test` skips them on macOS — the Demo test scheme is the executable gate here. Expected: FAIL, `AtomAttachment` not found.
- [ ] **Step 3: Implement `AtomAttachment`** — display text/tint per `AtomView`'s rules (`mention → AtomFormatting.mentionText`, tint blue; `status → text.uppercased()`, tint `color.tint`; `date → AtomFormatting.dateText`, tint gray; `inlineCard`/`mediaInline`/`inlineExtension` → chip style with SF Symbol omitted in v1, note in doc; `emoji → ":name:"` secondary, no capsule). `pillSize` = text measured with `.callout` medium at the category (via `FontSpecResolver` + `UIFontMetrics(forTextStyle: .callout).scaledValue` for the 8/2 paddings); `attachmentBounds.origin.y` = `pillTextFont.descender - verticalPadding` (pill text baseline sits on the line baseline, matching `WrappingInlineLayout`'s rowAscent − itemAscent placement); `image(forBounds:...)` renders capsule + text with `UIGraphicsImageRenderer` reading current traits at draw time (dark-mode correct without invalidation).
- [ ] **Step 4: Extend the toggle to the atom arm** — `SegmentedTextView`'s TK2 branch now takes the full `displayed` array (drop the `[.text(merged)]` special case: pass `displayed` always); `TextRowContent.make` emits one attachment character per `.atom` (`NSAttributedString(attachment:)` with the run's surrounding font), records `segmentStrings.append("")` and the running UTF-16 start.
- [ ] **Step 5: Run tests + visual check** — iOS test target green; kitchen-sink screenshot vs SwiftUI branch: pills at matching size/position/baseline (≤1pt drift acceptable, note measured drift). Mention-popover taps and inline-card links still work in the SWIFTUI branch; TK2-branch atom taps are phase-4 hit-testing — record as a known phase-3 gap in the assessment doc.
- [ ] **Step 6: Commit** — `git commit -am "feat: vector-drawn AtomAttachment pills in TK2 rows"`

### Task 11: Baseline parity — lists, panels

**Files:**
- Modify (if needed after measurement): `Sources/ADFRendering/TextKit2/TextKit2RowView.swift` (`firstBaseline`)
- Modify: `docs/TextKit2-Port-Assessment.md`

- [ ] **Step 1:** Launch kitchen-sink both branches at default size and `-fontSizeStep 3`; screenshot list rows (bullet/ordered/task/decision at several depths) and panels.
- [ ] **Step 2:** Overlay-diff marker/icon vertical alignment (the `alignmentGuide` from Task 7 supplies the ascent). Acceptance: markers align with the first text line within 1pt at default size, 2pt at AX sizes; task checkboxes still toggle (tap via axe, state flips).
- [ ] **Step 3:** If drift exceeds tolerance, adjust `firstBaseline` (e.g., account for the paragraph style's line-height multiple) — it must remain a pure function of resolved fonts, never measured layout.
- [ ] **Step 4:** Record + commit.

### Task 12: RTL + AX3 fixtures

**Files:**
- Create: `Fixtures/rtl-mixed.json` (Arabic paragraphs, mixed-Bidi runs, an RTL list, a centered and an end-aligned paragraph — author via the existing fixture pattern; validate with `swift test` fixture-loading if a loader test exists, else by launching)
- Modify: `docs/TextKit2-Port-Assessment.md`

- [ ] **Step 1:** Author the fixture (minimal ADF: 4 paragraphs + 1 bulletList; Arabic text such as "هذا نص عربي للاختبار" with an embedded Latin word).
- [ ] **Step 2:** Launch `-fixture rtl-mixed` both branches, LTR and RTL app locale (`-AppleLanguages (ar)`); screenshots. Acceptance: paragraph alignment sides match between branches in all four combinations.
- [ ] **Step 3:** AX3 wrap parity: `-fixture kitchen-sink -fontSizeStep` at the ladder's AX3-equivalent (see `DynamicTypeStep.swift` table) — compare line counts of three long paragraphs between branches (equal, or note the divergence — the TK2 rendering is now truth, but gross divergence signals a resolver bug per the 37-vs-40pt class).
- [ ] **Step 4:** Record + commit.

### Task 13: Phase-3 gate re-run + parity report

- [ ] **Step 1:** Re-run Task 8's full matrix (autoscroll A/B stress-5k + giant-table, fling settle, first chunk, rotation ×8, §19 mid-scroll, media memory) — pills and search drawing have been added since the phase-2 numbers.
- [ ] **Step 2:** Video: `-fixture youtube -textkit2` (the youtube fixture name per `Sources/ADFYouTube` docs/§20): facade renders, tap → player in identical box, scroll away → facade returns, fling-through over active player, rotation round-trip pixel-identical. Nothing in phases 2–3 touched this path; the gate proves it.
- [ ] **Step 3:** Side-by-side screenshot suite (kitchen-sink, lists, panels, tables, code, RTL; default + AX3; light + dark) committed under `docs/assessment-assets/` with an index in the assessment doc.
- [ ] **Step 4:** Update `docs/TextKit2-Port-Assessment.md` with the complete phase 1–3 verdict. Commit.

### Task 14: Checkpoint + phase 4–5 plan

- [ ] **Step 1:** Report to the user: spike verdict, phase-2/3 numbers vs kill criteria, parity findings, recommendation (proceed to selection engine / adjust / kill).
- [ ] **Step 2:** On PROCEED: write `docs/superpowers/plans/<date>-textkit2-selection-engine.md` covering spec §7 (selection controller on the introspected scroll container per the spike's proven attachment pattern, UTF-16 text model over the search corpus with stored prefix sums, geometry registry + collapsed-row interpolation, epochs + gesture-cancel, expand policy, hit-test-free arbitration, drag autoscroll writing `anchors.topRow`) + spec §10's remaining gates (selection demos, rotate-with-Select-All-then-fling, live-edit-mid-drag, handle-drag autoscroll CPU, selection-session memory soak, pan-table/scrub-code-with-selection, emoji word-select) + final verdict in the assessment doc and issue #5 update. Use the same task structure as this plan; ground every selection task in the spike's recorded constraints.

## Self-review checklist (ran at authoring)

- Spec coverage: §3 → Tasks 2–3; §4 → Tasks 4–7; §5 → Task 10; §6 → Task 7; §8 → Tasks 4–6 (platform-agnostic core tested on macOS); §10 → Tasks 8, 13; §11 steps 1–3 → Tasks 1, 8, 13; §7 + remaining §10 gates → Task 14's follow-up plan (scope note).
- Deviation from spec recorded: list markers stay in the SwiftUI marker column with an `alignmentGuide` ascent (spec §4 "CG-drawn markers") — preserves `TaskMarkerView` checkbox interactivity, which CG drawing would destroy; copy policy (markers excluded) is unchanged. Update the spec's §4 line when Task 11 confirms alignment.
- Type consistency: `FontSpec`/`FontSpecAttribute` (T2) used in T3/T4/T5/T7/T10; `TextRowContent.make(segments:categoryRawValue:alignment:baselineScale:rightToLeft:)` consistent T5/T7; `measure(width:displayScale:)` consistent T6/T7.
