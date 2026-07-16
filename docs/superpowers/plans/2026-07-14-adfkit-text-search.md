# ADFKit Text Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Find-in-page for ADF documents: streamed match counts, next/prev navigation with background highlights, flash-on-arrival, visibility-gated margin scrolling, auto-expanding collapsed expands, and a demo search bar.

**Architecture:** A pure `SearchIndexer`/`SearchMatcher` in ADFPreparation builds `(ownerID, plainText, offset-map)` units off-main; a `@MainActor @Observable ADFDocumentSearch` owned by `ADFDocumentModel` streams scan results and drives the existing `scrollTarget` mechanism (extended with a margin placement); highlights flow to leaf text views through an environment-injected observable and are applied as `BackgroundColorAttribute` edits with a zero-cost early return for unmatched rows.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Swift Testing (`@Suite`/`@Test`/`#expect`/`#require`), SPM. Spec: `docs/superpowers/specs/2026-07-14-adfkit-text-search-design.md`.

## Global Constraints

- Swift 6 strict concurrency everywhere; the demo builds with `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES`. All new cross-actor types must be `Sendable`.
- Package platforms: `.iOS(.v17), .macOS(.v14)`. Anything iOS 18-only (`onScrollVisibilityChange`) must be `#available`-gated with an iOS 17 fallback.
- Perf doctrine (docs/ADF-Renderer-Design.md §8, non-negotiable):
  - Never build/scan `AttributedString`s in a SwiftUI `body` except via the gated zero-work-common-case pattern (`SegmentedTextView.scalingBaselineOffsets` precedent).
  - No O(document) work in `body`; no state observed by `ADFDocumentView.body` that changes per-keystroke/per-scroll.
  - Never read named-coordinate-space geometry inside lazy rows.
  - High-frequency state lives in plain reference types (`ScrollAnchorRegistry` pattern) or is observed only by leaf views (`ScrollTargetConsumer` pattern).
- `RenderBlock.id` values are SwiftUI identity and scroll anchors — never change or re-key them. Highlights are render-time attribute edits only.
- Match semantics: literal substring, options exactly `[.caseInsensitive, .diacriticInsensitive]`, `locale: nil`, non-overlapping (advance past each match).
- Defaults: `scrollMargin = 40` (points), `debounceInterval = .milliseconds(200)`, visibility threshold `0.95`, anchor margin fraction clamped to `0...0.4`.
- v1 documented exclusions from the searchable corpus: card titles, expand titles, extension-placeholder titles, unknown-block labels (all rendered as plain `Text`, not range-highlightable). Atom pills (mentions/status/dates/emoji/cards/attachments) ARE searchable via fallback text and get whole-pill highlights.
- Baseline: `swift test` passes 112 tests in ~0.3s before Task 1. Every task ends green.
- Commit after every task with the trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## File Structure

| File | Responsibility |
| --- | --- |
| `Sources/ADFPreparation/Search/SearchIndex.swift` (new) | `SearchTextUnit` (+`Part`), `SearchMatch`, `SearchHighlightSpan` value types |
| `Sources/ADFPreparation/Search/SearchIndexer.swift` (new) | `[RenderBlock]` → `[SearchTextUnit]` recursive walk (incl. expand bodies) |
| `Sources/ADFPreparation/Search/SearchMatcher.swift` (new) | query → match ranges; match range → per-segment spans / atom IDs |
| `Sources/ADFRendering/Search/ADFSearchHighlights.swift` (new) | Environment payload struct + `adfDocumentSearch` EnvironmentKey |
| `Sources/ADFRendering/Search/SearchHighlightPainter.swift` (new) | Pure attribute application to segments / AttributedString |
| `Sources/ADFRendering/Search/VisibleRowRegistry.swift` (new) | Plain-class viewport-visibility set fed by rows |
| `Sources/ADFRendering/Search/ADFDocumentSearch.swift` (new) | `@Observable` controller: debounce, off-main scan, navigation |
| `Sources/ADFRendering/ADFScrollTargetPlacement.swift` (new) | `.top/.nearTop/.nearBottom` → `UnitPoint` anchor math |
| `Sources/ADFPreparation/ADFTheme.swift` (modify) | `searchHighlight` / `searchCurrentHighlight` / `searchCurrentForeground` tokens |
| `Sources/ADFRendering/ADFDocumentModel.swift` (modify) | owns `search`, `anchors`, `expandedBlocks`, `scrollTargetPlacement`; hooks |
| `Sources/ADFRendering/ADFDocumentView.swift` (modify) | env injection, visibility feed, placement-aware consumer |
| `Sources/ADFRendering/Inline/SegmentedTextView.swift` (modify) | ownerID, highlight paint, flash, atom-ID tokens |
| `Sources/ADFRendering/Inline/AtomViews.swift` (unchanged) | pill highlight applied by `InlineTokenView`, not here |
| `Sources/ADFRendering/Blocks/CodeBlockView.swift` (modify) | ownerID, highlight paint, flash |
| `Sources/ADFRendering/Blocks/RichTextBlockView.swift`, `ListBlockView.swift`, `Media/MediaBlockView.swift`, `BlockView.swift` (modify) | thread ownerID to text leaves |
| `Sources/ADFRendering/Blocks/ExpandBlockView.swift` (modify) | model-backed expansion state |
| `Demo/ADFReader/SearchBar.swift` (new), `Demo/ADFReader/ReaderView.swift` (modify) | demo find-in-page UI |
| `Tests/ADFPreparationTests/SearchIndexerTests.swift`, `SearchMatcherTests.swift` (new) | indexer/matcher unit tests |
| `Tests/ADFRenderingTests/SearchHighlightPainterTests.swift`, `ScrollTargetPlacementTests.swift`, `ADFDocumentSearchTests.swift` (new) | painter/anchor/controller tests |

---

### Task 1: Search unit types + flat-text indexing

**Files:**
- Create: `Sources/ADFPreparation/Search/SearchIndex.swift`
- Create: `Sources/ADFPreparation/Search/SearchIndexer.swift`
- Test: `Tests/ADFPreparationTests/SearchIndexerTests.swift`

**Interfaces:**
- Consumes: `RenderBlock`, `InlineSegment`, `InlineComposer.fallbackText(_:)` (internal, same module), `ADFTheme`.
- Produces: `SearchTextUnit { ownerID: String, topLevelBlockID: String, expandAncestorIDs: [String], plainText: String, parts: [Part] }` with `Part { source: .textSegment(index: Int) | .atom(id: String), range: Range<Int> }` (Character offsets into `plainText`); `SearchMatch { unitIndex: Int, range: Range<Int> }`; `SearchHighlightSpan { segmentIndex: Int, range: Range<Int> }`; `SearchIndexer(theme:).units(for: [RenderBlock]) -> [SearchTextUnit]` covering richText, codeBlock, listRows (row segments), media/mediaStrip captions.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ADFPreparationTests/SearchIndexerTests.swift`:

```swift
import Foundation
import Testing
import ADFModel
@testable import ADFPreparation

@Suite("SearchIndexer")
struct SearchIndexerTests {
    private let theme = ADFTheme.default
    private var indexer: SearchIndexer { SearchIndexer(theme: theme) }

    private func prepared(_ json: String) async throws -> [RenderBlock] {
        DocumentPreparer(theme: theme).prepare(try await parseDoc(json))
    }

    @Test("a paragraph yields one unit whose plain text and part map cover the whole text")
    func paragraphUnit() async throws {
        let blocks = try await prepared("""
        {"version":1,"type":"doc","content":[{"type":"paragraph","content":[
          {"type":"text","text":"Hello "},
          {"type":"text","text":"world","marks":[{"type":"strong"}]}
        ]}]}
        """)
        let units = indexer.units(for: blocks)
        let unit = try #require(units.first)
        #expect(units.count == 1)
        #expect(unit.plainText == "Hello world")
        #expect(unit.ownerID == blocks[0].id)
        #expect(unit.topLevelBlockID == blocks[0].id)
        #expect(unit.expandAncestorIDs.isEmpty)
        // Adjacent text runs merge into ONE segment at preparation time.
        #expect(unit.parts == [
            SearchTextUnit.Part(source: .textSegment(index: 0), range: 0..<11)
        ])
    }

    @Test("atoms contribute fallback text and their own part with the node ID")
    func atomUnit() async throws {
        let blocks = try await prepared("""
        {"version":1,"type":"doc","content":[{"type":"paragraph","content":[
          {"type":"text","text":"ask "},
          {"type":"mention","attrs":{"id":"u1","text":"@bob"}},
          {"type":"text","text":" now"}
        ]}]}
        """)
        let unit = try #require(indexer.units(for: blocks).first)
        #expect(unit.plainText == "ask @bob now")
        // Word-chunk splitting (atoms present) makes "ask " chunk 0, the atom
        // segment 1, then " now" is split at the leading space boundary.
        let atomPart = try #require(unit.parts.first { part in
            if case .atom = part.source { return true }
            return false
        })
        #expect(atomPart.range == 4..<8)
        guard case .atom(let id) = atomPart.source else {
            Issue.record("expected atom part"); return
        }
        #expect(id.isEmpty == false)
        // Every character of plainText is covered by exactly one part, in order.
        var covered = 0
        for part in unit.parts {
            #expect(part.range.lowerBound == covered)
            covered = part.range.upperBound
        }
        #expect(covered == unit.plainText.count)
    }

    @Test("code blocks yield a unit from the raw code text")
    func codeBlockUnit() async throws {
        let blocks = try await prepared("""
        {"version":1,"type":"doc","content":[{"type":"codeBlock","attrs":{"language":"swift"},"content":[
          {"type":"text","text":"let x = 1"}
        ]}]}
        """)
        let unit = try #require(indexer.units(for: blocks).first)
        #expect(unit.plainText == "let x = 1")
        #expect(unit.ownerID == blocks[0].id)
        #expect(unit.parts == [SearchTextUnit.Part(source: .textSegment(index: 0), range: 0..<9)])
    }

    @Test("list rows yield one unit per row, owned by the row ID")
    func listRowUnits() async throws {
        let blocks = try await prepared("""
        {"version":1,"type":"doc","content":[{"type":"bulletList","content":[
          {"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"first"}]}]},
          {"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"second"}]}]}
        ]}]}
        """)
        guard case .listRows(let rows) = blocks[0].kind else {
            Issue.record("expected listRows"); return
        }
        let units = indexer.units(for: blocks)
        #expect(units.map(\.plainText) == ["first", "second"])
        #expect(units.map(\.ownerID) == rows.map(\.id))
        #expect(units.allSatisfy { $0.topLevelBlockID == blocks[0].id })
    }

    @Test("empty and whitespace-only text yields no unit")
    func emptyTextSkipped() async throws {
        let blocks = try await prepared("""
        {"version":1,"type":"doc","content":[{"type":"paragraph","content":[]}]}
        """)
        #expect(indexer.units(for: blocks).isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SearchIndexer`
Expected: compile FAILURE — `SearchIndexer`/`SearchTextUnit` not defined.

- [ ] **Step 3: Write the types**

Create `Sources/ADFPreparation/Search/SearchIndex.swift`:

```swift
import Foundation

/// One searchable run of text extracted from the prepared block tree, with
/// enough bookkeeping to paint highlights back onto the exact segments the
/// view layer renders and to scroll to the containing lazy-stack row.
public struct SearchTextUnit: Sendable, Hashable {
    /// ID the rendering view knows itself by when looking up highlights:
    /// the rich-text/code block's `RenderBlock.id`, a `PreparedListRow.id`,
    /// or a `PreparedMedia.id` for captions.
    public let ownerID: String
    /// ID of the containing top-level lazy-stack row (`scrollTarget` key).
    /// For nested content (table cells, panel children, expand bodies) this
    /// is the enclosing top-level block/slice, not the owner.
    public let topLevelBlockID: String
    /// Expand blocks (outermost first) that must be open for this unit's
    /// content to be on screen. Empty for content outside expands.
    public let expandAncestorIDs: [String]
    /// Concatenated plain text: `String(text.characters)` for text segments,
    /// `InlineComposer.fallbackText` for atoms, in segment order.
    public let plainText: String
    /// Ordered, gap-free composition map from `plainText` Character offsets
    /// back to segments/atoms.
    public let parts: [Part]

    public struct Part: Sendable, Hashable {
        public enum Source: Sendable, Hashable {
            /// Index into the owner's `[InlineSegment]` (word chunks included:
            /// the index is into the SAME array the view renders).
            case textSegment(index: Int)
            /// Structural node ID of an atom pill.
            case atom(id: String)
        }

        public let source: Source
        /// This part's contribution as Character offsets in `plainText`.
        public let range: Range<Int>

        public init(source: Source, range: Range<Int>) {
            self.source = source
            self.range = range
        }
    }

    public init(
        ownerID: String,
        topLevelBlockID: String,
        expandAncestorIDs: [String],
        plainText: String,
        parts: [Part]
    ) {
        self.ownerID = ownerID
        self.topLevelBlockID = topLevelBlockID
        self.expandAncestorIDs = expandAncestorIDs
        self.plainText = plainText
        self.parts = parts
    }
}

/// One query hit: a Character-offset range in one unit's `plainText`.
/// Document order is (unitIndex, range.lowerBound) ascending.
public struct SearchMatch: Sendable, Hashable {
    public let unitIndex: Int
    public let range: Range<Int>

    public init(unitIndex: Int, range: Range<Int>) {
        self.unitIndex = unitIndex
        self.range = range
    }
}

/// One paintable slice of a match: a Character-offset range inside one
/// segment's `AttributedString`. Produced by `SearchMatcher.spans(for:in:)`,
/// consumed by the rendering layer's highlight painter.
public struct SearchHighlightSpan: Sendable, Hashable {
    public let segmentIndex: Int
    public let range: Range<Int>

    public init(segmentIndex: Int, range: Range<Int>) {
        self.segmentIndex = segmentIndex
        self.range = range
    }
}
```

- [ ] **Step 4: Write the flat indexer**

Create `Sources/ADFPreparation/Search/SearchIndexer.swift`:

```swift
import Foundation
import ADFModel

/// Walks prepared blocks into `SearchTextUnit`s. Pure and `Sendable`: safe to
/// run on any executor (`ADFDocumentSearch` runs it detached, off-main).
/// The theme matters only for expand bodies, which are prepared on demand
/// with the SAME preparer configuration the view uses, so segment shapes and
/// IDs align exactly (Task 3).
public struct SearchIndexer: Sendable {
    public let theme: ADFTheme

    public init(theme: ADFTheme) {
        self.theme = theme
    }

    /// Units for a batch of TOP-LEVEL blocks, in document order.
    public func units(for blocks: [RenderBlock]) -> [SearchTextUnit] {
        var result: [SearchTextUnit] = []
        for block in blocks {
            collect(block, topLevelBlockID: block.id, expandAncestorIDs: [], into: &result)
        }
        return result
    }

    private func collect(
        _ block: RenderBlock,
        topLevelBlockID: String,
        expandAncestorIDs: [String],
        into result: inout [SearchTextUnit]
    ) {
        switch block.kind {
        case .richText(let segments, _):
            appendUnit(ownerID: block.id, segments: segments,
                       topLevelBlockID: topLevelBlockID,
                       expandAncestorIDs: expandAncestorIDs, into: &result)
        case .codeBlock(_, let code):
            appendUnit(ownerID: block.id, segments: [.text(code)],
                       topLevelBlockID: topLevelBlockID,
                       expandAncestorIDs: expandAncestorIDs, into: &result)
        case .listRows(let rows):
            for row in rows {
                appendUnit(ownerID: row.id, segments: row.segments,
                           topLevelBlockID: topLevelBlockID,
                           expandAncestorIDs: expandAncestorIDs, into: &result)
                for trailing in row.trailingBlocks {
                    collect(trailing, topLevelBlockID: topLevelBlockID,
                            expandAncestorIDs: expandAncestorIDs, into: &result)
                }
            }
        case .media(let media):
            appendCaption(media, topLevelBlockID: topLevelBlockID,
                          expandAncestorIDs: expandAncestorIDs, into: &result)
        case .mediaStrip(let items):
            for media in items {
                appendCaption(media, topLevelBlockID: topLevelBlockID,
                              expandAncestorIDs: expandAncestorIDs, into: &result)
            }
        case .panel, .quote, .tableSlice, .layoutColumns, .extensionPlaceholder:
            break // Container recursion lands in Task 2.
        case .expand:
            break // Expand bodies land in Task 3.
        case .divider, .card, .unknown:
            break // No range-highlightable text (see Global Constraints).
        }
    }

    private func appendCaption(
        _ media: PreparedMedia,
        topLevelBlockID: String,
        expandAncestorIDs: [String],
        into result: inout [SearchTextUnit]
    ) {
        guard let caption = media.caption else { return }
        appendUnit(ownerID: media.id, segments: caption,
                   topLevelBlockID: topLevelBlockID,
                   expandAncestorIDs: expandAncestorIDs, into: &result)
    }

    /// Builds one unit from a composed segment array; skips whitespace-only
    /// content so empty paragraphs never dilute the corpus.
    private func appendUnit(
        ownerID: String,
        segments: [InlineSegment],
        topLevelBlockID: String,
        expandAncestorIDs: [String],
        into result: inout [SearchTextUnit]
    ) {
        var plain = ""
        var offset = 0
        var parts: [SearchTextUnit.Part] = []
        for (index, segment) in segments.enumerated() {
            let contribution: String
            let source: SearchTextUnit.Part.Source
            switch segment {
            case .text(let text):
                contribution = String(text.characters)
                source = .textSegment(index: index)
            case .atom(let atom, let id):
                contribution = InlineComposer.fallbackText(atom)
                source = .atom(id: id)
            }
            guard !contribution.isEmpty else { continue }
            let length = contribution.count
            parts.append(.init(source: source, range: offset..<(offset + length)))
            plain += contribution
            offset += length
        }
        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        result.append(SearchTextUnit(
            ownerID: ownerID,
            topLevelBlockID: topLevelBlockID,
            expandAncestorIDs: expandAncestorIDs,
            plainText: plain,
            parts: parts
        ))
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter SearchIndexer`
Expected: PASS (5 tests). Then `swift test` — all 117 pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/ADFPreparation/Search Tests/ADFPreparationTests/SearchIndexerTests.swift
git commit -m "feat: add search text units and flat-block indexing"
```

---

### Task 2: Indexer container recursion

**Files:**
- Modify: `Sources/ADFPreparation/Search/SearchIndexer.swift` (the `case .panel, .quote, .tableSlice, .layoutColumns, .extensionPlaceholder: break` arm)
- Test: `Tests/ADFPreparationTests/SearchIndexerTests.swift` (append tests)

**Interfaces:**
- Produces: units for text nested in panels, quotes, extension bodies, layout columns, and table cells. Nested units keep `ownerID` = the inner block/row/media id but `topLevelBlockID` = the enclosing TOP-LEVEL block (for table content: the enclosing SLICE block id, e.g. `"3#rows0"`), so `scrollTarget` can address them.

- [ ] **Step 1: Write the failing tests** (append to `SearchIndexerTests.swift`, inside the suite)

```swift
    @Test("panel and quote children yield units addressed to the top-level container")
    func containerRecursion() async throws {
        let blocks = try await prepared("""
        {"version":1,"type":"doc","content":[
          {"type":"panel","attrs":{"panelType":"info"},"content":[
            {"type":"paragraph","content":[{"type":"text","text":"inside panel"}]}
          ]},
          {"type":"blockquote","content":[
            {"type":"paragraph","content":[{"type":"text","text":"inside quote"}]}
          ]}
        ]}
        """)
        let units = indexer.units(for: blocks)
        #expect(units.map(\.plainText) == ["inside panel", "inside quote"])
        #expect(units[0].topLevelBlockID == blocks[0].id)
        #expect(units[1].topLevelBlockID == blocks[1].id)
        // The owner is the INNER paragraph block (what the view keys on),
        // not the container.
        #expect(units[0].ownerID != blocks[0].id)
    }

    @Test("table cell text maps to the enclosing slice for scrolling")
    func tableCellUnits() async throws {
        let blocks = try await prepared("""
        {"version":1,"type":"doc","content":[{"type":"table","content":[
          {"type":"tableRow","content":[
            {"type":"tableHeader","content":[{"type":"paragraph","content":[{"type":"text","text":"head"}]}]}
          ]},
          {"type":"tableRow","content":[
            {"type":"tableCell","content":[{"type":"paragraph","content":[{"type":"text","text":"body cell"}]}]}
          ]}
        ]}]}
        """)
        // Preparer slices: [<id>#header, <id>#rows0].
        #expect(blocks.count == 2)
        let units = indexer.units(for: blocks)
        #expect(units.map(\.plainText) == ["head", "body cell"])
        #expect(units[0].topLevelBlockID == blocks[0].id)
        #expect(units[0].topLevelBlockID.hasSuffix("#header"))
        #expect(units[1].topLevelBlockID == blocks[1].id)
        #expect(units[1].topLevelBlockID.hasSuffix("#rows0"))
    }

    @Test("layout columns and extension bodies recurse")
    func layoutAndExtensionRecursion() async throws {
        let blocks = try await prepared("""
        {"version":1,"type":"doc","content":[
          {"type":"layoutSection","content":[
            {"type":"layoutColumn","attrs":{"width":50},"content":[
              {"type":"paragraph","content":[{"type":"text","text":"left col"}]}
            ]},
            {"type":"layoutColumn","attrs":{"width":50},"content":[
              {"type":"paragraph","content":[{"type":"text","text":"right col"}]}
            ]}
          ]}
        ]}
        """)
        let units = indexer.units(for: blocks)
        #expect(units.map(\.plainText) == ["left col", "right col"])
        #expect(units.allSatisfy { $0.topLevelBlockID == blocks[0].id })
    }

    @Test("kitchen-sink fixture indexes without gaps in any unit's part map")
    func fixtureIndexesGapFree() async throws {
        let doc = try await ADFParser().parse(fixtureData("kitchen-sink.json"))
        let blocks = DocumentPreparer(theme: theme).prepare(doc)
        let units = indexer.units(for: blocks)
        #expect(units.count > 10)
        for unit in units {
            var covered = 0
            for part in unit.parts {
                #expect(part.range.lowerBound == covered, "gap in \(unit.ownerID)")
                covered = part.range.upperBound
            }
            #expect(covered == unit.plainText.count, "short map in \(unit.ownerID)")
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SearchIndexer`
Expected: FAIL — `containerRecursion`, `tableCellUnits`, `layoutAndExtensionRecursion` find 0 units.

- [ ] **Step 3: Implement recursion**

In `SearchIndexer.swift`, replace the container `break` arm of `collect`:

```swift
        case .panel(_, let children):
            for child in children {
                collect(child, topLevelBlockID: topLevelBlockID,
                        expandAncestorIDs: expandAncestorIDs, into: &result)
            }
        case .quote(let children):
            for child in children {
                collect(child, topLevelBlockID: topLevelBlockID,
                        expandAncestorIDs: expandAncestorIDs, into: &result)
            }
        case .extensionPlaceholder(_, let body):
            for child in body {
                collect(child, topLevelBlockID: topLevelBlockID,
                        expandAncestorIDs: expandAncestorIDs, into: &result)
            }
        case .layoutColumns(let columns):
            for column in columns {
                for child in column.blocks {
                    collect(child, topLevelBlockID: topLevelBlockID,
                            expandAncestorIDs: expandAncestorIDs, into: &result)
                }
            }
        case .tableSlice(_, let rows, _):
            for row in rows {
                for cell in row.cells {
                    for child in cell.blocks {
                        collect(child, topLevelBlockID: topLevelBlockID,
                                expandAncestorIDs: expandAncestorIDs, into: &result)
                    }
                }
            }
```

(`topLevelBlockID` is threaded unchanged — for a table it is already the slice's own id because `collect` was entered with `block.id` of the slice.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SearchIndexer` → PASS. Then `swift test` → all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ADFPreparation/Search/SearchIndexer.swift Tests/ADFPreparationTests/SearchIndexerTests.swift
git commit -m "feat: index text nested in panels, quotes, tables, columns, extensions"
```

---

### Task 3: Indexer expand bodies + ancestor chains

**Files:**
- Modify: `Sources/ADFPreparation/Search/SearchIndexer.swift` (the `case .expand: break` arm)
- Test: `Tests/ADFPreparationTests/SearchIndexerTests.swift` (append tests)

**Interfaces:**
- Consumes: `DocumentPreparer(theme:).prepare(_:)` (synchronous), `ADFNode(id:type:kind:)`, `ADFDocument(version:root:issues:)`. The synthetic wrapper doc MUST be identical to `ExpandBlockView.prepareBodyIfNeeded()`'s: `ADFNode(id: "expand", type: "doc", kind: .doc(bodyNodes))` — that is what guarantees inner `RenderBlock.id`s match what the view renders after expansion.
- Produces: units inside expands carry `expandAncestorIDs` = chain of expand block ids, outermost first; `topLevelBlockID` = the enclosing top-level block (the expand itself when it is top-level).

- [ ] **Step 1: Write the failing tests** (append to the suite)

```swift
    @Test("collapsed expand bodies are indexed with the expand as ancestor")
    func expandBodyIndexed() async throws {
        let blocks = try await prepared("""
        {"version":1,"type":"doc","content":[{"type":"expand","attrs":{"title":"More"},"content":[
          {"type":"paragraph","content":[{"type":"text","text":"hidden treasure"}]}
        ]}]}
        """)
        let unit = try #require(indexer.units(for: blocks).first)
        #expect(unit.plainText == "hidden treasure")
        #expect(unit.expandAncestorIDs == [blocks[0].id])
        #expect(unit.topLevelBlockID == blocks[0].id)
        // Owner is the INNER paragraph's block id — the id the expanded view
        // will render it under.
        #expect(unit.ownerID != blocks[0].id)
    }

    @Test("nested expands accumulate the ancestor chain outermost-first")
    func nestedExpandChain() async throws {
        let blocks = try await prepared("""
        {"version":1,"type":"doc","content":[{"type":"expand","attrs":{"title":"Outer"},"content":[
          {"type":"nestedExpand","attrs":{"title":"Inner"},"content":[
            {"type":"paragraph","content":[{"type":"text","text":"deep"}]}
          ]}
        ]}]}
        """)
        let unit = try #require(indexer.units(for: blocks).first { $0.plainText == "deep" })
        #expect(unit.expandAncestorIDs.count == 2)
        #expect(unit.expandAncestorIDs.first == blocks[0].id)
        #expect(unit.topLevelBlockID == blocks[0].id)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SearchIndexer`
Expected: FAIL — expand units missing.

- [ ] **Step 3: Implement expand indexing**

In `SearchIndexer.swift`, add `import ADFModel` is already present; replace the `case .expand: break` arm:

```swift
        case .expand(_, let bodyNodes, _):
            // Prepare the body EXACTLY as ExpandBlockView does on first
            // expansion (same synthetic wrapper, same theme), so inner block
            // IDs and segment shapes match what the expanded view renders.
            let root = ADFNode(id: "expand", type: "doc", kind: .doc(bodyNodes))
            let document = ADFDocument(version: 1, root: root, issues: [])
            let bodyBlocks = DocumentPreparer(theme: theme).prepare(document)
            let chain = expandAncestorIDs + [block.id]
            for child in bodyBlocks {
                collect(child, topLevelBlockID: topLevelBlockID,
                        expandAncestorIDs: chain, into: &result)
            }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SearchIndexer` → PASS. Then `swift test` → all pass. Also confirm the stress fixture stays fast: `swift test --filter "DocumentPreparer"` (the 2-second stress gate must still pass).

- [ ] **Step 5: Commit**

```bash
git add Sources/ADFPreparation/Search/SearchIndexer.swift Tests/ADFPreparationTests/SearchIndexerTests.swift
git commit -m "feat: index collapsed expand bodies with ancestor chains"
```

---

### Task 4: SearchMatcher

**Files:**
- Create: `Sources/ADFPreparation/Search/SearchMatcher.swift`
- Test: `Tests/ADFPreparationTests/SearchMatcherTests.swift`

**Interfaces:**
- Produces:
  - `SearchMatcher.matchRanges(in text: String, query: String) -> [Range<Int>]` — Character-offset ranges, non-overlapping, `[.caseInsensitive, .diacriticInsensitive]`, `locale: nil`.
  - `SearchMatcher.matches(in units: [SearchTextUnit], unitIndexOffset: Int, query: String) -> [SearchMatch]`
  - `SearchMatcher.spans(for range: Range<Int>, in unit: SearchTextUnit) -> (textSpans: [SearchHighlightSpan], atomIDs: [String])` — slices a match range through the part map; text spans are LOCAL Character offsets within each segment.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ADFPreparationTests/SearchMatcherTests.swift`:

```swift
import Foundation
import Testing
@testable import ADFPreparation

@Suite("SearchMatcher")
struct SearchMatcherTests {
    @Test("matching is case- and diacritic-insensitive")
    func foldedMatching() {
        #expect(SearchMatcher.matchRanges(in: "My Résumé here", query: "resume") == [3..<9])
        #expect(SearchMatcher.matchRanges(in: "HELLO hello HeLLo", query: "hello") == [0..<5, 6..<11, 12..<17])
    }

    @Test("matches never overlap; the scanner advances past each hit")
    func nonOverlapping() {
        #expect(SearchMatcher.matchRanges(in: "aaaa", query: "aa") == [0..<2, 2..<4])
    }

    @Test("empty query and empty text match nothing")
    func emptyInputs() {
        #expect(SearchMatcher.matchRanges(in: "abc", query: "").isEmpty)
        #expect(SearchMatcher.matchRanges(in: "", query: "a").isEmpty)
    }

    @Test("batch matching offsets unit indices and preserves document order")
    func batchMatching() {
        let unit = SearchTextUnit(
            ownerID: "a", topLevelBlockID: "a", expandAncestorIDs: [],
            plainText: "fox and fox",
            parts: [.init(source: .textSegment(index: 0), range: 0..<11)]
        )
        let matches = SearchMatcher.matches(in: [unit, unit], unitIndexOffset: 7, query: "fox")
        #expect(matches == [
            SearchMatch(unitIndex: 7, range: 0..<3),
            SearchMatch(unitIndex: 7, range: 8..<11),
            SearchMatch(unitIndex: 8, range: 0..<3),
            SearchMatch(unitIndex: 8, range: 8..<11),
        ])
    }

    @Test("a match slices into per-segment local spans across chunk boundaries")
    func spansAcrossSegments() {
        // plainText "one two", split as chunks: "one " (seg 0) + "two" (seg 1)
        let unit = SearchTextUnit(
            ownerID: "a", topLevelBlockID: "a", expandAncestorIDs: [],
            plainText: "one two",
            parts: [
                .init(source: .textSegment(index: 0), range: 0..<4),
                .init(source: .textSegment(index: 1), range: 4..<7),
            ]
        )
        let result = SearchMatcher.spans(for: 2..<6, in: unit) // "e tw"
        #expect(result.textSpans == [
            SearchHighlightSpan(segmentIndex: 0, range: 2..<4),
            SearchHighlightSpan(segmentIndex: 1, range: 0..<2),
        ])
        #expect(result.atomIDs.isEmpty)
    }

    @Test("a match covering an atom reports the atom ID and clips text spans around it")
    func spansOverAtom() {
        // "ask " (seg 0) + "@bob" (atom n1) + " now" (seg 2, chunked as " now")
        let unit = SearchTextUnit(
            ownerID: "a", topLevelBlockID: "a", expandAncestorIDs: [],
            plainText: "ask @bob now",
            parts: [
                .init(source: .textSegment(index: 0), range: 0..<4),
                .init(source: .atom(id: "n1"), range: 4..<8),
                .init(source: .textSegment(index: 2), range: 8..<12),
            ]
        )
        let result = SearchMatcher.spans(for: 0..<10, in: unit)
        #expect(result.textSpans == [
            SearchHighlightSpan(segmentIndex: 0, range: 0..<4),
            SearchHighlightSpan(segmentIndex: 2, range: 0..<2),
        ])
        #expect(result.atomIDs == ["n1"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SearchMatcher`
Expected: compile FAILURE — `SearchMatcher` not defined.

- [ ] **Step 3: Implement the matcher**

Create `Sources/ADFPreparation/Search/SearchMatcher.swift`:

```swift
import Foundation

/// Pure string matching over indexed units. All offsets are Character
/// offsets (the unit of `AttributedString.characters`), so folded matches
/// (case/diacritic variants of different UTF lengths) stay aligned with the
/// original text.
public enum SearchMatcher {
    /// Non-overlapping hits of `query` in `text`, case- and
    /// diacritic-insensitive, as Character-offset ranges in `text`.
    public static func matchRanges(in text: String, query: String) -> [Range<Int>] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        var result: [Range<Int>] = []
        var searchStart = text.startIndex
        // Running Character offset of `searchStart`, so each hit converts
        // indices with a short local distance, not a scan from the start.
        var startOffset = 0
        while let found = text.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: searchStart..<text.endIndex,
            locale: nil
        ) {
            let lower = startOffset + text.distance(from: searchStart, to: found.lowerBound)
            let upper = lower + text.distance(from: found.lowerBound, to: found.upperBound)
            result.append(lower..<upper)
            searchStart = found.upperBound
            startOffset = upper
        }
        return result
    }

    /// Batch form used by the streaming scan: hits for `units`, whose global
    /// indices start at `unitIndexOffset`, in document order.
    public static func matches(
        in units: [SearchTextUnit],
        unitIndexOffset: Int,
        query: String
    ) -> [SearchMatch] {
        var result: [SearchMatch] = []
        for (localIndex, unit) in units.enumerated() {
            for range in matchRanges(in: unit.plainText, query: query) {
                result.append(SearchMatch(unitIndex: unitIndexOffset + localIndex, range: range))
            }
        }
        return result
    }

    /// Slices one match range through the unit's part map into paintable
    /// pieces: per-segment LOCAL Character ranges for text parts, plus the
    /// IDs of atom pills the range covers (pills highlight whole).
    public static func spans(
        for range: Range<Int>,
        in unit: SearchTextUnit
    ) -> (textSpans: [SearchHighlightSpan], atomIDs: [String]) {
        var textSpans: [SearchHighlightSpan] = []
        var atomIDs: [String] = []
        for part in unit.parts where part.range.overlaps(range) {
            switch part.source {
            case .textSegment(let segmentIndex):
                let lower = max(range.lowerBound, part.range.lowerBound) - part.range.lowerBound
                let upper = min(range.upperBound, part.range.upperBound) - part.range.lowerBound
                guard lower < upper else { continue }
                textSpans.append(SearchHighlightSpan(segmentIndex: segmentIndex, range: lower..<upper))
            case .atom(let id):
                atomIDs.append(id)
            }
        }
        return (textSpans, atomIDs)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SearchMatcher` → PASS (6 tests). Then `swift test` → all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ADFPreparation/Search/SearchMatcher.swift Tests/ADFPreparationTests/SearchMatcherTests.swift
git commit -m "feat: add case/diacritic-insensitive matcher with span slicing"
```

---

### Task 5: Theme tokens, highlight payload, and painter

**Files:**
- Modify: `Sources/ADFPreparation/ADFTheme.swift` (add three stored tokens)
- Create: `Sources/ADFRendering/Search/ADFSearchHighlights.swift`
- Create: `Sources/ADFRendering/Search/SearchHighlightPainter.swift`
- Test: `Tests/ADFRenderingTests/SearchHighlightPainterTests.swift`

**Interfaces:**
- Produces:
  - `ADFTheme.searchHighlight: Color` (default `.yellow.opacity(0.3)`), `ADFTheme.searchCurrentHighlight: Color` (default opaque `Color(red: 1.0, green: 0.78, blue: 0.16)`), `ADFTheme.searchCurrentForeground: Color?` (default `.black`; documented as paired with the bright default fill).
  - `ADFSearchHighlights { spansByOwner: [String: [SearchHighlightSpan]], matchedAtomIDs: Set<String>, current: Current? }` with `Current { ownerID, spans: [SearchHighlightSpan], atomIDs: Set<String>, generation: Int }`, `static let none`, `var isActive: Bool`.
  - `adfDocumentSearch: ADFDocumentSearch?` EnvironmentKey — **declared in Task 7** when the class exists; this task only ships the payload struct.
  - `SearchHighlightPainter.paint(segments:spans:currentSpans:theme:dimCurrent:) -> [InlineSegment]` and `SearchHighlightPainter.paint(text:spans:currentSpans:theme:dimCurrent:) -> AttributedString`.

- [ ] **Step 1: Add theme tokens** (no test needed beyond compilation — value defaults asserted in painter tests)

In `Sources/ADFPreparation/ADFTheme.swift`, add stored properties after `cardCornerRadius` and matching init parameters with defaults:

```swift
    /// Background for every search match (subtle, translucent).
    public var searchHighlight: Color
    /// Background for the CURRENT search match (accent). The default is an
    /// opaque bright yellow-orange; pair a custom value with a suitable
    /// `searchCurrentForeground`.
    public var searchCurrentHighlight: Color
    /// Foreground forced over `searchCurrentHighlight` so the current match
    /// stays legible in both schemes. `nil` keeps the run's own foreground.
    public var searchCurrentForeground: Color?
```

and in `init`, after `cardCornerRadius: CGFloat = 10,`:

```swift
        searchHighlight: Color = .yellow.opacity(0.3),
        searchCurrentHighlight: Color = Color(red: 1.0, green: 0.78, blue: 0.16),
        searchCurrentForeground: Color? = .black
```

with the assignments in the body. Run `swift test` — still green (all params have defaults).

- [ ] **Step 2: Write the failing painter tests**

Create `Tests/ADFRenderingTests/SearchHighlightPainterTests.swift`:

```swift
import Foundation
import SwiftUI
import Testing
import ADFModel
import ADFPreparation
@testable import ADFRendering

private typealias SUI = AttributeScopes.SwiftUIAttributes

@Suite("SearchHighlightPainter")
struct SearchHighlightPainterTests {
    private let theme = ADFTheme.default

    private func backgrounds(of text: AttributedString) -> [(String, Color?)] {
        text.runs.map { run in
            (String(text[run.range].characters), run[SUI.BackgroundColorAttribute.self])
        }
    }

    @Test("no spans returns the identical segments — zero-work fast path")
    func noSpansIsIdentity() {
        let segments: [InlineSegment] = [.text(AttributedString("hello world"))]
        let painted = SearchHighlightPainter.paint(
            segments: segments, spans: [], currentSpans: [], theme: theme, dimCurrent: false
        )
        #expect(painted == segments)
    }

    @Test("a span paints the subtle background over exactly its range")
    func subtleSpanPaints() throws {
        let segments: [InlineSegment] = [.text(AttributedString("hello world"))]
        let painted = SearchHighlightPainter.paint(
            segments: segments,
            spans: [SearchHighlightSpan(segmentIndex: 0, range: 6..<11)],
            currentSpans: [], theme: theme, dimCurrent: false
        )
        guard case .text(let text) = painted[0] else { throw TestFailure("expected text") }
        let runs = backgrounds(of: text)
        #expect(runs.contains { $0.0 == "world" && $0.1 == theme.searchHighlight })
        #expect(runs.contains { $0.0 == "hello " && $0.1 == nil })
    }

    @Test("current spans win over subtle spans and set the contrast foreground")
    func currentSpanWins() throws {
        let segments: [InlineSegment] = [.text(AttributedString("aaaa"))]
        let painted = SearchHighlightPainter.paint(
            segments: segments,
            spans: [SearchHighlightSpan(segmentIndex: 0, range: 0..<4)],
            currentSpans: [SearchHighlightSpan(segmentIndex: 0, range: 0..<2)],
            theme: theme, dimCurrent: false
        )
        guard case .text(let text) = painted[0] else { throw TestFailure("expected text") }
        let runs = backgrounds(of: text)
        #expect(runs.contains { $0.0 == "aa" && $0.1 == theme.searchCurrentHighlight })
        let currentRun = try #require(text.runs.first)
        #expect(currentRun[SUI.ForegroundColorAttribute.self] == theme.searchCurrentForeground)
    }

    @Test("dimCurrent paints the current span with the subtle color (flash off-phase)")
    func dimmedCurrentUsesSubtle() throws {
        let segments: [InlineSegment] = [.text(AttributedString("abcd"))]
        let painted = SearchHighlightPainter.paint(
            segments: segments, spans: [],
            currentSpans: [SearchHighlightSpan(segmentIndex: 0, range: 0..<4)],
            theme: theme, dimCurrent: true
        )
        guard case .text(let text) = painted[0] else { throw TestFailure("expected text") }
        #expect(backgrounds(of: text).contains { $0.0 == "abcd" && $0.1 == theme.searchHighlight })
    }

    @Test("out-of-bounds ranges clamp instead of trapping")
    func rangesClamp() throws {
        let segments: [InlineSegment] = [.text(AttributedString("ab"))]
        let painted = SearchHighlightPainter.paint(
            segments: segments,
            spans: [SearchHighlightSpan(segmentIndex: 0, range: 1..<99),
                    SearchHighlightSpan(segmentIndex: 5, range: 0..<1)],
            currentSpans: [], theme: theme, dimCurrent: false
        )
        guard case .text(let text) = painted[0] else { throw TestFailure("expected text") }
        #expect(backgrounds(of: text).contains { $0.0 == "b" && $0.1 == theme.searchHighlight })
    }

    @Test("atom segments are left untouched by text spans")
    func atomSegmentsUntouched() {
        let segments: [InlineSegment] = [
            .atom(.mention(text: "@bob"), id: "n1"),
            .text(AttributedString("hi")),
        ]
        let painted = SearchHighlightPainter.paint(
            segments: segments,
            spans: [SearchHighlightSpan(segmentIndex: 0, range: 0..<2)],
            currentSpans: [], theme: theme, dimCurrent: false
        )
        #expect(painted[0] == segments[0])
    }
}

struct TestFailure: Error { let message: String; init(_ message: String) { self.message = message } }
```

Note: `TestFailure` here is target-local to ADFRenderingTests (the ADFPreparationTests one is a different target).

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter SearchHighlightPainter`
Expected: compile FAILURE — `SearchHighlightPainter` / `ADFSearchHighlights` not defined.

- [ ] **Step 4: Implement payload + painter**

Create `Sources/ADFRendering/Search/ADFSearchHighlights.swift`:

```swift
import Foundation
import ADFPreparation

/// Everything leaf text views need to paint search highlights, published by
/// `ADFDocumentSearch.highlights`. Changes only when results change or the
/// user navigates — never per keystroke mid-debounce.
public struct ADFSearchHighlights: Equatable, Sendable {
    /// All matches' text spans, keyed by owner ID (rich-text/code block id,
    /// list-row id, media id). Spans use LOCAL Character offsets per segment.
    public internal(set) var spansByOwner: [String: [SearchHighlightSpan]]
    /// Atom pills covered by any match (whole-pill subtle highlight).
    public internal(set) var matchedAtomIDs: Set<String>
    /// The navigated-to match, painted with the accent style + flash.
    public internal(set) var current: Current?

    public struct Current: Equatable, Sendable {
        public internal(set) var ownerID: String
        public internal(set) var spans: [SearchHighlightSpan]
        public internal(set) var atomIDs: Set<String>
        /// Bumped on every navigation; drives the arrival flash.
        public internal(set) var generation: Int
    }

    public static let none = ADFSearchHighlights(
        spansByOwner: [:], matchedAtomIDs: [], current: nil
    )

    public var isActive: Bool {
        !spansByOwner.isEmpty || !matchedAtomIDs.isEmpty || current != nil
    }
}
```

Create `Sources/ADFRendering/Search/SearchHighlightPainter.swift`:

```swift
import SwiftUI
import ADFPreparation

/// Applies search-highlight attributes to prepared text. Pure functions,
/// called from `body` ONLY when the owner has matches (the caller's guard is
/// the zero-work-common-case gate; see `scalingBaselineOffsets` precedent).
enum SearchHighlightPainter {
    private typealias SUI = AttributeScopes.SwiftUIAttributes

    /// Returns `segments` with match backgrounds applied. Returns the input
    /// value untouched (no copy) when there is nothing to paint.
    static func paint(
        segments: [InlineSegment],
        spans: [SearchHighlightSpan],
        currentSpans: [SearchHighlightSpan],
        theme: ADFTheme,
        dimCurrent: Bool
    ) -> [InlineSegment] {
        guard !spans.isEmpty || !currentSpans.isEmpty else { return segments }
        // Group edits per segment; subtle first so current overwrites.
        var edits: [Int: [(Range<Int>, Bool)]] = [:]
        for span in spans { edits[span.segmentIndex, default: []].append((span.range, false)) }
        for span in currentSpans { edits[span.segmentIndex, default: []].append((span.range, true)) }
        var painted = segments
        for (index, segmentEdits) in edits {
            guard painted.indices.contains(index), case .text(let text) = painted[index] else {
                continue // Atom spans never reach here; stale indices are skipped.
            }
            painted[index] = .text(apply(segmentEdits, to: text, theme: theme, dimCurrent: dimCurrent))
        }
        return painted
    }

    /// Single-string form for code blocks (segmentIndex is ignored; the code
    /// block is one attributed string).
    static func paint(
        text: AttributedString,
        spans: [SearchHighlightSpan],
        currentSpans: [SearchHighlightSpan],
        theme: ADFTheme,
        dimCurrent: Bool
    ) -> AttributedString {
        guard !spans.isEmpty || !currentSpans.isEmpty else { return text }
        let edits = spans.map { ($0.range, false) } + currentSpans.map { ($0.range, true) }
        return apply(edits, to: text, theme: theme, dimCurrent: dimCurrent)
    }

    private static func apply(
        _ edits: [(Range<Int>, Bool)],
        to text: AttributedString,
        theme: ADFTheme,
        dimCurrent: Bool
    ) -> AttributedString {
        var painted = text
        let count = painted.characters.count
        // Subtle first, current last, so the accent wins on overlap.
        for (range, isCurrent) in edits.sorted(by: { !$0.1 && $1.1 }) {
            let lower = min(max(range.lowerBound, 0), count)
            let upper = min(max(range.upperBound, 0), count)
            guard lower < upper else { continue }
            let characters = painted.characters
            let start = characters.index(painted.startIndex, offsetBy: lower)
            let end = characters.index(start, offsetBy: upper - lower)
            let accent = isCurrent && !dimCurrent
            painted[start..<end][SUI.BackgroundColorAttribute.self] =
                accent ? theme.searchCurrentHighlight : theme.searchHighlight
            if accent, let foreground = theme.searchCurrentForeground {
                painted[start..<end][SUI.ForegroundColorAttribute.self] = foreground
            }
        }
        return painted
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter SearchHighlightPainter` → PASS (6 tests). Then `swift test` → all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/ADFPreparation/ADFTheme.swift Sources/ADFRendering/Search Tests/ADFRenderingTests/SearchHighlightPainterTests.swift
git commit -m "feat: add search highlight theme tokens, payload, and painter"
```

---

### Task 6: Scroll placement, visibility registry, model plumbing

**Files:**
- Create: `Sources/ADFRendering/ADFScrollTargetPlacement.swift`
- Create: `Sources/ADFRendering/Search/VisibleRowRegistry.swift`
- Modify: `Sources/ADFRendering/ADFDocumentModel.swift` (add `scrollTargetPlacement`, move `anchors` in)
- Modify: `Sources/ADFRendering/ADFDocumentView.swift` (use `model.anchors`; placement-aware `ScrollTargetConsumer` with viewport measurement)
- Test: `Tests/ADFRenderingTests/ScrollTargetPlacementTests.swift`

**Interfaces:**
- Produces:
  - `ADFScrollTargetPlacement: Equatable, Sendable` — `.top`, `.nearTop(margin: CGFloat)`, `.nearBottom(margin: CGFloat)`; `func anchor(viewportHeight: CGFloat) -> UnitPoint` (margin fraction clamped to `0...0.4`; zero/negative heights → `.top` behavior).
  - `VisibleRowRegistry` (internal `@MainActor final class`): `setVisible(_ id: String, _ visible: Bool)`, `isVisible(_ id: String) -> Bool`. Plain class — writes invalidate nothing.
  - `ADFDocumentModel.scrollTargetPlacement: ADFScrollTargetPlacement` (public, `@ObservationIgnored`, default `.top`, reset to `.top` after each consume alongside `scrollTarget = nil`; **set placement BEFORE `scrollTarget`** — the consumer observes only `scrollTarget`).
  - `ADFDocumentModel.anchors: ScrollAnchorRegistry` (internal, `@ObservationIgnored let`) — replaces `ADFDocumentView`'s `@State`.

- [ ] **Step 1: Write the failing anchor-math tests**

Create `Tests/ADFRenderingTests/ScrollTargetPlacementTests.swift`:

```swift
import SwiftUI
import Testing
@testable import ADFRendering

@Suite("Scroll target placement")
struct ScrollTargetPlacementTests {
    @Test(".top is the plain top anchor")
    func topAnchor() {
        #expect(ADFScrollTargetPlacement.top.anchor(viewportHeight: 800) == .top)
    }

    @Test("nearTop insets the anchor by margin/height from the top")
    func nearTopAnchor() {
        let anchor = ADFScrollTargetPlacement.nearTop(margin: 40).anchor(viewportHeight: 800)
        #expect(abs(anchor.y - 0.05) < 0.0001)
    }

    @Test("nearBottom insets the anchor by margin/height from the bottom")
    func nearBottomAnchor() {
        let anchor = ADFScrollTargetPlacement.nearBottom(margin: 40).anchor(viewportHeight: 800)
        #expect(abs(anchor.y - 0.95) < 0.0001)
    }

    @Test("margins clamp to at most 40% of the viewport, and never negative")
    func marginClamps() {
        #expect(ADFScrollTargetPlacement.nearTop(margin: 900).anchor(viewportHeight: 800).y == 0.4)
        #expect(ADFScrollTargetPlacement.nearTop(margin: -10).anchor(viewportHeight: 800).y == 0)
        #expect(ADFScrollTargetPlacement.nearBottom(margin: 900).anchor(viewportHeight: 800).y == 0.6)
    }

    @Test("a zero-height viewport degrades to the plain edge")
    func zeroHeight() {
        #expect(ADFScrollTargetPlacement.nearTop(margin: 40).anchor(viewportHeight: 0).y == 0)
        #expect(ADFScrollTargetPlacement.nearBottom(margin: 40).anchor(viewportHeight: 0).y == 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "Scroll target placement"`
Expected: compile FAILURE — `ADFScrollTargetPlacement` not defined.

- [ ] **Step 3: Implement placement + registry**

Create `Sources/ADFRendering/ADFScrollTargetPlacement.swift`:

```swift
import SwiftUI

/// Where a programmatic scroll should land its target block: at the exact
/// top (legacy), or near an edge with a point margin left visible — search
/// navigation uses the edge nearest the match's approach direction.
public enum ADFScrollTargetPlacement: Equatable, Sendable {
    case top
    case nearTop(margin: CGFloat)
    case nearBottom(margin: CGFloat)

    /// The `ScrollViewProxy.scrollTo` anchor expressing this placement in a
    /// viewport of the given height. Margins are clamped to 40% of the
    /// viewport so degenerate configurations cannot center-or-worse a jump.
    public func anchor(viewportHeight: CGFloat) -> UnitPoint {
        switch self {
        case .top:
            return .top
        case .nearTop(let margin):
            return UnitPoint(x: 0.5, y: Self.fraction(margin, viewportHeight))
        case .nearBottom(let margin):
            return UnitPoint(x: 0.5, y: 1 - Self.fraction(margin, viewportHeight))
        }
    }

    private static func fraction(_ margin: CGFloat, _ height: CGFloat) -> CGFloat {
        guard height > 0 else { return 0 }
        return min(max(margin, 0) / height, 0.4)
    }
}
```

Create `Sources/ADFRendering/Search/VisibleRowRegistry.swift`:

```swift
/// Which top-level rows are genuinely inside the viewport, fed by per-row
/// `onScrollVisibilityChange` on iOS 18+/macOS 15+. On earlier OSes nothing
/// reports, `isVisible` is always false, and search navigation always
/// scrolls (graceful degradation).
///
/// A plain class on purpose (`ScrollAnchorRegistry` pattern): rows write on
/// every visibility crossing during scroll, and those writes must invalidate
/// nothing.
@MainActor
final class VisibleRowRegistry {
    private var visible: Set<String> = []

    func setVisible(_ id: String, _ isVisible: Bool) {
        if isVisible { visible.insert(id) } else { visible.remove(id) }
    }

    func isVisible(_ id: String) -> Bool {
        visible.contains(id)
    }
}
```

- [ ] **Step 4: Move anchors into the model and extend the consumer**

In `Sources/ADFRendering/ADFDocumentModel.swift`, add below `scrollTargetAnimation`:

```swift
    /// Placement for the next `scrollTarget` consume. Set BEFORE
    /// `scrollTarget` (the consumer observes only `scrollTarget`); the view
    /// resets it to `.top` together with clearing the target.
    /// Configuration, not UI state — hence not observed.
    @ObservationIgnored public var scrollTargetPlacement: ADFScrollTargetPlacement = .top

    /// Scroll-anchoring registry the document view binds `scrollPosition(id:)`
    /// through. Owned here (not view `@State`) so search can read the
    /// top-visible row without any geometry. See `ScrollAnchorRegistry`.
    @ObservationIgnored let anchors = ScrollAnchorRegistry()
```

In `Sources/ADFRendering/ADFDocumentView.swift`:

1. Delete the `@State private var anchors = ScrollAnchorRegistry()` property.
2. In `anchorBinding`, replace `anchors` with `model.anchors`:

```swift
    private var anchorBinding: Binding<String?> {
        Binding(get: { model.anchors.topRow }, set: { model.anchors.topRow = $0 })
    }
```

3. Replace `ScrollTargetConsumer` entirely:

```swift
/// Consumes `ADFDocumentModel.scrollTarget`: jumps the scroll view to the
/// requested block ID with the model's placement, then clears both. A
/// standalone leaf view so the observation (and the clearing write) never
/// invalidates the document view that hosts the lazy stack. The viewport
/// height is measured HERE — on the scroll view's frame, never inside lazy
/// rows — to turn point margins into `UnitPoint` anchors.
private struct ScrollTargetConsumer: View {
    let model: ADFDocumentModel
    let proxy: ScrollViewProxy

    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        Color.clear
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                viewportHeight = height
            }
            .onChange(of: model.scrollTarget) { _, target in
                guard let target else { return }
                let anchor = model.scrollTargetPlacement.anchor(viewportHeight: viewportHeight)
                withAnimation(model.scrollTargetAnimation) {
                    proxy.scrollTo(target, anchor: anchor)
                }
                model.scrollTarget = nil
                model.scrollTargetPlacement = .top
            }
    }
}
```

- [ ] **Step 5: Run tests to verify everything passes**

Run: `swift test`
Expected: PASS — placement tests green, all existing tests (TOC jump behavior unchanged: default placement `.top` ≡ old `anchor: .top`).

- [ ] **Step 6: Commit**

```bash
git add Sources/ADFRendering/ADFScrollTargetPlacement.swift Sources/ADFRendering/Search/VisibleRowRegistry.swift Sources/ADFRendering/ADFDocumentModel.swift Sources/ADFRendering/ADFDocumentView.swift Tests/ADFRenderingTests/ScrollTargetPlacementTests.swift
git commit -m "feat: margin-aware scroll placement, visibility registry, model-owned anchors"
```

---

### Task 7: ADFDocumentSearch controller + model wiring

**Files:**
- Create: `Sources/ADFRendering/Search/ADFDocumentSearch.swift`
- Modify: `Sources/ADFRendering/ADFDocumentModel.swift` (own `search`, `expandedBlocks`, hooks in `load`/`append`)
- Modify: `Sources/ADFRendering/Search/ADFSearchHighlights.swift` (append the EnvironmentKey now that the class exists)
- Test: `Tests/ADFRenderingTests/ADFDocumentSearchTests.swift`

**Interfaces:**
- Consumes: `SearchIndexer`, `SearchMatcher`, `ADFSearchHighlights`, `VisibleRowRegistry`, `ADFScrollTargetPlacement`, `model.anchors.topRow`, `model.scrollTarget(...)`.
- Produces (public API — the spec's contract):
  - `ADFDocumentSearch: @MainActor @Observable final class` with `run(_ query: String)`, `next()`, `previous()`, `clear()`; observable `query: String`, `matchCount: Int`, `currentIndex: Int?`, `isSearching: Bool`, `highlights: ADFSearchHighlights`; config `scrollMargin: CGFloat = 40`, `debounceInterval: Duration = .milliseconds(200)`.
  - Internal: `weak var model`, `let visibleRows = VisibleRowRegistry()`, `indexAppended(_ blocks: [RenderBlock], theme: ADFTheme)`, `reset()`.
  - `ADFDocumentModel.search: ADFDocumentSearch` (public let), `ADFDocumentModel.expandedBlocks: Set<String>` (public var, observable), `load()` calls `search.reset()` and clears `expandedBlocks`, `append()` calls `search.indexAppended(chunk, theme: theme)`.
  - `EnvironmentValues.adfDocumentSearch: ADFDocumentSearch?` (public, default nil).

- [ ] **Step 1: Write the failing tests**

Create `Tests/ADFRenderingTests/ADFDocumentSearchTests.swift`:

```swift
import Foundation
import Testing
import ADFPreparation
@testable import ADFRendering

/// Polls a main-actor condition with yields; fails fast instead of hanging.
@MainActor
private func waitUntil(
    _ what: Comment,
    timeoutIterations: Int = 2_000,
    _ condition: () -> Bool
) async throws {
    for _ in 0..<timeoutIterations {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("timed out waiting for \(what)")
    throw TestFailure("timeout: \(what)")
}

@MainActor
private func readyModel(_ json: String) async throws -> ADFDocumentModel {
    let model = ADFDocumentModel()
    model.load(data: Data(json.utf8))
    try await waitUntil("document ready") { model.phase == .ready }
    model.search.debounceInterval = .zero
    return model
}

private let threeFoxes = """
{"version":1,"type":"doc","content":[
  {"type":"paragraph","content":[{"type":"text","text":"a fox leads"}]},
  {"type":"paragraph","content":[{"type":"text","text":"no match here"}]},
  {"type":"paragraph","content":[{"type":"text","text":"fox two and fox three"}]}
]}
"""

@Suite("ADFDocumentSearch")
@MainActor
struct ADFDocumentSearchTests {
    @Test("run streams counts, auto-selects the first match, and requests a scroll")
    func runFindsAndAutoSelects() async throws {
        let model = try await readyModel(threeFoxes)
        model.search.run("fox")
        try await waitUntil("scan done") { !model.search.isSearching && model.search.matchCount > 0 }
        #expect(model.search.matchCount == 3)
        #expect(model.search.currentIndex == 0)
        #expect(model.search.highlights.current?.ownerID == model.blocks[0].id)
        // No visibility reporting in tests → navigation always scrolls.
        #expect(model.scrollTarget == model.blocks[0].id)
        #expect(model.search.highlights.spansByOwner.count == 2) // blocks 0 and 2
    }

    @Test("next and previous wrap in both directions and bump the flash generation")
    func navigationWraps() async throws {
        let model = try await readyModel(threeFoxes)
        model.search.run("fox")
        try await waitUntil("scan done") { !model.search.isSearching && model.search.matchCount == 3 }
        let firstGeneration = try #require(model.search.highlights.current?.generation)

        model.search.next()
        #expect(model.search.currentIndex == 1)
        model.search.next()
        #expect(model.search.currentIndex == 2)
        model.search.next() // wraps
        #expect(model.search.currentIndex == 0)
        model.search.previous() // wraps back
        #expect(model.search.currentIndex == 2)
        let lastGeneration = try #require(model.search.highlights.current?.generation)
        #expect(lastGeneration == firstGeneration + 4)
    }

    @Test("navigation direction picks nearBottom for matches at/after the top row")
    func placementFollowsDirection() async throws {
        let model = try await readyModel(threeFoxes)
        model.search.run("fox")
        try await waitUntil("scan done") { !model.search.isSearching && model.search.matchCount == 3 }
        // Simulate the viewport sitting at the last block: match 0 is ABOVE.
        model.anchors.topRow = model.blocks[2].id
        model.scrollTarget = nil
        model.search.next() // from 0 → 1 (block 2, at top row → below/at)
        #expect(model.scrollTargetPlacement == .nearBottom(margin: model.search.scrollMargin))
        model.anchors.topRow = model.blocks[2].id
        model.search.next() // → 2 (same block, still nearBottom)
        model.search.next() // wraps → 0 (block 0, above top row)
        #expect(model.scrollTargetPlacement == .nearTop(margin: model.search.scrollMargin))
    }

    @Test("clear empties results, highlights, and query")
    func clearResets() async throws {
        let model = try await readyModel(threeFoxes)
        model.search.run("fox")
        try await waitUntil("scan done") { model.search.matchCount == 3 }
        model.search.clear()
        #expect(model.search.query.isEmpty)
        #expect(model.search.matchCount == 0)
        #expect(model.search.currentIndex == nil)
        #expect(model.search.highlights == .none)
    }

    @Test("matches inside collapsed expands are counted and navigation expands ancestors")
    func expandAutoExpands() async throws {
        let model = try await readyModel("""
        {"version":1,"type":"doc","content":[
          {"type":"paragraph","content":[{"type":"text","text":"intro"}]},
          {"type":"expand","attrs":{"title":"More"},"content":[
            {"type":"paragraph","content":[{"type":"text","text":"hidden fox"}]}
          ]}
        ]}
        """)
        #expect(model.expandedBlocks.isEmpty) // nothing expanded before the search
        model.search.run("fox")
        try await waitUntil("scan done") { !model.search.isSearching && model.search.matchCount == 1 }
        // Auto-select already navigated to the only match, expanding its
        // ancestor chain and requesting the scroll (an expanding target
        // always scrolls — it needs a layout pass to reveal the body).
        #expect(model.search.currentIndex == 0)
        #expect(model.expandedBlocks.contains(model.blocks[1].id))
        #expect(model.scrollTarget == model.blocks[1].id)
    }

    @Test("reload resets search state")
    func reloadResets() async throws {
        let model = try await readyModel(threeFoxes)
        model.search.run("fox")
        try await waitUntil("scan done") { model.search.matchCount == 3 }
        model.load(data: Data(threeFoxes.utf8))
        #expect(model.search.matchCount == 0)
        #expect(model.search.highlights == .none)
        try await waitUntil("re-ready") { model.phase == .ready }
    }

    @Test("empty query behaves as clear")
    func emptyQueryClears() async throws {
        let model = try await readyModel(threeFoxes)
        model.search.run("fox")
        try await waitUntil("scan done") { model.search.matchCount == 3 }
        model.search.run("")
        #expect(model.search.matchCount == 0)
        #expect(model.search.highlights == .none)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ADFDocumentSearch`
Expected: compile FAILURE — `model.search` not defined.

- [ ] **Step 3: Implement the controller**

Create `Sources/ADFRendering/Search/ADFDocumentSearch.swift`:

```swift
import Foundation
import Observation
import SwiftUI
import ADFPreparation

/// Find-in-page controller for one `ADFDocumentModel`, exposed as
/// `model.search`. Indexing and matching run OFF the main actor over the
/// `Sendable` prepared blocks; only compact results are published back here.
/// Match counts stream: they keep climbing while the scan (or the document
/// itself) is still loading.
@Observable @MainActor
public final class ADFDocumentSearch {
    // MARK: Observable metadata (the embedder's UI surface)

    public private(set) var query: String = ""
    public private(set) var matchCount: Int = 0
    /// 0-based position of the current match in document order; nil = none.
    public private(set) var currentIndex: Int?
    /// True while a scan (or the index build feeding it) is in flight.
    public private(set) var isSearching: Bool = false
    /// Highlight payload consumed by leaf text views via the environment.
    public private(set) var highlights: ADFSearchHighlights = .none

    // MARK: Configuration

    /// Viewport inset (points) left above/below a match when scrolling to it.
    @ObservationIgnored public var scrollMargin: CGFloat = 40
    /// Delay between `run(_:)` and the scan starting. `.zero` scans at once.
    @ObservationIgnored public var debounceInterval: Duration = .milliseconds(200)

    // MARK: Internal state (never observed — doctrine: high-frequency data
    // lives outside the observation graph)

    @ObservationIgnored internal weak var model: ADFDocumentModel?
    @ObservationIgnored internal let visibleRows = VisibleRowRegistry()
    @ObservationIgnored private var units: [SearchTextUnit] = []
    @ObservationIgnored private var matches: [SearchMatch] = []
    @ObservationIgnored private var blockOrder: [String: Int] = [:]
    @ObservationIgnored private var baseSpans: [String: [SearchHighlightSpan]] = [:]
    @ObservationIgnored private var baseAtoms: Set<String> = []
    @ObservationIgnored private var scannedUnitCount = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    private let scanBatchSize = 256

    public init() {}

    deinit {
        indexTask?.cancel()
        scanTask?.cancel()
        debounceTask?.cancel()
    }

    // MARK: Public API

    /// Sets the query and (after the debounce) restarts the scan. Re-running
    /// the current query is a no-op; an empty query clears.
    public func run(_ query: String) {
        guard query != self.query else { return }
        self.query = query
        debounceTask?.cancel()
        guard !query.isEmpty else {
            clearResults()
            return
        }
        debounceTask = Task { [weak self] in
            guard let self else { return }
            if let interval = self.debounceIntervalIfPositive() {
                try? await Task.sleep(for: interval)
            }
            guard !Task.isCancelled else { return }
            self.startScan()
        }
    }

    public func next() {
        guard !matches.isEmpty else { return }
        navigate(to: ((currentIndex ?? -1) + 1) % matches.count)
    }

    public func previous() {
        guard !matches.isEmpty else { return }
        navigate(to: ((currentIndex ?? 0) - 1 + matches.count) % matches.count)
    }

    /// Ends the search: clears query, results, and every highlight.
    public func clear() {
        query = ""
        debounceTask?.cancel()
        clearResults()
    }

    // MARK: Model hooks (internal)

    /// Called by the model for every appended chunk of top-level blocks.
    /// Index building chains sequentially off-main; an active query scans
    /// the new units as they land, so counts stream during document load.
    func indexAppended(_ chunk: [RenderBlock], theme: ADFTheme) {
        for block in chunk where blockOrder[block.id] == nil {
            blockOrder[block.id] = blockOrder.count
        }
        let previous = indexTask
        indexTask = Task { [weak self] in
            _ = await previous?.value
            guard !Task.isCancelled else { return }
            let indexer = SearchIndexer(theme: theme)
            let newUnits = await Task.detached(priority: .userInitiated) {
                indexer.units(for: chunk)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.units.append(contentsOf: newUnits)
            self.scanAppendedUnitsIfNeeded()
        }
    }

    /// Called on document (re)load: drops the index and every result.
    func reset() {
        indexTask?.cancel()
        indexTask = nil
        query = ""
        debounceTask?.cancel()
        units = []
        blockOrder = [:]
        clearResults()
    }

    // MARK: Scanning

    private func debounceIntervalIfPositive() -> Duration? {
        debounceInterval > .zero ? debounceInterval : nil
    }

    private func clearResults() {
        scanTask?.cancel()
        scanTask = nil
        matches = []
        matchCount = 0
        currentIndex = nil
        isSearching = false
        baseSpans = [:]
        baseAtoms = []
        scannedUnitCount = 0
        highlights = .none
    }

    private func startScan() {
        scanTask?.cancel()
        matches = []
        matchCount = 0
        currentIndex = nil
        baseSpans = [:]
        baseAtoms = []
        scannedUnitCount = 0
        highlights = .none
        isSearching = true
        scanTask = Task { [weak self] in
            await self?.drainScan(autoSelect: true)
        }
    }

    /// New units arrived while a query is active: resume scanning the tail.
    /// If a scan loop is already running it re-checks `units.count` each
    /// iteration and picks the tail up itself.
    private func scanAppendedUnitsIfNeeded() {
        guard !query.isEmpty, !isSearching else { return }
        isSearching = true
        scanTask = Task { [weak self] in
            await self?.drainScan(autoSelect: false)
        }
    }

    /// Scans units in batches; matching runs detached, results append on the
    /// main actor between batches — that is the "streamed counts" surface.
    private func drainScan(autoSelect: Bool) async {
        while scannedUnitCount < units.count {
            let start = scannedUnitCount
            let end = min(start + scanBatchSize, units.count)
            let batch = Array(units[start..<end])
            let query = self.query
            let found = await Task.detached(priority: .userInitiated) {
                SearchMatcher.matches(in: batch, unitIndexOffset: start, query: query)
            }.value
            guard !Task.isCancelled else { return }
            scannedUnitCount = end
            appendMatches(found)
        }
        isSearching = false
        if autoSelect, currentIndex == nil, !matches.isEmpty {
            navigate(to: initialSelectionIndex())
        }
    }

    private func appendMatches(_ found: [SearchMatch]) {
        guard !found.isEmpty else { return }
        matches.append(contentsOf: found)
        matchCount = matches.count
        for match in found {
            let unit = units[match.unitIndex]
            let painted = SearchMatcher.spans(for: match.range, in: unit)
            if !painted.textSpans.isEmpty {
                baseSpans[unit.ownerID, default: []].append(contentsOf: painted.textSpans)
            }
            baseAtoms.formUnion(painted.atomIDs)
        }
        highlights = ADFSearchHighlights(
            spansByOwner: baseSpans,
            matchedAtomIDs: baseAtoms,
            current: highlights.current
        )
    }

    // MARK: Navigation

    /// Browser behavior: the first match at/after the current viewport top.
    private func initialSelectionIndex() -> Int {
        guard let topRow = model?.anchors.topRow, let topOrder = blockOrder[topRow] else {
            return 0
        }
        return matches.firstIndex { match in
            (blockOrder[units[match.unitIndex].topLevelBlockID] ?? .max) >= topOrder
        } ?? 0
    }

    private func navigate(to index: Int) {
        guard let model, matches.indices.contains(index) else { return }
        currentIndex = index
        let match = matches[index]
        let unit = units[match.unitIndex]
        let painted = SearchMatcher.spans(for: match.range, in: unit)
        generation += 1
        highlights = ADFSearchHighlights(
            spansByOwner: baseSpans,
            matchedAtomIDs: baseAtoms,
            current: .init(
                ownerID: unit.ownerID,
                spans: painted.textSpans,
                atomIDs: Set(painted.atomIDs),
                generation: generation
            )
        )

        // Matches inside collapsed expands: open every ancestor first. The
        // expand needs a layout pass to reveal the body, so always scroll.
        let needsExpansion = !unit.expandAncestorIDs.allSatisfy(model.expandedBlocks.contains)
        if needsExpansion {
            model.expandedBlocks.formUnion(unit.expandAncestorIDs)
        }

        let target = unit.topLevelBlockID
        if !needsExpansion, visibleRows.isVisible(target) {
            return // On screen: restyle + flash only, no scroll.
        }
        let placement: ADFScrollTargetPlacement
        if let topRow = model.anchors.topRow,
           let topOrder = blockOrder[topRow],
           let targetOrder = blockOrder[target],
           targetOrder < topOrder {
            placement = .nearTop(margin: scrollMargin)
        } else if model.anchors.topRow == nil || blockOrder[model.anchors.topRow ?? ""] == nil {
            placement = .nearTop(margin: scrollMargin)
        } else {
            placement = .nearBottom(margin: scrollMargin)
        }
        model.scrollTargetPlacement = placement // BEFORE scrollTarget (observed).
        model.scrollTarget = target
    }
}
```

Append to `Sources/ADFRendering/Search/ADFSearchHighlights.swift`:

```swift
import SwiftUI

private struct ADFDocumentSearchKey: EnvironmentKey {
    static let defaultValue: ADFDocumentSearch? = nil
}

extension EnvironmentValues {
    /// The document's search controller, injected by `ADFDocumentView` so
    /// leaf text views can observe `highlights` without the document view
    /// ever re-evaluating (the reference itself never changes).
    public var adfDocumentSearch: ADFDocumentSearch? {
        get { self[ADFDocumentSearchKey.self] }
        set { self[ADFDocumentSearchKey.self] = newValue }
    }
}
```

- [ ] **Step 4: Wire the model**

In `Sources/ADFRendering/ADFDocumentModel.swift`:

1. Add stored properties (after `sections`):

```swift
    /// Find-in-page controller for this document (`run`/`next`/`previous`/
    /// `clear`, streamed `matchCount`, highlight payload). One per model.
    public let search: ADFDocumentSearch

    /// Expand blocks currently open, keyed by block ID. Owned here (not view
    /// `@State`) so expansion survives rows collapsing to spacers, and so
    /// search navigation can open expands programmatically.
    public var expandedBlocks: Set<String> = []
```

2. In `init`, after `self.theme = theme`:

```swift
        self.search = ADFDocumentSearch()
        self.search.model = self
```

3. In `load(data:)`, alongside the other resets (after `scrollTarget = nil`):

```swift
        scrollTargetPlacement = .top
        expandedBlocks = []
        search.reset()
```

4. At the top of `append(_ chunk:)`:

```swift
        search.indexAppended(chunk, theme: theme)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ADFDocumentSearch` → PASS (7 tests). Then `swift test` → all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/ADFRendering/Search Sources/ADFRendering/ADFDocumentModel.swift Tests/ADFRenderingTests/ADFDocumentSearchTests.swift
git commit -m "feat: add ADFDocumentSearch controller with streamed scan and navigation"
```

---

### Task 8: Leaf view integration — highlights, flash, atom pills

**Files:**
- Modify: `Sources/ADFRendering/Inline/SegmentedTextView.swift` (ownerID, paint, flash, atom-ID tokens)
- Modify: `Sources/ADFRendering/Blocks/CodeBlockView.swift` (ownerID, paint, flash)
- Modify: `Sources/ADFRendering/BlockView.swift`, `Blocks/RichTextBlockView.swift`, `Blocks/ListBlockView.swift`, `Media/MediaBlockView.swift` (thread ownerID)
- Test: existing suites must stay green (`BaselineOffsetScalingTests` exercises `SegmentedTextView` statics); behavior verified live in Task 11.

**Interfaces:**
- Consumes: `\.adfDocumentSearch`, `\.adfTheme`, `SearchHighlightPainter`, `ADFSearchHighlights`.
- Produces: `SegmentedTextView(segments:ownerID:)` (ownerID `String?` default nil = search-inert), `CodeBlockView(language:code:ownerID:)`, `RichTextBlockView(segments:style:ownerID:)`, `InlineToken.Kind.atom(InlineAtom, id: String)`.

- [ ] **Step 1: Extend SegmentedTextView**

Replace the declaration/body portion of `Sources/ADFRendering/Inline/SegmentedTextView.swift` (keep `scalingBaselineOffsets`, `mergedText`, `isLineBreak`, `WrappingInlineLayout`, `LineBreakLayoutKey` as they are):

```swift
struct SegmentedTextView: View {
    let segments: [InlineSegment]
    /// ID search highlights are keyed by (`RenderBlock.id`, list-row id, or
    /// media id). `nil` opts out of search entirely (previews, chrome).
    var ownerID: String? = nil

    /// Gap between wrapped lines, scaled with Dynamic Type so line rhythm
    /// tracks the text size it separates.
    @ScaledMetric(relativeTo: .body) private var lineSpacing: CGFloat = 3

    /// The live Dynamic Type factor: `1` at the default size, growing with
    /// larger accessibility sizes. Used to scale sub/superscript baseline
    /// offsets, which are baked as fixed points at preparation time and would
    /// otherwise stay put while the font grew.
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    @Environment(\.adfDocumentSearch) private var search
    @Environment(\.adfTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Flash off-phase: while true the current match paints with the subtle
    /// color, so alternating it blinks the accent (§ arrival flash).
    @State private var flashDimmed = false

    var body: some View {
        let displayed = displayedSegments
        Group {
            if let merged = Self.mergedText(displayed) {
                Text(Self.scalingBaselineOffsets(in: merged, by: typeScale))
            } else {
                WrappingInlineLayout(lineSpacing: lineSpacing) {
                    ForEach(Self.tokens(for: displayed)) { token in
                        InlineTokenView(
                            token: token,
                            typeScale: typeScale,
                            atomHighlight: atomHighlight(for: token)
                        )
                    }
                }
            }
        }
        .task(id: flashTrigger) { await runFlash() }
    }

    // MARK: Search highlighting

    /// The zero-work gate: rows without matches return the stored segments
    /// untouched (no copy, no scan) — the path every row takes while
    /// scrolling with no search active, and every unmatched row during one.
    private var displayedSegments: [InlineSegment] {
        guard let ownerID, let highlights = search?.highlights, highlights.isActive else {
            return segments
        }
        let spans = highlights.spansByOwner[ownerID] ?? []
        let currentSpans = highlights.current?.ownerID == ownerID
            ? (highlights.current?.spans ?? []) : []
        guard !spans.isEmpty || !currentSpans.isEmpty else { return segments }
        return SearchHighlightPainter.paint(
            segments: segments,
            spans: spans,
            currentSpans: currentSpans,
            theme: theme,
            dimCurrent: flashDimmed
        )
    }

    private func atomHighlight(for token: InlineToken) -> AtomHighlightState? {
        guard case .atom(_, let id) = token.kind,
              let highlights = search?.highlights, highlights.isActive else { return nil }
        if let current = highlights.current, current.atomIDs.contains(id) {
            return .current(dimmed: flashDimmed)
        }
        return highlights.matchedAtomIDs.contains(id) ? .subtle : nil
    }

    // MARK: Arrival flash

    private struct FlashTrigger: Equatable {
        let generation: Int
        let isCurrentOwner: Bool
    }

    private var flashTrigger: FlashTrigger {
        let current = search?.highlights.current
        return FlashTrigger(
            generation: current?.generation ?? 0,
            isCurrentOwner: ownerID != nil && current?.ownerID == ownerID
        )
    }

    /// Two accent→subtle pulses (~500 ms). Runs when this view holds the
    /// current match after a navigation — including when the row only
    /// materializes after the scroll lands (flash on arrival). Reduce Motion
    /// keeps the steady accent instead.
    private func runFlash() async {
        flashDimmed = false
        guard flashTrigger.isCurrentOwner, flashTrigger.generation > 0, !reduceMotion else {
            return
        }
        for _ in 0..<2 {
            try? await Task.sleep(for: .milliseconds(130))
            guard !Task.isCancelled else { return }
            flashDimmed = true
            try? await Task.sleep(for: .milliseconds(130))
            guard !Task.isCancelled else { return }
            flashDimmed = false
        }
    }
    // … keep scalingBaselineOffsets / mergedText / isLineBreak unchanged …
```

Update `tokens(for:)`'s atom arm to keep the ID:

```swift
            case .atom(let atom, let id):
                tokens.append(InlineToken(id: tokens.count, kind: .atom(atom, id: id)))
```

Update `InlineToken` and `InlineTokenView`:

```swift
/// One unit placed by `WrappingInlineLayout`.
struct InlineToken: Identifiable, Hashable {
    enum Kind: Hashable {
        case text(AttributedString)
        case atom(InlineAtom, id: String)
        case lineBreak
    }

    let id: Int
    let kind: Kind
}

/// Whole-pill search emphasis for atoms (pills are plain `Text`, not
/// range-highlightable, so a matched pill tints entirely).
enum AtomHighlightState: Equatable {
    case subtle
    case current(dimmed: Bool)
}

struct InlineTokenView: View {
    let token: InlineToken
    /// Live Dynamic Type factor for scaling sub/superscript baseline offsets
    /// on word-chunk text tokens (see `SegmentedTextView`).
    var typeScale: CGFloat = 1
    var atomHighlight: AtomHighlightState? = nil

    @Environment(\.adfTheme) private var theme

    var body: some View {
        switch token.kind {
        case .text(let text):
            Text(SegmentedTextView.scalingBaselineOffsets(in: text, by: typeScale))
        case .atom(let atom, _):
            AtomView(atom: atom)
                .background {
                    if let atomHighlight {
                        RoundedRectangle(cornerRadius: theme.chipCornerRadius)
                            .fill(highlightColor(atomHighlight))
                    }
                }
        case .lineBreak:
            Color.clear
                .frame(width: 0, height: 0)
                .layoutValue(key: LineBreakLayoutKey.self, value: true)
        }
    }

    private func highlightColor(_ state: AtomHighlightState) -> Color {
        switch state {
        case .subtle, .current(dimmed: true):
            return theme.searchHighlight
        case .current(dimmed: false):
            return theme.searchCurrentHighlight
        }
    }
}
```

- [ ] **Step 2: Extend CodeBlockView**

In `Sources/ADFRendering/Blocks/CodeBlockView.swift`, add the same machinery around its single string:

```swift
struct CodeBlockView: View {
    let language: String?
    let code: AttributedString
    /// `RenderBlock.id`; nil opts out of search (previews).
    var ownerID: String? = nil

    @Environment(\.adfTheme) private var theme
    @Environment(\.adfDocumentSearch) private var search
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flashDimmed = false
```

Replace `Text(code)` inside the horizontal ScrollView with `Text(displayedCode)`, add below `copyCode()`:

```swift
    /// Zero-work gate: unmatched code blocks return the stored string as-is.
    private var displayedCode: AttributedString {
        guard let ownerID, let highlights = search?.highlights, highlights.isActive else {
            return code
        }
        let spans = highlights.spansByOwner[ownerID] ?? []
        let currentSpans = highlights.current?.ownerID == ownerID
            ? (highlights.current?.spans ?? []) : []
        guard !spans.isEmpty || !currentSpans.isEmpty else { return code }
        return SearchHighlightPainter.paint(
            text: code, spans: spans, currentSpans: currentSpans,
            theme: theme, dimCurrent: flashDimmed
        )
    }

    private struct FlashTrigger: Equatable {
        let generation: Int
        let isCurrentOwner: Bool
    }

    private var flashTrigger: FlashTrigger {
        let current = search?.highlights.current
        return FlashTrigger(
            generation: current?.generation ?? 0,
            isCurrentOwner: ownerID != nil && current?.ownerID == ownerID
        )
    }

    private func runFlash() async {
        flashDimmed = false
        guard flashTrigger.isCurrentOwner, flashTrigger.generation > 0, !reduceMotion else {
            return
        }
        for _ in 0..<2 {
            try? await Task.sleep(for: .milliseconds(130))
            guard !Task.isCancelled else { return }
            flashDimmed = true
            try? await Task.sleep(for: .milliseconds(130))
            guard !Task.isCancelled else { return }
            flashDimmed = false
        }
    }
```

and attach `.task(id: flashTrigger) { await runFlash() }` to the outer `VStack`.

- [ ] **Step 3: Thread ownerID to the leaves**

- `Sources/ADFRendering/Blocks/RichTextBlockView.swift`: add `var ownerID: String? = nil` and pass it: `SegmentedTextView(segments: segments, ownerID: ownerID)`.
- `Sources/ADFRendering/BlockView.swift`: pass IDs in the switch:
  ```swift
        case .richText(let segments, let style):
            RichTextBlockView(segments: segments, style: style, ownerID: block.id)
        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code, ownerID: block.id)
  ```
- `Sources/ADFRendering/Blocks/ListBlockView.swift` (`ListRowView.body`): `SegmentedTextView(segments: row.segments, ownerID: row.id)`.
- `Sources/ADFRendering/Media/MediaBlockView.swift` (caption site, line ~33): `SegmentedTextView(segments: caption, ownerID: media.id)` — adjust to the local property name for the `PreparedMedia` value in that view.

- [ ] **Step 4: Build and run the full suite**

Run: `swift build && swift test`
Expected: everything compiles (strict concurrency clean) and all tests pass — highlight rendering is inert without an injected search (env default nil).

- [ ] **Step 5: Commit**

```bash
git add Sources/ADFRendering
git commit -m "feat: paint search highlights and arrival flash in leaf text views"
```

---

### Task 9: Expand external state, row visibility, document-view injection

**Files:**
- Modify: `Sources/ADFRendering/Blocks/ExpandBlockView.swift` (model-backed expansion)
- Modify: `Sources/ADFRendering/BlockView.swift` (pass expand block id)
- Modify: `Sources/ADFRendering/ADFDocumentView.swift` (env injection, visibility feed)
- Test: full suite green; live behavior in Task 11.

**Interfaces:**
- Consumes: `model.expandedBlocks` (via `\.adfDocumentSearch.model`), `VisibleRowRegistry`, `onScrollVisibilityChange` (iOS 18+/macOS 15+).
- Produces: `ExpandBlockView(id:title:bodyNodes:isNested:)`; rows report viewport visibility; `ADFDocumentView` injects `\.adfDocumentSearch`.

- [ ] **Step 1: Externalize expand state**

Replace `Sources/ADFRendering/Blocks/ExpandBlockView.swift`'s state handling (keep the visual body structure):

```swift
struct ExpandBlockView: View {
    /// The expand's `RenderBlock.id` — the key in `model.expandedBlocks`.
    let id: String
    let title: String
    let bodyNodes: [ADFNode]
    let isNested: Bool

    @Environment(\.adfTheme) private var theme
    @Environment(\.adfDocumentSearch) private var search
    /// Fallback when rendered outside ADFDocumentView (previews): behaves
    /// like the old private state.
    @State private var localExpanded = false
    @State private var preparedBody: [RenderBlock]?

    private var model: ADFDocumentModel? { search?.model }

    /// Expansion lives on the model so it survives the row collapsing to a
    /// spacer (fixes silent re-collapse on scroll-away) and so search
    /// navigation can open expands programmatically.
    private var isExpanded: Bool {
        model?.expandedBlocks.contains(id) ?? localExpanded
    }

    private func toggle() {
        withAnimation(.snappy) {
            if let model {
                if model.expandedBlocks.contains(id) {
                    model.expandedBlocks.remove(id)
                } else {
                    model.expandedBlocks.insert(id)
                }
            } else {
                localExpanded.toggle()
            }
        }
    }
```

In the body, the Button action becomes `toggle()` (remove the old `withAnimation` wrapper there — `toggle()` animates). Everything else (label, `if isExpanded` body, `prepareBodyIfNeeded`) stays as is.

In `Sources/ADFRendering/BlockView.swift`:

```swift
        case .expand(let title, let bodyNodes, let isNested):
            ExpandBlockView(id: block.id, title: title, bodyNodes: bodyNodes, isNested: isNested)
```

- [ ] **Step 2: Feed row visibility and inject the search environment**

In `Sources/ADFRendering/ADFDocumentView.swift`:

1. Add to the environment injection list in `body`:

```swift
        .environment(\.adfDocumentSearch, model.search)
```

2. Pass the registry into rows (in `rows`):

```swift
                        DocumentRow(
                            block: block,
                            margin: model.theme.spacing * 2,
                            containerWidth: containerWidth,
                            visibility: model.search.visibleRows
                        )
```

3. In `DocumentRow`, add the property and the reporting modifier:

```swift
    let visibility: VisibleRowRegistry
```

and on the `Group` (after `.onDisappear { … }`), replacing the plain `.onDisappear`:

```swift
        .onAppear { isInRenderRegion = true }
        .onDisappear {
            isInRenderRegion = false
            // Render-region exit implies viewport exit; also covers removal
            // paths where the visibility callback never fires a final false.
            visibility.setVisible(block.id, false)
        }
        .reportScrollVisibility(id: block.id, to: visibility)
```

4. Add the availability-gated helper at file bottom:

```swift
extension View {
    /// Reports genuine viewport visibility (not render-region membership) to
    /// the registry on iOS 18+/macOS 15+. Earlier OSes report nothing, so
    /// `VisibleRowRegistry.isVisible` stays false and search always scrolls.
    /// The 0.95 threshold ≈ "fully visible": partially clipped matches still
    /// get a scroll that brings them fully inside the margin.
    @ViewBuilder
    func reportScrollVisibility(id: String, to registry: VisibleRowRegistry) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            onScrollVisibilityChange(threshold: 0.95) { visible in
                registry.setVisible(id, visible)
            }
        } else {
            self
        }
    }
}
```

- [ ] **Step 3: Build and run the full suite**

Run: `swift build && swift test`
Expected: all pass. (`ADFDocumentSearchTests.expandAutoExpands` from Task 7 already covers the model side; the view side is exercised live in Task 11.)

- [ ] **Step 4: Commit**

```bash
git add Sources/ADFRendering
git commit -m "feat: model-backed expand state, viewport visibility feed, search env injection"
```

---

### Task 10: Demo search bar

**Files:**
- Create: `Demo/ADFReader/SearchBar.swift`
- Modify: `Demo/ADFReader/ReaderView.swift`

**Interfaces:**
- Consumes: `model.search` (`ADFDocumentSearch` public API only — this proves the embedder surface).
- Produces: a search toolbar button on `ReaderView`; bottom bar with live query field, `current / total` counter with progress spinner, prev/next chevrons, Done.

- [ ] **Step 1: Create the bar**

Create `Demo/ADFReader/SearchBar.swift`:

```swift
import SwiftUI
import ADFRendering

/// Bottom find-in-page bar: query field, streamed "current / total" counter,
/// previous/next, and Done. All state lives in the library's
/// `ADFDocumentSearch`; this view is a thin shell over it.
struct SearchBar: View {
    let search: ADFDocumentSearch
    @Binding var isPresented: Bool

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find in page", text: $text)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($isFocused)
                    .onSubmit { search.next() }
                    .onChange(of: text) { _, newValue in
                        search.run(newValue)
                    }
                if search.isSearching {
                    ProgressView()
                        .controlSize(.small)
                } else if !text.isEmpty {
                    Text(counterText)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))

            Button {
                search.previous()
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(search.matchCount == 0)
            .accessibilityLabel("Previous match")

            Button {
                search.next()
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(search.matchCount == 0)
            .accessibilityLabel("Next match")

            Button("Done") {
                search.clear()
                isPresented = false
            }
            .fontWeight(.semibold)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onAppear { isFocused = true }
    }

    private var counterText: String {
        guard search.matchCount > 0 else { return "0" }
        return "\((search.currentIndex ?? 0) + 1) / \(search.matchCount)"
    }
}
```

- [ ] **Step 2: Mount it in ReaderView**

In `Demo/ADFReader/ReaderView.swift`:

1. Add state: `@State private var searchPresented = false`
2. After `.toolbar { toolbarContent }` add:

```swift
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if searchPresented {
                    SearchBar(search: model.search, isPresented: $searchPresented)
                }
            }
```

3. Add a third toolbar item (before the TOC menu in `toolbarContent`):

```swift
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                withAnimation(.snappy) { searchPresented.toggle() }
                if !searchPresented { model.search.clear() }
            } label: {
                Label("Find in Page", systemImage: "magnifyingglass")
            }
        }
```

- [ ] **Step 3: Build the demo**

```bash
cd Demo && xcodegen generate && xcodebuild -project ADFReader.xcodeproj -scheme ADFReader \
  -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5; cd ..
```

Expected: `BUILD SUCCEEDED` (strict concurrency + warnings-as-errors clean).

- [ ] **Step 4: Commit**

```bash
git add Demo/ADFReader/SearchBar.swift Demo/ADFReader/ReaderView.swift
git commit -m "feat: add find-in-page search bar to the ADFReader demo"
```

---

### Task 11: Verification — perf gates + live behavior + docs

**Files:**
- Modify: `docs/Architecture-Decisions.md` (append a short "Text search" section documenting: env-injected observable search controller, leaf-applied highlights with zero-work gate, visibility-gated margin scrolling, expand-state lifting, v1 exclusions)
- No product code changes expected; fixes discovered here are their own commits.

**This task follows the repo's verification doctrine. Run every check; report numbers, not adjectives.**

- [ ] **Step 1: Full unit suite** — `swift test` → all pass (baseline 112 + ~25 new).

- [ ] **Step 2: Boot the demo on a simulator with kitchen-sink**

```bash
xcrun simctl list devices | grep -i booted   # reuse a booted sim if present (shared-sim etiquette)
cd Demo && xcodegen generate && xcodebuild -project ADFReader.xcodeproj -scheme ADFReader \
  -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -3 && cd ..
xcrun simctl install <UDID> <DerivedData app path>
xcrun simctl launch --console-pty <UDID> com.connie.adfreader -fixture kitchen-sink
```

Wait for the `READY fixture=… blocks=…` line.

- [ ] **Step 3: Live find-in-page checks** (drive with axe per the project's simulator automation memory; screenshot each state via `xcrun simctl io <UDID> screenshot`)

1. Tap the magnifying glass → bar appears, keyboard up.
2. Type a common word from the fixture → counter climbs, subtle highlights visible, first match at/after viewport gets the accent + flashes.
3. Next repeatedly: current match advances, wraps at the end; off-screen matches scroll in with ~40 pt margin (top when approaching from below, bottom when from above); on-screen matches do NOT scroll (iOS 18 sim).
4. Previous: same in reverse.
5. A match inside a collapsed expand: expand opens automatically, scrolls, inner match highlighted + flashes.
6. Match in a table cell and in a code block: highlights render; navigation lands on the right slice.
7. Search a mention/status pill's text: pill highlights whole.
8. Done → all highlights clear instantly.
9. Expand a section manually, scroll far away and back → it STAYS expanded (the lifted-state bug fix).

- [ ] **Step 4: Perf gates** (all Debug-simulator vs a fresh same-build-type baseline from `main`; document both numbers)

1. Baseline: `git stash` nothing — instead check out `main` in the primary checkout or use the pre-change commit; run `-fixture stress-5k -autoscroll`, record `SCROLL_METRICS … hitchRatioMsPerS` (expect ~10.3 ms/s Debug-sim).
2. Branch, search idle: same run → within noise of baseline.
3. Branch, search active: launch stress-5k, activate search with a high-frequency letter (e.g. "e", thousands of matches), then `-autoscroll` equivalent via 12 axe flings; hitch ratio must stay within noise.
4. **Fling-and-watch-CPU** (mandatory — the autoscroll gate misses livelocks): 12 axe swipes, then `ps -o %cpu -p $(pgrep -f ADFReader)` must settle to ~0.0 within a few seconds, with and without an active query.
5. Rotation round-trip during active search: `notifyutil -p com.connie.adfreader.rotate` twice → reader keeps its place, highlights intact, no trailing blank space.

- [ ] **Step 5: Docs + final commit**

Append the "Text search" section to `docs/Architecture-Decisions.md`, then:

```bash
git add docs/Architecture-Decisions.md
git commit -m "docs: record the text-search architecture decisions"
```

- [ ] **Step 6: Report** — summarize test counts, perf numbers (baseline vs branch), and the live checklist outcomes. Surface any deviation instead of adjusting gates.

---

## Plan Self-Review Notes

- **Spec coverage:** streamed counts (Task 7 `drainScan` batches), navigation + wrap (Task 7), highlights all/current (Tasks 5, 8), flash + reduce-motion (Task 8), visibility-gated scroll with margin (Tasks 6, 7, 9), clear API (Task 7), expand find/auto-expand + state-lift bug fix (Tasks 3, 7, 9), demo bar (Task 10), atom pills (Tasks 1, 4, 8), table/nested mapping (Task 2), perf gates (Task 11). v1 exclusions and block-granularity scrolling documented in Global Constraints and Task 11 docs step.
- **Type consistency:** `SearchTextUnit/Part/SearchMatch/SearchHighlightSpan` (Task 1) are consumed with identical shapes in Tasks 4, 5, 7, 8. `ADFScrollTargetPlacement.anchor(viewportHeight:)` (Task 6) is what Task 7 sets and Task 6's consumer reads. `ownerID` naming is uniform across Tasks 1, 7, 8.
- **Known judgment calls for implementers:** exact local property names at the `MediaBlockView` caption site and `ReaderView` insertion points may differ by a line or two — match the surrounding code; do not restructure.
