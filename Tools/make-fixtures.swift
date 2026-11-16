#!/usr/bin/env swift
// make-fixtures.swift — deterministic stress-fixture generator for ADFKit.
//
// Run from anywhere (paths resolve relative to this file):
//     swift Tools/make-fixtures.swift
//     swift Tools/make-fixtures.swift --check
//     swift Tools/make-fixtures.swift --landmarks
// The second form regenerates every fixture in memory, writes nothing and
// exits 1 if any generated fixture differs from its bytes in Fixtures/
// (or is missing), 0 when all match. Fixtures/SHA256SUMS pins the bytes of
// every Fixtures/*.json, hand-authored ones included
// (Tests/ADFModelTests/FixtureManifestTests.swift); the lines above its
// `# PR 4` line never change. The third form writes nothing and prints the
// container and caption fixtures' landmark tables as Markdown (top-level
// blocks with their `-scrollToFraction` landing values, and every sentinel
// owner with its container chain and census class).
//
// Emits into <repo-root>/Fixtures/:
//   stress-5k.json      5,000 mixed top-level blocks (paragraphs with mixed
//                       marks, headings, 4-deep lists, code blocks, panels,
//                       a blockquote every ~10 blocks, plus groups of 5
//                       consecutive expands every 50 blocks whose bodies cycle
//                       through 10 recipes covering every node family:
//                       lists/tasks/decisions, tables with nestedExpand,
//                       layout columns, media, cards, inline nodes,
//                       extensions and sync blocks)
//   stress-1k.json      the first 1,000 blocks of stress-5k, byte for byte
//                       the same nodes — the per-PR perf gate's stress
//                       fixture (a full stress-5k scroll is ~8.5 min/trial)
//   giant-table.json    800 data rows x 6 columns, header row, sprinkled
//                       colspans and cell backgrounds
//   media-gallery.json  300 mediaSingle nodes with width/height attrs,
//                       external urls "placeholder://<n>", every layout value
//   text-dense.json     3,000 text-only top-level blocks for the TextKit 2
//                       perf gate: mixed-mark paragraphs (occasional hard
//                       breaks and emoji characters) with a heading every
//                       8th block (levels cycle 1–6). No inline atoms, so
//                       every block is TextKit 2 eligible.
//   long-paragraph.json one ~20,000-character paragraph (mixed marks, hard
//                       breaks, emoji and combining sequences as plain text)
//                       between an H1 and a closing paragraph — the per-row
//                       full-layout worst case. The trailing block gives the
//                       autoscroller a leg that crosses the whole paragraph.
//   lists-parity.json   hand-authored (no RNG) compact list fixture for the
//                       TextKit 2 list stage: all four list families, five
//                       nesting levels with alternating ordered/bullet
//                       ancestry, ordered starts and 9→10 / z→aa / roman
//                       boundaries, tasks done/undone, wrapping leaders,
//                       marks, links, hard breaks, Unicode/RTL, atom-bearing
//                       leaders, empty and non-paragraph first children,
//                       continuations, embedded excluded blocks, trailing
//                       `.listRows` (sync block, malformed item child) and
//                       lists inside excluded containers. Every row carries
//                       a unique `LP-…` sentinel; root order and node paths
//                       are pinned by ADFPreparationTests — append new cases
//                       just before `LP-END`, never reorder.
//   list-dense.json     600 root lists (bullet 210, ordered 180, task 120,
//                       decision 90) for the list perf gate: mixed nesting,
//                       continuations, multi-paragraph items, trailing
//                       headings, plain/marked/linked/atom-bearing leaves
//                       (atoms ≈10 %, the declared fallback share). Sized so
//                       the demo autoscroll estimator (Σ estimated height /
//                       1,200 pt/s) lands in the stress-1k class (100–150 s);
//                       the generator prints its emitted-node tally.
//   list-tall.json      one ordered root list of 316 rows (200 items, 50
//                       nested 2-item bullet lists, 16 continuation
//                       paragraphs; plain text only) plus a 1-item closing
//                       list, so the autoscroll's last leg crosses the whole
//                       tall root — the eager-inside-root bound (`-fixture
//                       list-tall`). No root paragraph or heading: every
//                       text owner in it is a list row or list trailing block.
//   lists-links.json    hand-authored (no RNG) linked list text for the
//                       interaction UI tests (exact-URL routing): a link
//                       that wraps across lines, a coloured link, links
//                       directly between emoji, Hebrew and Arabic
//                       paragraphs with RTL and LTR links, a link on a later
//                       line, two links in one leader, a linked continuation
//                       paragraph and trailing paragraph, and linked task and
//                       decision leaders (with plain controls). Every link
//                       has its own https://example.com/lists-links/<slug>
//                       URL and every leaf a unique `LL-…` sentinel. Not
//                       part of arm A, visual parity or the perf designs.
//   code-parity.json    compact code-block fixture for the TextKit 2 code
//                       stage: 24 top-level code blocks under headings
//                       `CP-S1`…`CP-S6` (plain ASCII shapes and a wide
//                       block to pan; breakout wide/full-width; blank
//                       lines, trailing newlines, whitespace; the canvas
//                       budget boundary; tabs, emoji/CJK, combining marks,
//                       Hebrew/Arabic, `""` and `"\n"`), then one code
//                       block inside a bullet item, a panel and an expand.
//                       No table, no media. Each block's first non-empty
//                       line carries `CP-<nn>` (the two blocks without
//                       text carry it as their language). Top-level node
//                       index = block id `0.<index>`; append new cases
//                       just before `CP-END`, never reorder.
//   code-dense.json     600 top-level code blocks and nothing else, for the
//                       code perf gate: exact line-count and width quotas
//                       paired by a seeded shuffle, first line
//                       `// CD-<iii>`, printable ASCII and line feeds only.
//                       A block over the canvas budget has its widest line
//                       shortened (true maximum recomputed after every
//                       cut) except a deliberate 18 (3 %) left over
//                       budget. Sized for 100–150 s of autoscroll; the
//                       generator prints the realised histograms, the
//                       estimate and the hand-countable totals.
//                       `CodeDenseSpec.version` selects the lighten
//                       ladder: 1 (the default) is this fixture; 2 and 3
//                       are two fixed lighter versions (the tallest and
//                       widest blocks moved down a bucket), declared
//                       before any timing of the fixture exists.
//   code-tall.json      a 400-line, 60-column code block (over the canvas
//                       budget), the largest 60-column block declared
//                       under it, and a short closing block (`-fixture
//                       code-tall`; an ungated pilot like list-tall).
//                       Then a heading `CT-SEQ` and a bounded near-limit
//                       sequence: eight consecutive blocks, each just
//                       under the budget, from narrow and tall to wide
//                       and short (`// CT-SEQ-1` … `// CT-SEQ-8`), to
//                       read how many near-limit canvases are live at
//                       once. 12 top-level nodes.
//   containers-parity.json  hand-authored (no RNG, except the seeded code
//                       text) compact container fixture for the TextKit 2
//                       container stage: panels in every palette and
//                       custom colours, quotes three deep, bodied and
//                       bodiless extensions, sync blocks, columns 25/75,
//                       33/67, 50/50 and 33/33/33 plus the edge widths
//                       (0, negative, all ≤ 0, an indented leaf), expands
//                       and nested expands, lists and code inside every
//                       container (PR 3's admitted cohort plus one block
//                       over budget), and the out-of-scope negatives
//                       (tables, a plugin embed card, containers inside a
//                       list item). Every leaf carries a unique `KP-…`
//                       sentinel; root order is pinned by
//                       ADFPreparationTests — append before `KP-END`.
//   containers-dense.json  800 top-level containers (panel 6, quote 5,
//                       columns 5, extension 4 per 20) plus one closed
//                       expand per 20, for the container perf gate: exact
//                       leaf-count, role and mark-class quotas per group,
//                       nested quote/panel bodies, 12 nested code blocks;
//                       each container's first leaf starts `KD-<iiii>`.
//                       No table, no media. Sized for 100–150 s of
//                       autoscroll. `ContainersDenseSpec.version` selects
//                       the lighten ladder: 1 (the default) is this
//                       fixture; 2 and 3 move the containers to fewer
//                       leaves each, declared before any timing exists.
//   containers-expand.json  block 0 is a closed three-level expand chain
//                       whose deepest body holds the search sentinel
//                       `CXOPENSENTINEL` (exactly once in the file), then a
//                       plain tail sized for ≥ 40 s of autoscroll, then
//                       headings `CE-S2`…`CE-S7` before the lifecycle
//                       expands: CE-TALL (300 plain paragraphs) and
//                       CE-OPEN-1…5 (30–40 eligible leaves, a list, a task
//                       list, a code block and a nested expand each), with
//                       four screens of filler after each.
//   captions-parity.json  hand-authored media captions: none, empty,
//                       plain, marks, a link, a whitespace-only link,
//                       colours, a placeholder, atoms, wrapping with a
//                       hard break, Unicode/RTL; captions inside a panel,
//                       a column and an expand; one caption per
//                       mediaSingle layout. External `placeholder://` media
//                       at a fixed pixel width. Sentinels `CAP-…`.
//
// The three code fixtures size and declare every "over budget" / "just
// under budget" block through `codeBudgetVerdict`, which reads only the
// constants in `CodeCanvasModel` (documented values for the default
// configuration, not measurements — correct them there).
//
// Fully deterministic: seeded LCG, no Date(), no system randomness.
// Output is byte-stable across runs (JSONSerialization + .sortedKeys,
// integer-only numbers). Adding a fixture must never change an existing
// file's bytes: each fixture owns its own seed, and new fixtures append to
// the emit list.

import Foundation

// MARK: - Deterministic RNG (64-bit LCG, Knuth MMIX constants)

struct LCG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    /// Uniform Int in `range` (upper bound excluded).
    mutating func int(_ range: Range<Int>) -> Int {
        range.lowerBound + Int(next() >> 33) % range.count
    }

    mutating func pick<T>(_ values: [T]) -> T {
        values[int(0 ..< values.count)]
    }

    /// True roughly once per `n` calls.
    mutating func oneIn(_ n: Int) -> Bool {
        int(0 ..< n) == 0
    }
}

// MARK: - Word soup

let words = [
    "atlas", "confluence", "document", "render", "swift", "actor", "stream",
    "block", "inline", "mark", "table", "panel", "media", "layout", "expand",
    "vector", "lazy", "scroll", "anchor", "theme", "token", "chunk", "batch",
    "quartz", "signal", "ledger", "matrix", "kernel", "buffer", "cursor",
    "spline", "raster", "glyph", "corpus", "schema", "fixture", "stress",
]

func sentence(_ rng: inout LCG, wordCount: Int) -> String {
    var parts: [String] = []
    parts.reserveCapacity(wordCount)
    for _ in 0 ..< wordCount {
        parts.append(rng.pick(words))
    }
    return parts.joined(separator: " ")
}

// MARK: - Node builders (raw JSON dictionaries)

func textNode(_ text: String, marks: [[String: Any]] = []) -> [String: Any] {
    var node: [String: Any] = ["type": "text", "text": text]
    if !marks.isEmpty { node["marks"] = marks }
    return node
}

func paragraph(_ content: [[String: Any]]) -> [String: Any] {
    ["type": "paragraph", "content": content]
}

/// Pool of valid mark JSON objects; every shape parses cleanly in ADFMark.
func randomMarks(_ rng: inout LCG, index: Int) -> [[String: Any]] {
    let pool: [[String: Any]] = [
        ["type": "strong"],
        ["type": "em"],
        ["type": "underline"],
        ["type": "strike"],
        ["type": "code"],
        ["type": "subsup", "attrs": ["type": "sup"]],
        ["type": "subsup", "attrs": ["type": "sub"]],
        ["type": "textColor", "attrs": ["color": rng.pick(["#ff5630", "#36b37e", "#6554c0", "#00b8d9"])]],
        ["type": "backgroundColor", "attrs": ["color": rng.pick(["#fffae6", "#e3fcef", "#deebff"])]],
        ["type": "link", "attrs": ["href": "https://example.com/page/\(index)"]],
    ]
    switch rng.int(0 ..< 4) {
    case 0: return []
    case 1: return [rng.pick(pool)]
    default:
        // Two distinct picks (may still collide on type; harmless for parsing).
        return [rng.pick(pool), rng.pick(pool)]
    }
}

func mixedParagraph(_ rng: inout LCG, index: Int) -> [String: Any] {
    let runCount = rng.int(1 ..< 5)
    var runs: [[String: Any]] = []
    runs.reserveCapacity(runCount)
    for _ in 0 ..< runCount {
        let text = sentence(&rng, wordCount: rng.int(3 ..< 11)) + " "
        runs.append(textNode(text, marks: randomMarks(&rng, index: index)))
    }
    return paragraph(runs)
}

func heading(_ rng: inout LCG, index: Int) -> [String: Any] {
    [
        "type": "heading",
        "attrs": ["level": 1 + index % 6],
        "content": [textNode("Section \(index): \(sentence(&rng, wordCount: 3))")],
    ]
}

/// Nested list, `depth` levels deep (depth 4 = plan's "lists 4-deep").
func list(_ rng: inout LCG, depth: Int, ordered: Bool) -> [String: Any] {
    let itemCount = rng.int(2 ..< 4)
    var items: [[String: Any]] = []
    items.reserveCapacity(itemCount)
    for i in 0 ..< itemCount {
        var content: [[String: Any]] = [paragraph([textNode(sentence(&rng, wordCount: rng.int(2 ..< 7)))])]
        if depth > 1, i == 0 {
            content.append(list(&rng, depth: depth - 1, ordered: !ordered))
        }
        items.append(["type": "listItem", "content": content])
    }
    var node: [String: Any] = ["type": ordered ? "orderedList" : "bulletList", "content": items]
    if ordered, rng.oneIn(3) {
        node["attrs"] = ["order": rng.int(2 ..< 10)]
    }
    return node
}

func codeBlock(_ rng: inout LCG, index: Int) -> [String: Any] {
    let lineCount = rng.int(3 ..< 9)
    var lines: [String] = []
    lines.reserveCapacity(lineCount)
    for line in 0 ..< lineCount {
        lines.append("let value\(line) = compute(\(rng.int(0 ..< 100)))  // \(rng.pick(words))")
    }
    return [
        "type": "codeBlock",
        "attrs": ["language": rng.pick(["swift", "json", "python", "sql", "bash"])],
        "content": [textNode(lines.joined(separator: "\n"))],
    ]
}

func panel(_ rng: inout LCG, index: Int) -> [String: Any] {
    let panelType = rng.pick(["info", "note", "tip", "warning", "error", "success", "custom"])
    var attrs: [String: Any] = ["panelType": panelType]
    if panelType == "custom" {
        attrs["panelIcon"] = ":rocket:"
        attrs["panelColor"] = "#6554c0"
    }
    return [
        "type": "panel",
        "attrs": attrs,
        "content": [mixedParagraph(&rng, index: index)],
    ]
}

func blockquote(_ rng: inout LCG, index: Int) -> [String: Any] {
    var content = [mixedParagraph(&rng, index: index)]
    if rng.oneIn(2) {
        content.append(paragraph([textNode(sentence(&rng, wordCount: rng.int(4 ..< 9)))]))
    }
    return ["type": "blockquote", "content": content]
}

func doc(_ content: [[String: Any]]) -> [String: Any] {
    ["version": 1, "type": "doc", "content": content]
}

// MARK: - Leaf / inline builders used inside expands

func rule() -> [String: Any] { ["type": "rule"] }

func media(_ rng: inout LCG, index: Int) -> [String: Any] {
    [
        "type": "media",
        "attrs": [
            "type": "file",
            "id": "media-\(index)",
            "collection": "contentId-\(index % 7)",
            "width": 320 + rng.int(0 ..< 9) * 80,
            "height": 240 + rng.int(0 ..< 7) * 80,
            "alt": "Expand image \(index)",
        ] as [String: Any],
    ]
}

func mediaInline(_ index: Int) -> [String: Any] {
    ["type": "mediaInline", "attrs": ["type": "file", "id": "media-inline-\(index)", "collection": "contentId-1"]]
}

func mention(_ index: Int) -> [String: Any] {
    ["type": "mention", "attrs": ["id": "user-\(index)", "text": "@user\(index)", "accessLevel": "CONTAINER"]]
}

func emoji(_ rng: inout LCG) -> [String: Any] {
    let choice = rng.pick([(":smile:", "1f604", "😄"), (":rocket:", "1f680", "🚀"), (":warning:", "26a0", "⚠️")])
    return ["type": "emoji", "attrs": ["shortName": choice.0, "id": choice.1, "text": choice.2]]
}

func date(_ index: Int) -> [String: Any] {
    // Deterministic epoch ms (no system clock): 2024-01-01 plus index days.
    ["type": "date", "attrs": ["timestamp": "\(1_704_067_200_000 + index * 86_400_000)"]]
}

func status(_ rng: inout LCG, index: Int) -> [String: Any] {
    let color = rng.pick(["neutral", "purple", "blue", "red", "yellow", "green"])
    return ["type": "status", "attrs": ["text": color.uppercased(), "color": color, "localId": "st-\(index)"]]
}

func placeholder(_ index: Int) -> [String: Any] {
    ["type": "placeholder", "attrs": ["text": "Type something \(index)"]]
}

func inlineCard(_ index: Int) -> [String: Any] {
    ["type": "inlineCard", "attrs": ["url": "https://example.atlassian.net/wiki/pages/\(index)"]]
}

func blockCard(_ index: Int) -> [String: Any] {
    ["type": "blockCard", "attrs": ["url": "https://example.atlassian.net/browse/ADF-\(index)"]]
}

func embedCard(_ rng: inout LCG, index: Int) -> [String: Any] {
    [
        "type": "embedCard",
        "attrs": [
            "url": "https://example.com/embed/\(index)",
            "layout": rng.pick(["center", "wide", "full-width"]),
            "width": 100,
            "originalWidth": 640,
            "originalHeight": 360,
        ] as [String: Any],
    ]
}

func extensionAttrs(_ key: String, index: Int) -> [String: Any] {
    [
        "extensionType": "com.atlassian.confluence.macro.core",
        "extensionKey": key,
        "text": "\(key) \(index)",
        "parameters": ["macroParams": ["depth": ["value": "\(index % 5)"]]],
        "layout": "default",
        "localId": "ext-\(index)",
    ]
}

func taskList(_ rng: inout LCG, index: Int) -> [String: Any] {
    var items: [[String: Any]] = []
    for i in 0 ..< rng.int(2 ..< 5) {
        items.append([
            "type": "taskItem",
            "attrs": ["localId": "task-\(index)-\(i)", "state": rng.pick(["TODO", "DONE"])] as [String: Any],
            "content": [textNode(sentence(&rng, wordCount: rng.int(3 ..< 8)))],
        ])
    }
    return ["type": "taskList", "attrs": ["localId": "task-list-\(index)"], "content": items]
}

func decisionList(_ rng: inout LCG, index: Int) -> [String: Any] {
    var items: [[String: Any]] = []
    for i in 0 ..< rng.int(1 ..< 4) {
        items.append([
            "type": "decisionItem",
            "attrs": ["localId": "decision-\(index)-\(i)", "state": "DECIDED"] as [String: Any],
            "content": [textNode(sentence(&rng, wordCount: rng.int(3 ..< 8)))],
        ])
    }
    return ["type": "decisionList", "attrs": ["localId": "decision-list-\(index)"], "content": items]
}

/// `nestedExpand` is only schema-legal inside table cells and layout columns.
func nestedExpand(_ rng: inout LCG, index: Int, content: [[String: Any]]) -> [String: Any] {
    [
        "type": "nestedExpand",
        "attrs": ["title": "Nested \(index): \(sentence(&rng, wordCount: 2))"],
        "content": content,
    ]
}

/// Small table (header row + 2 data rows); one cell holds a nestedExpand.
func smallTable(_ rng: inout LCG, index: Int) -> [String: Any] {
    var rows: [[String: Any]] = []
    rows.append([
        "type": "tableRow",
        "content": (0 ..< 3).map { c in
            [
                "type": "tableHeader",
                "attrs": ["background": "#f4f5f7", "colwidth": [180]] as [String: Any],
                "content": [paragraph([textNode("H\(c + 1)", marks: [["type": "strong"]])])],
            ] as [String: Any]
        },
    ])
    for r in 0 ..< 2 {
        var cells: [[String: Any]] = []
        for c in 0 ..< 3 {
            var content: [[String: Any]] = [paragraph([textNode("r\(r)c\(c) \(sentence(&rng, wordCount: rng.int(1 ..< 4)))")])]
            if r == 0, c == 2 {
                content.append(nestedExpand(&rng, index: index, content: [
                    mixedParagraph(&rng, index: index),
                    list(&rng, depth: 2, ordered: false),
                ]))
            }
            var cell: [String: Any] = ["type": "tableCell", "content": content]
            if rng.oneIn(4) { cell["attrs"] = ["background": rng.pick(["#deebff", "#e3fcef"])] }
            cells.append(cell)
        }
        rows.append(["type": "tableRow", "content": cells])
    }
    return ["type": "table", "attrs": ["isNumberColumnEnabled": false, "layout": "default"], "content": rows]
}

func layoutSection(_ rng: inout LCG, index: Int) -> [String: Any] {
    let left: [String: Any] = [
        "type": "layoutColumn",
        "attrs": ["width": 50],
        "content": [
            mixedParagraph(&rng, index: index),
            nestedExpand(&rng, index: index, content: [
                paragraph([textNode(sentence(&rng, wordCount: 6))]),
                codeBlock(&rng, index: index),
            ]),
        ],
    ]
    let right: [String: Any] = [
        "type": "layoutColumn",
        "attrs": ["width": 50],
        "content": [panel(&rng, index: index), taskList(&rng, index: index)],
    ]
    return ["type": "layoutSection", "content": [left, right]]
}

// MARK: - Expand groups

/// Ten content recipes; together they cover every block and inline node family
/// the model knows about. Each expand gets one recipe.
func expandContent(_ rng: inout LCG, recipe: Int, index: Int) -> [[String: Any]] {
    switch recipe {
    case 0: // text basics: marks, hard breaks, headings, rule
        return [
            heading(&rng, index: index),
            paragraph([
                textNode(sentence(&rng, wordCount: 5) + " ", marks: [["type": "strong"], ["type": "em"]]),
                ["type": "hardBreak"],
                textNode(sentence(&rng, wordCount: 5), marks: [["type": "code"]]),
            ]),
            mixedParagraph(&rng, index: index),
            rule(),
        ]
    case 1: // every list family
        return [
            list(&rng, depth: 3, ordered: false),
            list(&rng, depth: 2, ordered: true),
            taskList(&rng, index: index),
            decisionList(&rng, index: index),
        ]
    case 2: // code, panel, quote
        return [codeBlock(&rng, index: index), panel(&rng, index: index), blockquote(&rng, index: index)]
    case 3: // table with a nestedExpand inside a cell
        return [paragraph([textNode("Table inside an expand")]), smallTable(&rng, index: index)]
    case 4: // layout columns, one holding a nestedExpand
        return [layoutSection(&rng, index: index)]
    case 5: // media
        return [
            [
                "type": "mediaSingle",
                "attrs": ["layout": rng.pick(["center", "wide", "full-width", "align-start"])],
                "content": [
                    media(&rng, index: index),
                    ["type": "caption", "content": [textNode("Caption \(index): \(sentence(&rng, wordCount: 3))")]],
                ],
            ],
            ["type": "mediaGroup", "content": [media(&rng, index: index), media(&rng, index: index + 1)]],
            paragraph([textNode("Inline media: "), mediaInline(index), textNode(" trailing.")]),
        ]
    case 6: // smart cards
        return [
            blockCard(index),
            embedCard(&rng, index: index),
            paragraph([textNode("See "), inlineCard(index), textNode(" for details.")]),
        ]
    case 7: // inline node zoo
        return [
            paragraph([
                mention(index), textNode(" shipped on "), date(index), textNode(" "),
                status(&rng, index: index), textNode(" "), emoji(&rng), textNode(" "),
                placeholder(index),
            ]),
            paragraph([
                textNode(sentence(&rng, wordCount: 4) + " ", marks: [["type": "link", "attrs": ["href": "https://example.com/\(index)"]]]),
                textNode("x", marks: [["type": "subsup", "attrs": ["type": "sub"]]]),
                textNode("2", marks: [["type": "subsup", "attrs": ["type": "sup"]]]),
            ]),
        ]
    case 8: // extensions
        return [
            ["type": "extension", "attrs": extensionAttrs("toc", index: index)],
            [
                "type": "bodiedExtension",
                "attrs": extensionAttrs("excerpt", index: index),
                "content": [mixedParagraph(&rng, index: index), list(&rng, depth: 1, ordered: false)],
            ],
            paragraph([textNode("Macro: "), ["type": "inlineExtension", "attrs": extensionAttrs("status-macro", index: index)]]),
        ]
    default: // sync blocks + a mixed tail
        return [
            ["type": "syncBlock", "attrs": ["resourceId": "ari:cloud:confluence:site/sync-\(index)", "localId": "sync-\(index)"]],
            [
                "type": "bodiedSyncBlock",
                "attrs": ["resourceId": "ari:cloud:confluence:site/sync-b-\(index)", "localId": "sync-b-\(index)"] as [String: Any],
                "content": [mixedParagraph(&rng, index: index), panel(&rng, index: index)],
            ],
            rule(),
        ]
    }
}

let expandRecipeCount = 10

func expand(_ rng: inout LCG, recipe: Int, index: Int) -> [String: Any] {
    [
        "type": "expand",
        "attrs": ["title": "Expand \(index) [\(recipe)]: \(sentence(&rng, wordCount: 3))"],
        "content": expandContent(&rng, recipe: recipe, index: index),
    ]
}

// MARK: - Fixture 1: stress-5k.json

func makeStress5K() -> [String: Any] {
    var rng = LCG(seed: 0x5EED_5000)
    var blocks: [[String: Any]] = []
    blocks.reserveCapacity(5000)
    // Expands arrive in groups of 5 consecutive blocks, once every 50 blocks
    // (100 groups, 500 expands). Recipes advance across the whole document so
    // every node family shows up inside an expand many times over.
    let groupSize = 5
    let groupStride = 50
    var expandCount = 0

    for i in 0 ..< 5000 {
        if i % groupStride >= groupStride - groupSize {
            blocks.append(expand(&rng, recipe: expandCount % expandRecipeCount, index: i))
            expandCount += 1
            continue
        }
        switch i % 10 {
        case 0:
            blocks.append(heading(&rng, index: i))
        case 4:
            blocks.append(list(&rng, depth: 4, ordered: false))
        case 5:
            blocks.append(codeBlock(&rng, index: i))
        case 6:
            blocks.append(panel(&rng, index: i))
        case 8:
            blocks.append(list(&rng, depth: rng.int(1 ..< 5), ordered: true))
        case 9:
            blocks.append(blockquote(&rng, index: i)) // a quote every ~10 blocks
        default:
            blocks.append(mixedParagraph(&rng, index: i))
        }
    }
    return doc(blocks)
}

/// The first 1,000 blocks of stress-5k (the per-PR perf gate's stress
/// fixture; the reference build gets this one file added).
func makeStress1K(from stress5K: [String: Any]) -> [String: Any] {
    let blocks = stress5K["content"] as? [[String: Any]] ?? []
    return doc(Array(blocks.prefix(1000)))
}

// MARK: - Fixture 2: giant-table.json

func makeGiantTable() -> [String: Any] {
    var rng = LCG(seed: 0x5EED_0800)
    let columnCount = 6
    let cellBackgrounds = ["#deebff", "#e3fcef", "#fffae6", "#ffebe6"]

    func cell(row: Int, column: Int, colspan: Int) -> [String: Any] {
        var node: [String: Any] = [
            "type": "tableCell",
            "content": [paragraph([textNode("R\(row)C\(column) \(sentence(&rng, wordCount: rng.int(1 ..< 5)))")])],
        ]
        var attrs: [String: Any] = [:]
        if colspan > 1 { attrs["colspan"] = colspan }
        if rng.oneIn(9) { attrs["background"] = rng.pick(cellBackgrounds) }
        if !attrs.isEmpty { node["attrs"] = attrs }
        return node
    }

    var rows: [[String: Any]] = []
    rows.reserveCapacity(801)

    // Header row: 6 tableHeader cells with backgrounds and column widths.
    var headerCells: [[String: Any]] = []
    for c in 0 ..< columnCount {
        headerCells.append([
            "type": "tableHeader",
            "attrs": ["background": "#f4f5f7", "colwidth": [160]],
            "content": [paragraph([textNode("Column \(c + 1)", marks: [["type": "strong"]])])],
        ])
    }
    rows.append(["type": "tableRow", "content": headerCells])

    // 800 data rows; roughly every 20th row gets one colspan-2 cell.
    for r in 0 ..< 800 {
        var cells: [[String: Any]] = []
        if r % 20 == 7 {
            let spanAt = rng.int(0 ..< columnCount - 1)
            var c = 0
            while c < columnCount {
                if c == spanAt {
                    cells.append(cell(row: r, column: c, colspan: 2))
                    c += 2
                } else {
                    cells.append(cell(row: r, column: c, colspan: 1))
                    c += 1
                }
            }
        } else {
            for c in 0 ..< columnCount {
                cells.append(cell(row: r, column: c, colspan: 1))
            }
        }
        rows.append(["type": "tableRow", "content": cells])
    }

    let table: [String: Any] = [
        "type": "table",
        "attrs": ["isNumberColumnEnabled": false, "layout": "default"],
        "content": rows,
    ]
    return doc([
        ["type": "heading", "attrs": ["level": 1], "content": [textNode("Giant table: 800 rows x 6 columns")]],
        table,
    ])
}

// MARK: - Fixture 3: media-gallery.json

func makeMediaGallery() -> [String: Any] {
    var rng = LCG(seed: 0x5EED_0300)
    // Every schema-legal mediaSingle layout, cycled so all are represented.
    let layouts = ["center", "wrap-left", "wrap-right", "align-start", "align-end", "wide", "full-width"]

    var blocks: [[String: Any]] = []
    blocks.reserveCapacity(301)
    blocks.append(["type": "heading", "attrs": ["level": 1], "content": [textNode("Media gallery: 300 external images")]])

    for n in 0 ..< 300 {
        let width = 320 + rng.int(0 ..< 13) * 80 // 320...1280
        let height = 240 + rng.int(0 ..< 10) * 80 // 240...960
        let media: [String: Any] = [
            "type": "media",
            "attrs": [
                "type": "external",
                "url": "placeholder://\(n)",
                "width": width,
                "height": height,
                "alt": "Placeholder image \(n)",
            ] as [String: Any],
        ]

        var content: [[String: Any]] = [media]
        if n % 10 == 0 {
            content.append([
                "type": "caption",
                "content": [textNode("Caption for image \(n): \(sentence(&rng, wordCount: 4))")],
            ])
        }

        var attrs: [String: Any] = ["layout": layouts[n % layouts.count]]
        if n % 3 == 0 {
            attrs["width"] = 25 + rng.int(0 ..< 4) * 25 // 25/50/75/100
            attrs["widthType"] = "percentage"
        } else if n % 5 == 0 {
            attrs["width"] = width
            attrs["widthType"] = "pixel"
        }

        blocks.append(["type": "mediaSingle", "attrs": attrs, "content": content])
    }
    return doc(blocks)
}

// MARK: - Fixture 4: text-dense.json

/// Emoji and combining sequences carried as plain text (emoji *nodes* are
/// inline atoms, which the TextKit 2 path does not cover yet).
let textEmoji = ["🚀", "👩🏽‍💻", "🇯🇵", "❤️", "✅", "e\u{0301}", "🧪", "👍🏿"]

func textDenseParagraph(_ rng: inout LCG, index: Int) -> [String: Any] {
    let runCount = rng.int(1 ..< 6)
    var runs: [[String: Any]] = []
    runs.reserveCapacity(runCount + 2)
    for r in 0 ..< runCount {
        var text = sentence(&rng, wordCount: rng.int(4 ..< 14))
        if rng.oneIn(6) { text += " " + rng.pick(textEmoji) }
        runs.append(textNode(text + " ", marks: randomMarks(&rng, index: index)))
        if r < runCount - 1, rng.oneIn(10) {
            runs.append(["type": "hardBreak"])
        }
    }
    return paragraph(runs)
}

func makeTextDense() -> [String: Any] {
    var rng = LCG(seed: 0x5EED_3000)
    var blocks: [[String: Any]] = []
    blocks.reserveCapacity(3000)
    for i in 0 ..< 3000 {
        if i % 8 == 0 {
            blocks.append(heading(&rng, index: i))
        } else {
            blocks.append(textDenseParagraph(&rng, index: i))
        }
    }
    return doc(blocks)
}

// MARK: - Fixture 5: long-paragraph.json

func makeLongParagraph() -> [String: Any] {
    var rng = LCG(seed: 0x5EED_2000)
    let targetCharacters = 20_000
    var runs: [[String: Any]] = []
    var characters = 0
    var runIndex = 0
    while characters < targetCharacters {
        var text = sentence(&rng, wordCount: rng.int(6 ..< 15))
        if runIndex % 5 == 4 { text += " " + rng.pick(textEmoji) }
        text += " "
        runs.append(textNode(text, marks: randomMarks(&rng, index: runIndex)))
        characters += text.count
        runIndex += 1
        if runIndex % 12 == 0 {
            runs.append(["type": "hardBreak"])
            characters += 1
        }
    }
    return doc([
        ["type": "heading", "attrs": ["level": 1], "content": [textNode("Long paragraph: \(targetCharacters) characters")]],
        paragraph(runs),
        paragraph([textNode("End of the long paragraph.")]),
    ])
}

// MARK: - List node builders (lists-parity, list-dense, list-tall)

func hardBreakNode() -> [String: Any] { ["type": "hardBreak"] }

func linkMark(_ href: String) -> [String: Any] {
    ["type": "link", "attrs": ["href": href]]
}

func listItemNode(_ content: [[String: Any]]) -> [String: Any] {
    ["type": "listItem", "content": content]
}

func bulletListNode(_ items: [[String: Any]]) -> [String: Any] {
    ["type": "bulletList", "content": items]
}

func orderedListNode(order: Int? = nil, _ items: [[String: Any]]) -> [String: Any] {
    var node: [String: Any] = ["type": "orderedList", "content": items]
    if let order { node["attrs"] = ["order": order] }
    return node
}

func headingNode(level: Int, _ text: String) -> [String: Any] {
    ["type": "heading", "attrs": ["level": level], "content": [textNode(text)]]
}

func taskItemNode(_ localId: String, done: Bool, _ content: [[String: Any]]) -> [String: Any] {
    ["type": "taskItem", "attrs": ["localId": localId, "state": done ? "DONE" : "TODO"], "content": content]
}

func taskListNode(_ localId: String, _ items: [[String: Any]]) -> [String: Any] {
    ["type": "taskList", "attrs": ["localId": localId], "content": items]
}

func decisionItemNode(_ localId: String, _ content: [[String: Any]]) -> [String: Any] {
    ["type": "decisionItem", "attrs": ["localId": localId, "state": "DECIDED"], "content": content]
}

func decisionListNode(_ localId: String, _ items: [[String: Any]]) -> [String: Any] {
    ["type": "decisionList", "attrs": ["localId": localId], "content": items]
}

func mentionNode(id: String, text: String) -> [String: Any] {
    ["type": "mention", "attrs": ["id": id, "text": text, "accessLevel": "CONTAINER"]]
}

func statusNode(_ text: String, color: String, localId: String) -> [String: Any] {
    ["type": "status", "attrs": ["text": text, "color": color, "localId": localId]]
}

/// An emoji with neither `text` nor a hex `id`: no Unicode representation,
/// so the composer emits an atom (a text-bearing emoji node stays text).
func emojiAtomNode(shortName: String) -> [String: Any] {
    ["type": "emoji", "attrs": ["shortName": shortName]]
}

/// Zero-padded 3-digit label (locale-free, unlike `String(format:)`).
func pad3(_ n: Int) -> String {
    let digits = String(n)
    return String(repeating: "0", count: max(0, 3 - digits.count)) + digits
}

// MARK: - Fixture 6: lists-parity.json

/// Hand-authored, no RNG. Root order (index → node) is pinned by
/// `Tests/ADFPreparationTests/ListFixturePreparationTests.swift`, whose
/// expected node paths (`0.<root>.<child>…`) were derived by hand from this
/// structure: append new cases just before `LP-END`, never reorder.
///
///   0 heading   LP-S1        1 bulletList  nesting chain (depth 0–4) + same-type chain
///   2 heading   LP-S2        3 orderedList starts 8/25/8/99: 9→10, z→aa, viii→ix→x, 99→100
///   4 heading   LP-S3        5 taskList    done/undone, nested task lists, atoms, link, empty
///                            6 decisionList plain, status atom, link, hard break
///   7 heading   LP-S4        8 bulletList  wrapping, marks, link, breaks, Unicode, RTL,
///                                          mention/status/date/emoji atoms, empty leader,
///                                          code-block first child
///   9 heading   LP-S5       10 orderedList multi-paragraph, nested → continuation → nested →
///                                          continuation + trailing heading, embedded code/
///                                          panel/quote/expand/table/rule
///  11 heading   LP-S6       12 bulletList  trailing `.listRows`: sync block, malformed item
///  13 heading   LP-S7       14 panel, 15 blockquote, 16 table, 17 expand, 18 layoutSection
///                              — lists inside excluded containers
///  19 paragraph LP-END
///
/// No media (the media lifecycle livelock, issue #8, stays out of the list
/// fixtures).
func makeListsParity() -> [String: Any] {
    func p(_ text: String) -> [String: Any] { paragraph([textNode(text)]) }
    func li(_ content: [String: Any]...) -> [String: Any] { listItemNode(content) }
    func ul(_ items: [String: Any]...) -> [String: Any] { bulletListNode(items) }
    func ol(_ order: Int? = nil, _ items: [String: Any]...) -> [String: Any] { orderedListNode(order: order, items) }

    // 1: depth 0–4 with alternating ancestry (bullet > ordered > bullet >
    // ordered > bullet), then a same-type bullet chain (bullet depth 0–3).
    let nesting = ul(
        li(
            p("LP-BULLET-L1-A root bullet leader"),
            ol(nil,
               li(
                   p("LP-ORDERED-L2-A ordered inside a bullet"),
                   ul(
                       li(
                           p("LP-BULLET-L3-A bullet inside an ordered list"),
                           ol(nil,
                              li(
                                  p("LP-ORDERED-L4-A ordered at depth three"),
                                  ul(li(p("LP-BULLET-L5-A deepest bullet at depth four")))
                              ),
                              li(p("LP-ORDERED-L4-B")))
                       ),
                       li(p("LP-BULLET-L3-B"))
                   )
               ),
               li(p("LP-ORDERED-L2-B")))
        ),
        li(
            p("LP-BULLET-L1-B same-type bullet nesting"),
            ul(li(
                p("LP-BULLET-SAME-L2"),
                ul(li(
                    p("LP-BULLET-SAME-L3"),
                    ul(li(p("LP-BULLET-SAME-L4")))
                ))
            ))
        )
    )

    // 3: ordered starts and marker-width boundaries, one per ordered level
    // (decimal, alphabetic, roman, decimal again).
    let ordered = ol(8,
        li(p("LP-ORD-8 ordered list starting at eight")),
        li(
            p("LP-ORD-9 nine, before the two-digit marker"),
            ol(25,
               li(p("LP-ALPHA-Y")),
               li(
                   p("LP-ALPHA-Z"),
                   ol(8,
                      li(p("LP-ROMAN-VIII")),
                      li(
                          p("LP-ROMAN-IX"),
                          ol(99,
                             li(p("LP-DEC4-99")),
                             li(p("LP-DEC4-100")))
                      ),
                      li(p("LP-ROMAN-X")))
               ),
               li(p("LP-ALPHA-AA")))
        ),
        li(p("LP-ORD-10 ten, a two-digit marker")),
        li(p("LP-ORD-11"))
    )

    // 5: task list. Task item content is inline (no paragraph); nested task
    // lists are siblings of task items (schema).
    let tasks = taskListNode("lp-tasklist-1", [
        taskItemNode("lp-task-a", done: false, [textNode("LP-TASK-A undone task")]),
        taskItemNode("lp-task-b", done: true, [textNode("LP-TASK-B done task")]),
        taskListNode("lp-tasklist-1-nested", [
            taskItemNode("lp-task-c", done: false, [textNode("LP-TASK-C nested undone task")]),
            taskItemNode("lp-task-d", done: true, [textNode(
                "LP-TASK-D nested done task with a long leader that wraps across several "
                    + "lines at phone width, so the checkbox must stay on the first baseline"
            )]),
            taskListNode("lp-tasklist-1-deeper", [
                taskItemNode("lp-task-e", done: false, [textNode("LP-TASK-E second task nesting level")]),
            ]),
        ]),
        taskItemNode("lp-task-f", done: false, [
            textNode("LP-TASK-F due "),
            date(300),
            textNode(" for "),
            mentionNode(id: "lp-user-2", text: "@LP Owner"),
        ]),
        taskItemNode("lp-task-g", done: true, [
            textNode("LP-TASK-G done with a "),
            textNode("linked spec", marks: [linkMark("https://example.com/lists-parity/task-g")]),
        ]),
        taskItemNode("lp-task-h", done: false, []),
    ])

    // 6: decision list.
    let decisions = decisionListNode("lp-decisionlist-1", [
        decisionItemNode("lp-decision-a", [textNode("LP-DECISION-A plain decision")]),
        decisionItemNode("lp-decision-b", [
            textNode("LP-DECISION-B shipped as "),
            statusNode("DONE", color: "green", localId: "lp-status-2"),
        ]),
        decisionItemNode("lp-decision-c", [
            textNode("LP-DECISION-C see the "),
            textNode("decision record", marks: [linkMark("https://example.com/lists-parity/decision-c")]),
        ]),
        decisionItemNode("lp-decision-d", [
            textNode("LP-DECISION-D a decision whose text runs long enough to wrap onto a second line"),
            hardBreakNode(),
            textNode("and continues after a hard break"),
        ]),
    ])

    // 8: leader content. Atom-bearing leaders (mention, status, date, emoji
    // without a Unicode form) stay SwiftUI; everything else is text.
    let leaders = ul(
        li(p(
            "LP-WRAP-A a deliberately long bullet leader that wraps across several lines "
                + "at phone width, so the marker must stay aligned with the first baseline "
                + "while every following line wraps under the text column, not the marker."
        )),
        li(paragraph([
            textNode("LP-MARKS-A "),
            textNode("strong", marks: [["type": "strong"]]),
            textNode(" "),
            textNode("emphasis", marks: [["type": "em"]]),
            textNode(" "),
            textNode("inline code", marks: [["type": "code"]]),
            textNode(" "),
            textNode("struck", marks: [["type": "strike"]]),
            textNode(" "),
            textNode("underlined", marks: [["type": "underline"]]),
            textNode(" "),
            textNode("red text", marks: [["type": "textColor", "attrs": ["color": "#ff5630"]]]),
            textNode(" "),
            textNode("highlighted", marks: [["type": "backgroundColor", "attrs": ["color": "#fffae6"]]]),
            textNode(" H"),
            textNode("2", marks: [["type": "subsup", "attrs": ["type": "sub"]]]),
            textNode("O and x"),
            textNode("2", marks: [["type": "subsup", "attrs": ["type": "sup"]]]),
        ])),
        li(paragraph([
            textNode("LP-LINK-A see "),
            textNode("the linked docs", marks: [linkMark("https://example.com/lists-parity/link-a")]),
            textNode(" for details"),
        ])),
        li(paragraph([
            textNode("LP-BREAK-A first line"),
            hardBreakNode(),
            textNode("second line after a hard break"),
            hardBreakNode(),
            textNode("third line"),
        ])),
        li(paragraph([
            textNode("LP-UNICODE-A café naïve Zoë 日本語 中文 한국어 👩🏽‍💻 🇯🇵 e\u{0301} ✅ ❤️ "),
            ["type": "emoji", "attrs": ["shortName": ":rocket:", "id": "1f680", "text": "🚀"]],
            textNode(" text emoji"),
        ])),
        li(p("LP-RTL-A left-to-right leader with עברית: שלום עולם and العربية: مرحبا بالعالم")),
        li(p("שלום עולם — פסקה מימין לשמאל LP-RTL-B")),
        li(paragraph([
            textNode("LP-ATOM-MENTION ping "),
            mentionNode(id: "lp-user-1", text: "@LP Reviewer"),
            textNode(" today"),
        ])),
        li(paragraph([
            textNode("LP-ATOM-STATUS state "),
            statusNode("IN PROGRESS", color: "blue", localId: "lp-status-1"),
        ])),
        li(paragraph([
            textNode("LP-ATOM-DATE due "),
            date(310),
        ])),
        li(paragraph([
            textNode("LP-ATOM-EMOJI custom "),
            emojiAtomNode(shortName: ":lp-custom:"),
        ])),
        li(paragraph([])),
        li(
            ["type": "codeBlock", "attrs": ["language": "swift"],
             "content": [textNode("let lpCodeFirst = true // LP-CODE-FIRST")]],
            p("LP-AFTER-CODE paragraph after a code-block first child")
        )
    )

    // 10: item structure and excluded blocks embedded in an item.
    let structure = ol(nil,
        li(
            p("LP-MULTI-P1 first paragraph of a multi-paragraph item"),
            p("LP-MULTI-P2 second paragraph, a trailing text block"),
            p("LP-MULTI-P3 third paragraph")
        ),
        li(
            p("LP-CONT-LEADER item with nested lists and continuations"),
            ul(li(p("LP-CONT-NESTED-1A")), li(p("LP-CONT-NESTED-1B"))),
            p("LP-CONT-PARA-1 continuation paragraph after the first nested list"),
            ul(li(p("LP-CONT-NESTED-2A"))),
            p("LP-CONT-PARA-2 second continuation paragraph"),
            headingNode(level: 3, "LP-CONT-HEADING trailing heading after a nested list")
        ),
        li(
            p("LP-EMBED-LEADER item with embedded excluded blocks"),
            ["type": "codeBlock", "attrs": ["language": "json"],
             "content": [textNode("{\"sentinel\": \"LP-EMBED-CODE\"}")]],
            ["type": "panel", "attrs": ["panelType": "info"],
             "content": [p("LP-EMBED-PANEL panel inside a list item")]],
            ["type": "blockquote", "content": [p("LP-EMBED-QUOTE quote inside a list item")]],
            ["type": "expand", "attrs": ["title": "LP-EMBED-EXPAND expand inside a list item"],
             "content": [p("LP-EMBED-EXPAND-BODY")]],
            ["type": "table", "attrs": ["isNumberColumnEnabled": false, "layout": "default"] as [String: Any],
             "content": [
                 ["type": "tableRow", "content": [["type": "tableHeader", "content": [p("LP-EMBED-TH")]]]],
                 ["type": "tableRow", "content": [["type": "tableCell", "content": [p("LP-EMBED-TD")]]]],
             ]],
            rule()
        ),
        li(p("LP-AFTER-EMBED closing item"))
    )

    // 12: the two fixture-borne ways a trailing `.listRows` arises (the
    // third, a non-task/decision child of a task/decision list, is pinned
    // by inline JSON in the tests only).
    let trailingLists = ul(
        li(
            p("LP-SYNC-LEADER item whose nested list sits inside a sync block"),
            ["type": "bodiedSyncBlock",
             "attrs": ["resourceId": "ari:cloud:confluence:site/lp-sync-1", "localId": "lp-sync-1"],
             "content": [ul(li(p("LP-SYNC-NESTED-A")), li(p("LP-SYNC-NESTED-B")))]]
        ),
        li(
            p("LP-MALFORMED-LEADER item with a stray listItem child"),
            li(ol(nil, li(p("LP-MALFORMED-NESTED-A"))))
        )
    )

    // 14–18: lists inside excluded containers.
    let inPanel: [String: Any] = [
        "type": "panel",
        "attrs": ["panelType": "note"],
        "content": [
            p("LP-PANEL-INTRO a list inside a panel"),
            ul(
                li(p("LP-IN-PANEL-A"), ol(nil, li(p("LP-IN-PANEL-A1")))),
                li(p("LP-IN-PANEL-B"))
            ),
        ],
    ]
    let inQuote: [String: Any] = [
        "type": "blockquote",
        "content": [ol(3, li(p("LP-IN-QUOTE-3")), li(p("LP-IN-QUOTE-4")))],
    ]
    let inTable: [String: Any] = [
        "type": "table",
        "attrs": ["isNumberColumnEnabled": false, "layout": "default"] as [String: Any],
        "content": [
            ["type": "tableRow", "content": [
                ["type": "tableHeader", "content": [p("LP-TABLE-H1")]],
                ["type": "tableHeader", "content": [p("LP-TABLE-H2")]],
            ]],
            ["type": "tableRow", "content": [
                ["type": "tableCell", "content": [ul(li(p("LP-IN-CELL-A")), li(p("LP-IN-CELL-B")))]],
                ["type": "tableCell", "content": [taskListNode("lp-cell-tasks", [
                    taskItemNode("lp-cell-task-a", done: false, [textNode("LP-IN-CELL-TASK")]),
                ])]],
            ]],
        ],
    ]
    let inExpand: [String: Any] = [
        "type": "expand",
        "attrs": ["title": "LP-EXPAND lists inside an expand"],
        "content": [
            ul(li(p("LP-IN-EXPAND-BULLET"))),
            taskListNode("lp-expand-tasks", [
                taskItemNode("lp-expand-task-a", done: true, [textNode("LP-IN-EXPAND-TASK")]),
            ]),
            decisionListNode("lp-expand-decisions", [
                decisionItemNode("lp-expand-decision-a", [textNode("LP-IN-EXPAND-DECISION")]),
            ]),
        ],
    ]
    let inColumns: [String: Any] = [
        "type": "layoutSection",
        "content": [
            ["type": "layoutColumn", "attrs": ["width": 50],
             "content": [ul(li(p("LP-IN-COLUMN-LEFT")))]],
            ["type": "layoutColumn", "attrs": ["width": 50],
             "content": [
                 ol(nil, li(p("LP-IN-COLUMN-RIGHT"))),
                 decisionListNode("lp-column-decisions", [
                     decisionItemNode("lp-column-decision-a", [textNode("LP-IN-COLUMN-DECISION")]),
                 ]),
             ]],
        ],
    ]

    return doc([
        headingNode(level: 2, "LP-S1 Nesting: alternating bullet and ordered ancestry"),
        nesting,
        headingNode(level: 2, "LP-S2 Ordered starts and marker boundaries"),
        ordered,
        headingNode(level: 2, "LP-S3 Task and decision lists"),
        tasks,
        decisions,
        headingNode(level: 2, "LP-S4 Leader content"),
        leaders,
        headingNode(level: 2, "LP-S5 Item structure and embedded blocks"),
        structure,
        headingNode(level: 2, "LP-S6 Trailing list rows"),
        trailingLists,
        headingNode(level: 2, "LP-S7 Lists inside excluded containers"),
        inPanel,
        inQuote,
        inTable,
        inExpand,
        inColumns,
        p("LP-END end of the lists parity fixture"),
    ])
}

// MARK: - Fixture 7: list-dense.json

/// What the list-dense generator emitted, counted at emission time
/// (independently of `ListPreparer`); printed by the emit step and recorded
/// in the fixture manifest.
struct ListDenseTally {
    var rootLists: [String: Int] = [:]
    /// listItem + taskItem + decisionItem nodes (= marker rows).
    var items = 0
    /// Leaders (an item's first paragraph, or a task/decision item's inline
    /// content) by leaf class.
    var leaders: [String: Int] = [:]
    /// Second paragraphs directly after a leader (marker-row trailing text).
    var extraParagraphs: [String: Int] = [:]
    /// Paragraphs after a nested list (each opens one continuation row).
    var continuationParagraphs: [String: Int] = [:]
    /// Headings after a nested list (after a continuation paragraph, or
    /// opening the continuation row themselves).
    var trailingHeadings = 0
    var continuationRows = 0
}

/// Leaf classes in declared proportions: plain 55 %, marked 20 %, linked
/// 15 % (TextKit 1-backed), atom-bearing 10 % (the declared SwiftUI
/// fallback share).
func listDenseLeafClass(_ rng: inout LCG) -> String {
    let roll = rng.int(0 ..< 20)
    if roll < 11 { return "plain" }
    if roll < 15 { return "marked" }
    if roll < 18 { return "linked" }
    return "atom"
}

func listDenseMark(_ rng: inout LCG) -> [String: Any] {
    switch rng.int(0 ..< 8) {
    case 0: return ["type": "strong"]
    case 1: return ["type": "em"]
    case 2: return ["type": "underline"]
    case 3: return ["type": "strike"]
    case 4: return ["type": "code"]
    case 5: return ["type": "textColor", "attrs": ["color": rng.pick(["#ff5630", "#36b37e", "#6554c0"])]]
    case 6: return ["type": "backgroundColor", "attrs": ["color": rng.pick(["#fffae6", "#e3fcef", "#deebff"])]]
    default: return ["type": "subsup", "attrs": ["type": "sup"]]
    }
}

/// Inline content for one list-dense leaf. Short leaves on purpose: the
/// fixture is sized by leaf text, not by dropping coverage.
func listDenseInline(_ rng: inout LCG, leafClass: String, serial: Int, label: String?) -> [[String: Any]] {
    let lead = label.map { $0 + " " } ?? ""
    switch leafClass {
    case "marked":
        return [
            textNode(lead + sentence(&rng, wordCount: rng.int(1 ..< 3)) + " "),
            textNode(sentence(&rng, wordCount: rng.int(1 ..< 3)), marks: [listDenseMark(&rng)]),
            textNode(" " + sentence(&rng, wordCount: rng.int(1 ..< 3))),
        ]
    case "linked":
        return [
            textNode(lead + sentence(&rng, wordCount: rng.int(1 ..< 3)) + " "),
            textNode(sentence(&rng, wordCount: rng.int(1 ..< 3)),
                     marks: [linkMark("https://example.com/list-dense/\(serial)")]),
            textNode(" " + sentence(&rng, wordCount: rng.int(1 ..< 3))),
        ]
    case "atom":
        let atom: [String: Any]
        switch rng.int(0 ..< 4) {
        case 0: atom = mention(serial)
        case 1: atom = status(&rng, index: serial)
        case 2: atom = date(serial % 365)
        default: atom = emojiAtomNode(shortName: ":ld-custom-\(serial % 7):")
        }
        return [
            textNode(lead + sentence(&rng, wordCount: rng.int(1 ..< 3)) + " "),
            atom,
            textNode(" " + sentence(&rng, wordCount: rng.int(1 ..< 3))),
        ]
    default: // plain
        var text = lead + sentence(&rng, wordCount: rng.int(2 ..< 6))
        if rng.oneIn(10) { text += " " + rng.pick(textEmoji) }
        if rng.oneIn(16) {
            return [textNode(text), hardBreakNode(), textNode(sentence(&rng, wordCount: rng.int(2 ..< 4)))]
        }
        return [textNode(text)]
    }
}

func listDenseLeaf(
    _ rng: inout LCG, _ tally: inout ListDenseTally, serial: inout Int,
    bucket: WritableKeyPath<ListDenseTally, [String: Int]>, label: String? = nil
) -> [[String: Any]] {
    serial += 1
    let leafClass = listDenseLeafClass(&rng)
    tally[keyPath: bucket][leafClass, default: 0] += 1
    return listDenseInline(&rng, leafClass: leafClass, serial: serial, label: label)
}

/// A bullet or ordered list, up to depth 3 (four levels). An item may carry
/// a second paragraph, and a nested list (likelier on the first item); after
/// a nested list it may continue with a paragraph, a heading, or both.
func listDenseList(
    _ rng: inout LCG, _ tally: inout ListDenseTally, serial: inout Int,
    depth: Int, ordered: Bool, label: String?
) -> [String: Any] {
    let itemCount = depth == 0 ? rng.int(2 ..< 5) : rng.int(1 ..< 4)
    var items: [[String: Any]] = []
    for k in 0 ..< itemCount {
        tally.items += 1
        var content: [[String: Any]] = [paragraph(listDenseLeaf(
            &rng, &tally, serial: &serial, bucket: \.leaders, label: k == 0 ? label : nil
        ))]
        if rng.oneIn(8) {
            content.append(paragraph(listDenseLeaf(&rng, &tally, serial: &serial, bucket: \.extraParagraphs)))
        }
        if depth < 3, rng.int(0 ..< 10) < (k == 0 ? 5 : 2) {
            let nestedOrdered = rng.oneIn(3) ? ordered : !ordered
            content.append(listDenseList(&rng, &tally, serial: &serial, depth: depth + 1, ordered: nestedOrdered, label: nil))
            let roll = rng.int(0 ..< 12)
            if roll < 4 {
                tally.continuationRows += 1
                content.append(paragraph(listDenseLeaf(&rng, &tally, serial: &serial, bucket: \.continuationParagraphs)))
                if roll == 0 {
                    tally.trailingHeadings += 1
                    content.append(headingNode(level: 3 + rng.int(0 ..< 4), sentence(&rng, wordCount: rng.int(2 ..< 4))))
                }
            } else if roll == 4 {
                tally.continuationRows += 1
                tally.trailingHeadings += 1
                content.append(headingNode(level: 3 + rng.int(0 ..< 4), sentence(&rng, wordCount: rng.int(2 ..< 4))))
            }
        }
        items.append(listItemNode(content))
    }
    if ordered {
        let start: Int? = rng.oneIn(4) ? rng.int(2 ..< 12) : nil
        return orderedListNode(order: start, items)
    }
    return bulletListNode(items)
}

func listDenseTaskList(_ rng: inout LCG, _ tally: inout ListDenseTally, serial: inout Int, index: Int, label: String) -> [String: Any] {
    var items: [[String: Any]] = []
    for k in 0 ..< rng.int(3 ..< 6) {
        tally.items += 1
        let inline = listDenseLeaf(&rng, &tally, serial: &serial, bucket: \.leaders, label: k == 0 ? label : nil)
        items.append(taskItemNode("ld-task-\(index)-\(k)", done: rng.oneIn(3), inline))
        if k == 0, rng.oneIn(4) {
            var nested: [[String: Any]] = []
            for n in 0 ..< 2 {
                tally.items += 1
                let nestedInline = listDenseLeaf(&rng, &tally, serial: &serial, bucket: \.leaders)
                nested.append(taskItemNode("ld-task-\(index)-0-\(n)", done: rng.oneIn(2), nestedInline))
            }
            items.append(taskListNode("ld-tasklist-\(index)-0", nested))
        }
    }
    return taskListNode("ld-tasklist-\(index)", items)
}

func listDenseDecisionList(_ rng: inout LCG, _ tally: inout ListDenseTally, serial: inout Int, index: Int, label: String) -> [String: Any] {
    var items: [[String: Any]] = []
    for k in 0 ..< rng.int(2 ..< 5) {
        tally.items += 1
        let inline = listDenseLeaf(&rng, &tally, serial: &serial, bucket: \.leaders, label: k == 0 ? label : nil)
        items.append(decisionItemNode("ld-decision-\(index)-\(k)", inline))
    }
    return decisionListNode("ld-decisionlist-\(index)", items)
}

/// 600 root lists, family by `i % 20`: 0–6 bullet (210), 7–12 ordered
/// (180), 13–16 task (120), 17–19 decision (90). Each root's first leader
/// starts with its `LD-<iii>` label (search/scroll anchor).
func makeListDense(tally: inout ListDenseTally) -> [String: Any] {
    var rng = LCG(seed: 0x5EED_0600)
    var serial = 0
    var blocks: [[String: Any]] = []
    blocks.reserveCapacity(600)
    for i in 0 ..< 600 {
        let label = "LD-" + pad3(i)
        let family: String
        switch i % 20 {
        case 0 ..< 7: family = "bulletList"
        case 7 ..< 13: family = "orderedList"
        case 13 ..< 17: family = "taskList"
        default: family = "decisionList"
        }
        tally.rootLists[family, default: 0] += 1
        switch family {
        case "bulletList", "orderedList":
            blocks.append(listDenseList(&rng, &tally, serial: &serial, depth: 0, ordered: family == "orderedList", label: label))
        case "taskList":
            blocks.append(listDenseTaskList(&rng, &tally, serial: &serial, index: i, label: label))
        default:
            blocks.append(listDenseDecisionList(&rng, &tally, serial: &serial, index: i, label: label))
        }
    }
    return doc(blocks)
}

// MARK: - Fixture 8: list-tall.json

/// One ordered root list of 200 items → 316 rows: items i % 4 == 1 carry a
/// 2-item nested bullet list (50 × 2 = 100 rows), and those with i % 3 == 0
/// as well (i ≡ 9 mod 12: 16 items) continue with a paragraph after it (16
/// continuation rows). Then a 1-item closing list (root 2).
func makeListTall() -> [String: Any] {
    var rng = LCG(seed: 0x5EED_0316)
    var items: [[String: Any]] = []
    items.reserveCapacity(200)
    for i in 0 ..< 200 {
        let label = "LT-" + pad3(i + 1)
        var content: [[String: Any]] = [
            paragraph([textNode(label + " " + sentence(&rng, wordCount: rng.int(3 ..< 7)))]),
        ]
        if i % 4 == 1 {
            content.append(bulletListNode([
                listItemNode([paragraph([textNode(label + "-A " + sentence(&rng, wordCount: rng.int(2 ..< 5)))])]),
                listItemNode([paragraph([textNode(label + "-B " + sentence(&rng, wordCount: rng.int(2 ..< 5)))])]),
            ]))
            if i % 3 == 0 {
                content.append(paragraph([textNode(label + "-CONT " + sentence(&rng, wordCount: rng.int(3 ..< 7)))]))
            }
        }
        items.append(listItemNode(content))
    }
    return doc([
        orderedListNode(items),
        bulletListNode([listItemNode([paragraph([textNode("LT-END closing list after the tall root list")])])]),
    ])
}

// MARK: - Fixture 9: lists-links.json

/// Hand-authored, no RNG; node paths are pinned by
/// `Tests/ADFPreparationTests/ListFixturePreparationTests.swift`.
///
///   0 heading   LL-S1        1 bulletList  10 items: wrapped, coloured, emoji-adjacent,
///                                          RTL (3), later-line, two links, linked
///                                          continuation (item 8), linked trailing
///                                          paragraph (item 9)
///   2 heading   LL-S2        3 taskList    linked task, plain control
///                            4 decisionList linked decision, plain control
///   5 paragraph LL-END
func makeListsLinks() -> [String: Any] {
    func url(_ slug: String) -> String { "https://example.com/lists-links/" + slug }
    func t(_ text: String) -> [String: Any] { textNode(text) }
    func a(_ text: String, _ slug: String, extra: [[String: Any]] = []) -> [String: Any] {
        textNode(text, marks: [linkMark(url(slug))] + extra)
    }
    func para(_ content: [String: Any]...) -> [String: Any] { paragraph(content) }
    func li(_ content: [String: Any]...) -> [String: Any] { listItemNode(content) }

    let leaders = bulletListNode([
        // 0.1.0: the link starts on the first line and wraps across two more.
        li(para(t("LL-WRAP-LINK leader whose link "),
                a("is deliberately long so that it wraps from the end of the first line across the following lines at phone width",
                  "wrap"),
                t(" and ends here"))),
        // 0.1.1: link text with a text colour.
        li(para(t("LL-COLOUR-LINK see the "),
                a("coloured link", "colour", extra: [["type": "textColor", "attrs": ["color": "#ff5630"]]]),
                t(" in red"))),
        // 0.1.2: emoji directly before and after the link, no spaces.
        li(para(t("LL-EMOJI-LINK rocket 🚀"), a("launch notes", "emoji"), t("✅ shipped"))),
        // 0.1.3: a Hebrew link inside a left-to-right paragraph.
        li(para(t("LL-RTL-LINK-A Hebrew link "), a("קישור לתיעוד", "rtl-hebrew"), t(" inside"))),
        // 0.1.4: a right-to-left paragraph with a Hebrew link.
        li(para(t("שלום "), a("קישור מימין לשמאל", "rtl-paragraph"), t(" עולם LL-RTL-LINK-B"))),
        // 0.1.5: an Arabic paragraph with a left-to-right link.
        li(para(t("مرحبا "), a("English link", "rtl-ltr-link"), t(" بالعالم LL-RTL-LINK-C"))),
        // 0.1.6: the link sits on the second line, after a hard break.
        li(para(t("LL-LATER-LINK first line"), hardBreakNode(), t("second line with a "),
                a("later-line link", "later-line"), t(" 🚀"))),
        // 0.1.7: two links, two URLs.
        li(para(t("LL-TWO-LINKS "), a("first", "first"), t(" and "), a("second", "second"), t(" links"))),
        // 0.1.8: a linked continuation paragraph (0.1.8.2) after a nested list.
        li(para(t("LL-CONT-LEADER item whose continuation is linked")),
           bulletListNode([li(para(t("LL-CONT-NESTED nested bullet")))]),
           para(t("LL-CONT-LINK a "), a("linked continuation", "continuation"))),
        // 0.1.9: a linked trailing paragraph (0.1.9.1) of a multi-paragraph item.
        li(para(t("LL-MULTI-P1 first paragraph of the item")),
           para(t("LL-MULTI-LINK a "), a("trailing link", "trailing-paragraph"))),
    ])

    let tasks = taskListNode("ll-tasklist-1", [
        taskItemNode("ll-task-link", done: false, [t("LL-TASK-LINK task with a "), a("linked task spec", "task")]),
        taskItemNode("ll-task-plain", done: true, [t("LL-TASK-PLAIN plain control task")]),
    ])
    let decisions = decisionListNode("ll-decisionlist-1", [
        decisionItemNode("ll-decision-link", [t("LL-DECISION-LINK see the "), a("linked decision record", "decision")]),
        decisionItemNode("ll-decision-plain", [t("LL-DECISION-PLAIN plain control decision")]),
    ])

    return doc([
        headingNode(level: 2, "LL-S1 Linked leaders and continuations"),
        leaders,
        headingNode(level: 2, "LL-S2 Linked tasks and decisions"),
        tasks,
        decisions,
        paragraph([textNode("LL-END end of the lists links fixture")]),
    ])
}

// MARK: - Code fixtures: the canvas budget model

/// Generator-side model of the TextKit 2 code canvas gate at the DEFAULT
/// configuration: the default theme's code font (monospaced body) at the
/// default size category (`large`, 17 pt), regular weight, left to right.
///
/// The arithmetic mirrors `TextKit2Scope.codeCanvasEstimate`
/// (Sources/ADFRendering/TextKit2/TextKit2Scope.swift):
///
///     pixelWidth  = ceil(maxLineUTF16 × advance × scale) + 2
///     pixelHeight = ceil(((lineCount + 2) × lineHeight + 2) × scale)
///     admitted when both are ≤ 8,192 and width × height × 4 ≤ 16 MiB
///
/// The generator cannot link UIKit, so the two font metrics are constants:
/// the advance read from the font file's tables (SF Mono, `SFUIMono.ttf`,
/// the same in the iOS 18.2 to 27.1 simulator runtimes), the line height
/// the pitch measured in the app; the gate measures both from the resolved
/// font at run time (`TextKit2CodeMetrics`). The reserves and caps are
/// copies.
/// CORRECT THEM HERE, and only here: every "over budget" and "just under
/// budget" block of code-parity, code-dense and code-tall is sized and
/// declared through `codeBudgetVerdict`, which reads nothing else. A change
/// moves fixture bytes (code-parity CP-16 and CP-17, code-dense's shortened
/// and kept blocks, code-tall's CT-NEAR and CT-SEQ blocks), so settle the
/// values before the fixtures are frozen.
enum CodeCanvasModel {
    /// Advance of one code glyph, in 1/1000 pt. 17 pt SF Mono: every
    /// printable ASCII glyph advances 1266/2048 em = 10.509 pt; rounded up.
    /// (The plan's "about 10.2 pt" is Menlo's 1233/2048 em.)
    static let advanceMilliPoints = 10_510
    /// Height of one code line, in 1/1000 pt: the line pitch measured at
    /// Large on iOS 26.3 (3x), where `Text` and the TextKit 2 row agree,
    /// 22.0 pt. Not the font-file value (ascender 1950 and descender 494
    /// of 2048, no line gap = 20.287 pt at 17 pt), which the run showed to
    /// be 8 % short.
    static let lineHeightMilliPoints = 22_000
    /// The display scale the declared verdicts are for. The summary prints
    /// the 2x verdict beside it.
    static let displayScale = 3
    /// `TextKit2Scope.maximumCodeCanvasDimension`: pixels per dimension.
    static let maximumDimensionPixels = 8_192
    /// `TextKit2Scope.maximumCodeCanvasBytes`: 16 MiB at `bytesPerPixel`.
    static let maximumBytes = 16 * 1_024 * 1_024
    static let bytesPerPixel = 4
    /// `TextKit2Scope.codeCanvasInkReserveLines`.
    static let inkReserveLines = 2
    /// `TextKit2Scope.codeCanvasRoundingReservePoints`, in 1/1000 pt.
    static let roundingReserveMilliPoints = 2_000
    /// `TextKit2Scope.codeCanvasWidthReservePixels`.
    static let widthReservePixels = 2
    /// Safety margin on the two font metrics, in 1/1000. A block is
    /// DECLARED under budget only if its bound is within the caps with both
    /// metrics this much larger, and over budget only if it is past a cap
    /// with both this much smaller. Anything in between is `.marginal`,
    /// and the generator emits none.
    static let metricMarginPermille = 30
}

/// The canvas bound of a code block of `lineCount` lines whose widest line
/// is `maxColumns` UTF-16 units, in pixels at `scale`.
struct CodeCanvasEstimate {
    let widthPixels: Int
    let heightPixels: Int

    var bytes: Int { widthPixels * heightPixels * CodeCanvasModel.bytesPerPixel }

    var isWithinCaps: Bool {
        widthPixels <= CodeCanvasModel.maximumDimensionPixels
            && heightPixels <= CodeCanvasModel.maximumDimensionPixels
            && bytes <= CodeCanvasModel.maximumBytes
    }
}

/// The mirror of `TextKit2Scope.codeCanvasEstimate`, in integers, with both
/// font metrics scaled by `metricPermille`/1000.
func codeCanvasEstimate(lineCount: Int, maxColumns: Int, scale: Int, metricPermille: Int = 1_000) -> CodeCanvasEstimate {
    // Metrics in 1/1,000,000 pt.
    let advance = CodeCanvasModel.advanceMilliPoints * metricPermille
    let lineHeight = CodeCanvasModel.lineHeightMilliPoints * metricPermille
    let width = maxColumns * advance * scale
    let reservedLines = lineCount + CodeCanvasModel.inkReserveLines
    let height = (reservedLines * lineHeight + CodeCanvasModel.roundingReserveMilliPoints * 1_000) * scale
    return CodeCanvasEstimate(
        widthPixels: (width + 999_999) / 1_000_000 + CodeCanvasModel.widthReservePixels,
        heightPixels: (height + 999_999) / 1_000_000
    )
}

enum CodeBudgetVerdict: String {
    /// Within the caps even with the metric margin added: expected on
    /// TextKit 2 (if its text is in the admitted cohort).
    case under
    /// Past a cap even with the metric margin taken off: expected on
    /// SwiftUI.
    case over
    /// Inside the safety band: not declared either way. Never emitted.
    case marginal
}

/// THE budget decision of the code fixtures, for the default configuration
/// at `scale`. Every declared over-budget or under-budget block, every
/// "largest under" and "smallest over" size and the code-dense shortening
/// rule go through this one function.
func codeBudgetVerdict(lineCount: Int, maxColumns: Int, scale: Int = CodeCanvasModel.displayScale) -> CodeBudgetVerdict {
    let margin = CodeCanvasModel.metricMarginPermille
    let generous = codeCanvasEstimate(lineCount: lineCount, maxColumns: maxColumns, scale: scale, metricPermille: 1_000 + margin)
    if generous.isWithinCaps {
        return .under
    }
    let tight = codeCanvasEstimate(lineCount: lineCount, maxColumns: maxColumns, scale: scale, metricPermille: 1_000 - margin)
    if !tight.isWithinCaps {
        return .over
    }
    return .marginal
}

/// The largest line count declared under budget at `columns` (0 if none).
func largestLineCountUnderBudget(columns: Int, scale: Int = CodeCanvasModel.displayScale) -> Int {
    var lines = 0
    while codeBudgetVerdict(lineCount: lines + 1, maxColumns: columns, scale: scale) == .under {
        lines += 1
    }
    return lines
}

/// The widest line declared under budget over `lineCount` lines (0 if none).
func largestColumnsUnderBudget(lineCount: Int, scale: Int = CodeCanvasModel.displayScale) -> Int {
    var columns = 0
    while codeBudgetVerdict(lineCount: lineCount, maxColumns: columns + 1, scale: scale) == .under {
        columns += 1
    }
    return columns
}

/// The smallest line count declared over budget at `columns`.
func smallestLineCountOverBudget(columns: Int, scale: Int) -> Int {
    var lines = 1
    while codeBudgetVerdict(lineCount: lines, maxColumns: columns, scale: scale) != .over {
        lines += 1
    }
    return lines
}

/// The narrowest widest line declared over budget over `lineCount` lines
/// (the width cap ends the search for any line count).
func smallestColumnsOverBudget(lineCount: Int, scale: Int = CodeCanvasModel.displayScale) -> Int {
    var columns = 1
    while codeBudgetVerdict(lineCount: lineCount, maxColumns: columns, scale: scale) != .over {
        columns += 1
    }
    return columns
}

// MARK: - Code fixtures: emitted-text measurement

/// What the generator measured on one emitted code string, in one pass
/// over its UTF-16 units — its own count, independent of the library's
/// prepared code shape and of the coverage walker.
struct CodeTextShape {
    /// Line feeds + 1 (the autoscroll estimator's definition; 1 for `""`).
    var lineCount = 1
    /// The widest line, in UTF-16 units (= columns for ASCII text).
    var maxLineUTF16 = 0
    var trailingNewlineCount = 0
    /// Every UTF-16 unit, line feeds included.
    var utf16Count = 0
    var isEmpty = true
    /// Non-empty and nothing but line feeds.
    var isAllNewlines = false
    /// Every unit is U+0020…U+007E or a line feed (the admitted cohort's
    /// content rule; an empty string satisfies it vacuously).
    var isPrintableASCIIAndLF = true
    var hasTabs = false
    var hasNonASCII = false
}

func codeTextShape(_ text: String) -> CodeTextShape {
    var shape = CodeTextShape()
    var currentLine = 0
    var trailingNewlines = 0
    var sawText = false
    for unit in text.utf16 {
        shape.isEmpty = false
        shape.utf16Count += 1
        if unit == 0x0A {
            shape.lineCount += 1
            shape.maxLineUTF16 = max(shape.maxLineUTF16, currentLine)
            currentLine = 0
            trailingNewlines += 1
            continue
        }
        trailingNewlines = 0
        sawText = true
        currentLine += 1
        if unit == 0x09 { shape.hasTabs = true }
        if unit > 0x7F { shape.hasNonASCII = true }
        if unit < 0x20 || unit > 0x7E { shape.isPrintableASCIIAndLF = false }
    }
    shape.maxLineUTF16 = max(shape.maxLineUTF16, currentLine)
    shape.trailingNewlineCount = trailingNewlines
    shape.isAllNewlines = !shape.isEmpty && !sawText
    return shape
}

/// One emitted top-level code block as the generator measured it. The emit
/// step prints these: the hand-countable source for fixture notes and pins.
struct CodeBlockRecord {
    /// Top-level node index; the block's id is `0.<index>`.
    let index: Int
    /// `CP-<nn>`, `CD-<iii>` or `CT-…`.
    let label: String
    let note: String
    let language: String?
    let breakoutMode: String?
    let shape: CodeTextShape
}

struct CodeFixture {
    let document: [String: Any]
    /// The top-level code blocks, in document order.
    let records: [CodeBlockRecord]
    /// Lines about what is not a top-level code block (nested code).
    var notes: [String] = []
}

// MARK: - Code fixtures: node and text builders

/// Zero-padded 2-digit label.
func pad2(_ n: Int) -> String {
    n < 10 ? "0" + String(n) : String(n)
}

/// A `codeBlock` node. `language` nil omits `attrs` (the model's
/// `language: nil`); `""` keeps an empty `language`. An empty `text` omits
/// `content` (a text node may not be empty in the ADF schema). `text` is
/// carried in one text node, exactly as given.
func codeBlockNode(language: String?, text: String, breakoutMode: String? = nil) -> [String: Any] {
    var node: [String: Any] = ["type": "codeBlock"]
    if let language {
        let attrs: [String: Any] = ["language": language]
        node["attrs"] = attrs
    }
    if !text.isEmpty {
        let content: [[String: Any]] = [textNode(text)]
        node["content"] = content
    }
    if let breakoutMode {
        let modeAttrs: [String: Any] = ["mode": breakoutMode]
        let mark: [String: Any] = ["type": "breakout", "attrs": modeAttrs]
        let marks: [[String: Any]] = [mark]
        node["marks"] = marks
    }
    return node
}

/// One code-like statement from the word soup: printable ASCII, no tab, no
/// leading or trailing space.
func codeStatement(_ rng: inout LCG) -> String {
    let a = rng.pick(words)
    let b = rng.pick(words)
    let c = rng.pick(words)
    let n = rng.int(0 ..< 1_000)
    switch rng.int(0 ..< 8) {
    case 0: return "let \(a)\(n) = \(b).\(c)(\(n))"
    case 1: return "\(a).\(b) = \(c)[\(n)]"
    case 2: return "if \(a).\(b) > \(n) { return \(c) }"
    case 3: return "// \(a) \(b) \(c) \(n)"
    case 4: return "guard let \(a) = \(b)[\(n)] else { return nil }"
    case 5: return "\(a).append(\(b)(\(c): \(n)))"
    case 6: return "for \(a) in \(b) where \(a).\(c) != \(n) {"
    default: return "return \(a)(\(b), \(c): \(n))"
    }
}

/// A statement of at most `columns` columns: a full `codeStatement` when
/// it fits, otherwise one of the three longest short forms that do ("}"
/// when nothing else fits). No statement is ever cut mid-token.
func fittingCodeStatement(_ rng: inout LCG, columns: Int) -> String {
    let statement = codeStatement(&rng)
    if statement.utf8.count <= columns {
        return statement
    }
    let a = rng.pick(words)
    let b = rng.pick(words)
    let n = rng.int(0 ..< 100)
    let shortForms: [String] = [
        "let \(a) = \(b)(\(n))",
        "\(a).\(b)()",
        "let \(a) = \(n)",
        "return \(a)",
        "\(a) += \(n)",
        "\(a)()",
        "return",
        "break",
    ]
    var fitting: [String] = []
    for form in shortForms where form.utf8.count <= columns {
        fitting.append(form)
    }
    if fitting.isEmpty {
        return "}"
    }
    let choices = Array(fitting.prefix(3))
    return rng.pick(choices)
}

/// `count` lowercase hex digits.
func codeHex(_ rng: inout LCG, count: Int) -> String {
    let digits: [Character] = Array("0123456789abcdef")
    var text = ""
    for _ in 0 ..< count {
        text.append(rng.pick(digits))
    }
    return text
}

/// Appends whole tokens to `line` while they fit in `columns`: comment
/// words inside a comment, chained calls after a closing parenthesis,
/// otherwise a trailing comment opened together with its first word (so no
/// comment is left empty). Returns whether the line now ends inside a
/// comment.
func extendCodeLine(_ rng: inout LCG, _ line: inout String, columns: Int, inComment: Bool) -> Bool {
    var commenting = inComment
    while true {
        let token: String
        var opensComment = false
        if commenting {
            token = " " + rng.pick(words)
        } else if line.hasSuffix(")") {
            let name = rng.pick(words)
            let argument = rng.int(0 ..< 100)
            token = ".\(name)(\(argument))"
        } else {
            token = " // " + rng.pick(words)
            opensComment = true
        }
        if line.utf8.count + token.utf8.count > columns {
            return commenting
        }
        line += token
        if opensComment {
            commenting = true
        }
    }
}

/// Pads `line` to exactly `columns` columns with hex digits (in a trailing
/// comment, opened here if there is room) or, for a gap of one or two
/// columns outside a comment, semicolons. Never leaves a trailing space.
func padCodeLine(_ rng: inout LCG, _ line: inout String, columns: Int, inComment: Bool) {
    let gap = columns - line.utf8.count
    if gap <= 0 {
        return
    }
    if inComment {
        if gap == 1 {
            line += codeHex(&rng, count: 1)
        } else {
            line += " " + codeHex(&rng, count: gap - 1)
        }
    } else if gap >= 5 {
        line += " // " + codeHex(&rng, count: gap - 4)
    } else if gap == 4 {
        line += " //" + codeHex(&rng, count: 1)
    } else if gap == 3 {
        line += " //"
    } else {
        line += String(repeating: ";", count: gap)
    }
}

/// One code line of at most `columns` columns, exactly `columns` when
/// `exact`: up to `indent` leading spaces, a statement that fits, then
/// whole tokens while they fit, then (if `exact`) hex padding. Printable
/// ASCII only, never blank, never ending in a space, never cut mid-token.
func codeLine(_ rng: inout LCG, columns: Int, indent: Int = 0, exact: Bool = false) -> String {
    guard columns > 0 else { return "" }
    let leading = min(indent, max(0, columns - 8))
    let statement = fittingCodeStatement(&rng, columns: columns - leading)
    var line = String(repeating: " ", count: leading) + statement
    let inComment = extendCodeLine(&rng, &line, columns: columns, inComment: statement.hasPrefix("//"))
    if exact {
        padCodeLine(&rng, &line, columns: columns, inComment: inComment)
    }
    return line
}

/// `line` (ASCII) shortened to at most `columns` columns at a token
/// boundary: everything from the last space or "." that still fits is
/// dropped, then trailing spaces and an emptied trailing comment.
func shortenedCodeLine(_ line: String, to columns: Int) -> String {
    guard line.utf8.count > columns else { return line }
    var cells: [Character] = Array(line.prefix(columns + 1))
    while let last = cells.last, last != " ", last != "." {
        cells.removeLast()
    }
    while let last = cells.last, last == " " || last == "." {
        cells.removeLast()
    }
    var text = String(cells)
    if text.hasSuffix(" //") {
        text.removeLast(3)
        while text.hasSuffix(" ") {
            text.removeLast()
        }
    }
    return text
}

/// A ruler of exactly `columns` characters: "." filler, ":" at every 5th
/// column and the column number right-aligned at every 10th
/// (`....:...10....:...20`), so a capture shows which column it is at.
func columnRuler(_ columns: Int) -> String {
    var cells = [Character](repeating: ".", count: columns)
    var column = 5
    while column <= columns {
        cells[column - 1] = ":"
        column += 10
    }
    column = 10
    while column <= columns {
        let digits: [Character] = Array(String(column))
        for (offset, digit) in digits.enumerated() {
            cells[column - digits.count + offset] = digit
        }
        column += 10
    }
    return String(cells)
}

/// The ruler as a comment line: still exactly `columns` wide, with the
/// column numbers in place (`// .:...10....:...20`).
func commentRuler(_ columns: Int) -> String {
    "// " + String(columnRuler(columns).dropFirst(3))
}

/// A generated block of exactly `lineCount` lines whose widest line is
/// exactly `columns`: the `header` line, a comment ruler (exactly
/// `columns` wide), then code lines capped at a width drawn from
/// `minColumns`…`columns`, on a wandering indent.
func generatedCodeBlock(_ rng: inout LCG, header: String, lineCount: Int, columns: Int, minColumns: Int) -> String {
    precondition(lineCount >= 2 && minColumns <= columns && header.utf16.count <= columns,
                 "generatedCodeBlock: \(lineCount) lines x \(columns) columns cannot hold its header and ruler")
    var lines = [header, commentRuler(columns)]
    var depth = 0
    while lines.count < lineCount {
        depth = max(0, min(3, depth + rng.int(0 ..< 3) - 1))
        let width = rng.int(minColumns ..< columns + 1)
        lines.append(codeLine(&rng, columns: width, indent: 4 * depth))
    }
    return lines.joined(separator: "\n")
}

// MARK: - Fixture 10: code-parity.json

enum CodeParitySpec {
    /// CP-03, the storyboard's block: wide enough to pan by 200 pt on any
    /// iPhone (about 1,260 pt of text), under half of the byte budget.
    static let storyboardColumns = 120
    /// CP-15: the E2 shape "one 300-column line among short ones".
    static let longLineColumns = 300
    /// CP-16 and CP-17: the width of the two budget-boundary blocks.
    static let budgetColumns = 100
}

/// Top-level node index → node (block ids are `0.<index>`; every node maps
/// to exactly one prepared block, because there is no table). Append new
/// cases just before `CP-END`, never reorder.
///
///   0 heading CP-S1    1 CP-01 one short line (language present)
///                      2 CP-02 8 lines under 40 columns
///                      3 CP-03 wide block for the storyboard (6 × 120)
///                      4 CP-04 no language attribute
///                      5 CP-05 empty language
///   6 heading CP-S2    7 CP-06 breakout wide      8 CP-07 breakout full-width
///   9 heading CP-S3   10 CP-08 one blank line    11 CP-09 three blank lines
///                     12 CP-10 leading blank line
///                     13 CP-11 / 14 CP-12 / 15 CP-13 one, two, three trailing newlines
///                     16 CP-14 whitespace-only line, trailing spaces on the longest line
///  17 heading CP-S4   18 CP-15 one 300-column line (over 8,192 px wide at 3x, under at 2x)
///                     19 CP-16 just under the canvas budget
///                     20 CP-17 over the canvas budget (at 3x and at 2x)
///                     21 CP-18 short block after it
///  22 heading CP-S5   23 CP-19 tabs              24 CP-20 emoji and CJK
///                     25 CP-21 combining marks   26 CP-22 Hebrew and Arabic
///                     27 CP-23 `""`              28 CP-24 `"\n"`
///  29 heading CP-S6   30 bulletList (CP-25 at 0.30.0.1), 31 panel (CP-26 at 0.31.1),
///                     32 expand (CP-27 at 0.32.1)
///  33 paragraph CP-END
///
/// Groups run from the plainest admitted text to the excluded cases:
/// CP-S1 and CP-S2 are printable ASCII and line feeds, well inside the
/// budget; CP-S3 is still ASCII but blank-line and trailing-newline shapes;
/// CP-S4 is the budget boundary; CP-S5 is outside the admitted cohort
/// (tabs, non-ASCII, no text); CP-S6 is nested code, which stays SwiftUI.
/// No table and no media (issue #8's lazy-stack livelock stays out).
func makeCodeParity() -> CodeFixture {
    var rng = LCG(seed: 0x5EED_C024)
    var blocks: [[String: Any]] = []
    var records: [CodeBlockRecord] = []

    func section(_ title: String) {
        blocks.append(headingNode(level: 2, title))
    }

    /// Appends top-level code block `CP-<number>` and records what was
    /// emitted. The label must be on the first non-empty line, or be the
    /// language when the block has no text; the declared budget verdict
    /// (default configuration, 3x) must be the measured one.
    func code(
        _ number: Int, _ note: String, _ text: String,
        language: String?, breakout: String? = nil, expect: CodeBudgetVerdict = .under
    ) {
        let label = "CP-" + pad2(number)
        let shape = codeTextShape(text)
        let firstLine = text.components(separatedBy: "\n").first(where: { !$0.isEmpty }) ?? ""
        if firstLine.isEmpty {
            precondition(language == label, "code-parity \(label): a block without text carries its label as the language")
        } else {
            precondition(firstLine.contains(label), "code-parity \(label): the first non-empty line must carry the label")
        }
        let verdict = codeBudgetVerdict(lineCount: shape.lineCount, maxColumns: shape.maxLineUTF16)
        precondition(verdict == expect,
                     "code-parity \(label): declared \(expect.rawValue), measured \(verdict.rawValue); re-size it or correct CodeCanvasModel")
        records.append(CodeBlockRecord(
            index: blocks.count, label: label, note: note,
            language: language, breakoutMode: breakout, shape: shape
        ))
        blocks.append(codeBlockNode(language: language, text: text, breakoutMode: breakout))
    }

    func joined(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    // CP-S1: printable ASCII and line feeds, no blank line, no trailing
    // newline, far inside the budget.
    section("CP-S1 Plain code")
    code(1, "one short line; language present", "let answer = 42 // CP-01", language: "swift")
    code(2, "8 lines under 40 columns", joined([
        "// CP-02 eight short lines",
        "struct Point {",
        "    var x: Double",
        "    var y: Double",
        "    func length() -> Double {",
        "        (x * x + y * y).squareRoot()",
        "    }",
        "}",
    ]), language: "swift")
    let wide = CodeParitySpec.storyboardColumns
    let wideFull = codeLine(&rng, columns: wide, indent: 0, exact: true)
    let wideSecond = codeLine(&rng, columns: 88, indent: 4, exact: true)
    let wideThird = codeLine(&rng, columns: 104, indent: 4, exact: true)
    let wideLast = codeLine(&rng, columns: 36, indent: 0, exact: true)
    code(3, "wide block for the storyboard: 6 lines, widest \(wide) columns", joined([
        "// CP-03 wide block: pan horizontally to column \(wide)",
        commentRuler(wide),
        wideFull,
        wideSecond,
        wideThird,
        wideLast,
    ]), language: "swift")
    code(4, "language nil (no attrs)", joined([
        "# CP-04 no language attribute",
        "total = sum(values)",
        "print(total)",
    ]), language: nil)
    code(5, "language empty", joined([
        "# CP-05 empty language attribute",
        "echo \"done\"",
    ]), language: "")

    // CP-S2: the same plain text under a breakout mark.
    section("CP-S2 Breakout")
    code(6, "breakout wide", joined([
        "// CP-06 breakout wide",
        "let columns = layout.columns(for: .wide)",
        "render(columns)",
    ]), language: "swift", breakout: "wide")
    code(7, "breakout full-width", joined([
        "// CP-07 breakout full-width",
        "let columns = layout.columns(for: .fullWidth)",
        "render(columns)",
    ]), language: "swift", breakout: "full-width")

    // CP-S3: blank lines, trailing newlines, whitespace. Still printable
    // ASCII and line feeds only.
    section("CP-S3 Blank lines and trailing newlines")
    code(8, "one blank line in the middle",
         "// CP-08 one blank line\nlet first = 1\n\nlet second = 2", language: "swift")
    code(9, "three blank lines in the middle",
         "// CP-09 three blank lines\nlet first = 1\n\n\n\nlet second = 2", language: "swift")
    code(10, "a leading blank line (label on line 2)",
         "\n// CP-10 leading blank line\nlet value = 3", language: "swift")
    code(11, "one trailing newline",
         "// CP-11 one trailing newline\nlet value = 4\n", language: "swift")
    code(12, "two trailing newlines",
         "// CP-12 two trailing newlines\nlet value = 5\n\n", language: "swift")
    code(13, "three trailing newlines",
         "// CP-13 three trailing newlines\nlet value = 6\n\n\n", language: "swift")
    code(14, "a whitespace-only line; four trailing spaces on the longest line", joined([
        "// CP-14 whitespace-only line",
        "let padded = \"the longest line ends in four spaces\"    ",
        "    ",
        "let after = 7",
    ]), language: "swift")

    // CP-S4: the canvas budget boundary. CP-16 and CP-17 are sized by
    // `codeBudgetVerdict`: CP-16 is the tallest block declared under the
    // budget at this width (3x), CP-17 the shortest declared over it at
    // both 3x and 2x. Their neighbours (CP-16, CP-18) are admitted.
    section("CP-S4 Canvas budget")
    let longLine = codeLine(&rng, columns: CodeParitySpec.longLineColumns, indent: 0, exact: true)
    code(15, "one \(CodeParitySpec.longLineColumns)-column line among short ones", joined([
        "// CP-15 one \(CodeParitySpec.longLineColumns)-column line",
        "let short = 1",
        longLine,
        "let after = 2",
    ]), language: "swift", expect: .over)
    let budgetColumns = CodeParitySpec.budgetColumns
    let nearLines = largestLineCountUnderBudget(columns: budgetColumns)
    let overLines = max(
        smallestLineCountOverBudget(columns: budgetColumns, scale: CodeCanvasModel.displayScale),
        smallestLineCountOverBudget(columns: budgetColumns, scale: 2)
    )
    let nearText = generatedCodeBlock(
        &rng, header: "// CP-16 just under the canvas budget: \(nearLines) lines x \(budgetColumns) columns",
        lineCount: nearLines, columns: budgetColumns, minColumns: 40
    )
    code(16, "just under the canvas budget: the most lines declared under at \(budgetColumns) columns",
         nearText, language: "swift")
    let overText = generatedCodeBlock(
        &rng, header: "// CP-17 over the canvas budget: \(overLines) lines x \(budgetColumns) columns",
        lineCount: overLines, columns: budgetColumns, minColumns: 40
    )
    code(17, "over the canvas budget at 3x and 2x: the fewest lines declared over at \(budgetColumns) columns",
         overText, language: "swift", expect: .over)
    precondition(codeBudgetVerdict(lineCount: overLines, maxColumns: budgetColumns, scale: 2) == .over,
                 "code-parity CP-17 must also be over budget at 2x")
    code(18, "short block after the over-budget one",
         "// CP-18 after the over-budget block\nlet neighbour = true", language: "swift")

    // CP-S5: outside the admitted cohort (tabs, non-ASCII, no text).
    section("CP-S5 Tabs, Unicode and empty code")
    code(19, "leading tabs and a mid-line tab", joined([
        "// CP-19 leading tabs and a mid-line tab",
        "\tlet indented = 1",
        "\t\tlet deeper = 2",
        "let mid = 3\t// after a mid-line tab",
    ]), language: "swift")
    code(20, "emoji and CJK in a comment", joined([
        "// CP-20 emoji 🚀 ✅ 👩🏽‍💻 and CJK 日本語 中文 한국어",
        "let launched = true",
    ]), language: "swift")
    code(21, "combining marks", joined([
        "// CP-21 combining marks: e\u{0301} n\u{0303} a\u{0308} o\u{0302}\u{0323}",
        "let cafe\u{0301} = \"nai\u{0308}ve\"",
    ]), language: "swift")
    code(22, "Hebrew and Arabic strings", joined([
        "// CP-22 Hebrew and Arabic strings",
        "let hebrew = \"שלום עולם\"",
        "let arabic = \"مرحبا بالعالم\"",
    ]), language: "swift")
    code(23, "empty code (no content); the label is the language", "", language: "CP-23")
    code(24, "one newline only; the label is the language", "\n", language: "CP-24")

    // CP-S6: nested code stays SwiftUI. Not recorded as top-level code.
    // Only the code carries `CP-25`…`CP-27`; the containers' own text is
    // labelled `CP-LIST`, `CP-PANEL`, `CP-EXPAND` and `CP-EXPAND-BODY`.
    section("CP-S6 Nested code")
    var notes: [String] = []
    notes.append("0.\(blocks.count).0.1 CP-25 code inside a bullet item (its leader paragraph is 0.\(blocks.count).0.0)")
    blocks.append(bulletListNode([
        listItemNode([
            paragraph([textNode("CP-LIST bullet item that holds a code block")]),
            codeBlockNode(language: "swift", text: "// CP-25 code inside a bullet item\nlet nested = \"list\""),
        ]),
    ]))
    let panelContent: [[String: Any]] = [
        paragraph([textNode("CP-PANEL panel that holds a code block")]),
        codeBlockNode(language: "swift", text: "// CP-26 code inside a panel\nlet nested = \"panel\""),
    ]
    let panelAttrs: [String: Any] = ["panelType": "info"]
    let inPanel: [String: Any] = ["type": "panel", "attrs": panelAttrs, "content": panelContent]
    notes.append("0.\(blocks.count).1 CP-26 code inside a panel")
    blocks.append(inPanel)
    let expandContent: [[String: Any]] = [
        paragraph([textNode("CP-EXPAND-BODY paragraph inside the expand")]),
        codeBlockNode(language: "swift", text: "// CP-27 code inside an expand\nlet nested = \"expand\""),
    ]
    let expandAttrs: [String: Any] = ["title": "CP-EXPAND expand that holds a code block"]
    let inExpand: [String: Any] = ["type": "expand", "attrs": expandAttrs, "content": expandContent]
    notes.append("0.\(blocks.count).1 CP-27 code inside an expand (collapsed at launch; its body is prepared on first expansion)")
    blocks.append(inExpand)

    blocks.append(paragraph([textNode("CP-END end of the code parity fixture")]))
    return CodeFixture(document: doc(blocks), records: records, notes: notes)
}

// MARK: - Fixture 11: code-dense.json

/// The frozen composition of code-dense. Quotas are exact (a seeded
/// shuffle pairs them), so the line-count and drawn-width histograms of
/// version 1 are these numbers by construction.
enum CodeDenseSpec {
    /// THE LIGHTEN LADDER: which version of code-dense is emitted. 1 (the
    /// default) is the fixture as drawn. 2 and 3 are the two fixed
    /// lightenings of `codeDenseLighten`, declared here before any timing
    /// of the fixture exists. There is no version 4, and no other
    /// parameter of this fixture may change once a timing has been seen.
    static let version = 1
    static let blockCount = 600
    /// Line-count buckets and quotas: 5 % one line, 40 % 3–8, 40 % 9–20,
    /// 15 % 21–40. Uniform within a bucket.
    static let lineBuckets: [ClosedRange<Int>] = [1 ... 1, 3 ... 8, 9 ... 20, 21 ... 40]
    static let lineQuotas = [30, 240, 240, 90]
    /// Width buckets (the widest line, in columns) and quotas: 55 % up to
    /// 40, 35 % 60–120, 10 % 150–220. Uniform within a bucket.
    static let widthBuckets: [ClosedRange<Int>] = [16 ... 40, 60 ... 120, 150 ... 220]
    static let widthQuotas = [330, 210, 60]
    /// Blocks deliberately left over the canvas budget: 3 % of 600.
    static let overBudgetCount = 18
    /// Blocks 0..<3 are pinned to 3–8 lines and at most 40 columns, so at
    /// least two admitted blocks are on the first screen.
    static let firstScreenBlocks = 3
    /// Language by index: none for `i % 20 == 3` (30 blocks), empty for
    /// `i % 20 == 13` (30 blocks), otherwise `languages[i % 6]`.
    static let languages = ["swift", "json", "python", "sql", "bash", "kotlin"]
}

/// What happened to code-dense on the way out; printed by the emit step.
struct CodeDenseSummary {
    /// Blocks per [line bucket][width bucket], as drawn (before the
    /// budget rule moves any width).
    var drawnJoint: [[Int]] = []
    /// Blocks whose drawn shape was declared over budget / marginal.
    var drawnOver = 0
    var drawnMarginal = 0
    /// Indices deliberately left over budget.
    var keptOver: [Int] = []
    /// Indices the budget rule shortened, and how many lines it cut.
    var shortenedBlocks: [Int] = []
    var shortenedLines = 0
    /// The lighten ladder: the version emitted, how many blocks it moved
    /// down from the tallest line bucket and from the widest width bucket,
    /// and how many kept over-budget blocks it re-shaped (all 0 in
    /// version 1).
    var version = 1
    var lightenedTall = 0
    var lightenedWide = 0
    var reshapedKept = 0
}

struct CodeDenseShape {
    let lineBucket: Int
    let widthBucket: Int
    let lineCount: Int
    let columns: Int
}

/// `quotas[k]` copies of bucket `k`, shuffled (Fisher–Yates on `rng`).
func codeDenseShuffledBuckets(_ rng: inout LCG, quotas: [Int]) -> [Int] {
    var buckets: [Int] = []
    for (bucket, quota) in quotas.enumerated() {
        buckets.append(contentsOf: [Int](repeating: bucket, count: quota))
    }
    var i = buckets.count - 1
    while i > 0 {
        let j = rng.int(0 ..< i + 1)
        buckets.swapAt(i, j)
        i -= 1
    }
    return buckets
}

/// Makes the first-screen blocks draw bucket `wanted`, by swapping each
/// with the first later block that drew it. The quotas stay exact.
func codeDensePinFirstScreen(_ buckets: inout [Int], to wanted: Int) {
    let pinned = CodeDenseSpec.firstScreenBlocks
    for i in 0 ..< pinned where buckets[i] != wanted {
        var j = pinned
        while j < buckets.count, buckets[j] != wanted {
            j += 1
        }
        precondition(j < buckets.count, "code-dense: no later block drew bucket \(wanted)")
        buckets.swapAt(i, j)
    }
}

/// Pass 1: every block's shape, before any text is drawn — so the joint
/// distribution depends on the seed and the quotas only, never on the
/// text synthesiser.
func codeDenseShapes(_ rng: inout LCG) -> [CodeDenseShape] {
    var lineBuckets = codeDenseShuffledBuckets(&rng, quotas: CodeDenseSpec.lineQuotas)
    var widthBuckets = codeDenseShuffledBuckets(&rng, quotas: CodeDenseSpec.widthQuotas)
    precondition(lineBuckets.count == CodeDenseSpec.blockCount && widthBuckets.count == CodeDenseSpec.blockCount,
                 "code-dense: quotas must add up to the block count")
    codeDensePinFirstScreen(&lineBuckets, to: 1)
    codeDensePinFirstScreen(&widthBuckets, to: 0)
    var shapes: [CodeDenseShape] = []
    shapes.reserveCapacity(CodeDenseSpec.blockCount)
    for i in 0 ..< CodeDenseSpec.blockCount {
        let lineRange = CodeDenseSpec.lineBuckets[lineBuckets[i]]
        let widthRange = CodeDenseSpec.widthBuckets[widthBuckets[i]]
        let lineCount = rng.int(lineRange.lowerBound ..< lineRange.upperBound + 1)
        let columns = rng.int(widthRange.lowerBound ..< widthRange.upperBound + 1)
        shapes.append(CodeDenseShape(
            lineBucket: lineBuckets[i], widthBucket: widthBuckets[i],
            lineCount: lineCount, columns: columns
        ))
    }
    return shapes
}

/// The blocks version 1 keeps over budget, from the drawn shapes alone:
/// `overBudgetCount` of the shapes declared over budget, evenly spaced
/// through them in index order. Version 1 itself decides on its emitted
/// text, which has exactly its drawn shape, so it keeps these same blocks.
func codeDenseKeptOverBudget(_ shapes: [CodeDenseShape]) -> [Int] {
    var drawnOver: [Int] = []
    for (index, shape) in shapes.enumerated() {
        if codeBudgetVerdict(lineCount: shape.lineCount, maxColumns: shape.columns) == .over {
            drawnOver.append(index)
        }
    }
    precondition(drawnOver.count >= CodeDenseSpec.overBudgetCount,
                 "code-dense: only \(drawnOver.count) shapes drew over budget; \(CodeDenseSpec.overBudgetCount) must be kept")
    var kept: [Int] = []
    for k in 0 ..< CodeDenseSpec.overBudgetCount {
        kept.append(drawnOver[k * drawnOver.count / CodeDenseSpec.overBudgetCount])
    }
    return kept
}

/// THE LIGHTEN LADDER (`CodeDenseSpec.version`), fixed before any timing of
/// the fixture exists. Version 1 changes nothing and returns nil. Versions
/// 2 and 3 start from version 1's shapes (same seed, same draws in pass 1)
/// and change only these, in index order, with no new draw:
///
///   - a block of the tallest line bucket (21–40 lines) that version 1 does
///     not keep over budget moves down one bucket, to 9–20 lines:
///     `9 + (lineCount − 21) % 12`. Version 2 moves every second such block
///     (ranks 1, 3, 5, …), version 3 every one;
///   - a block of the widest bucket (150–220 columns) that version 1 does
///     not keep over budget moves down one bucket the same way, to 60–120
///     columns: `60 + (columns − 150) % 61`;
///   - version 3 only: a block version 1 keeps over budget that is in the
///     tallest bucket gets the same line count rule and is widened, if it
///     must be, to the narrowest width still declared over budget at its
///     new line count. So version 3 has no block of more than 20 lines.
///
/// Every version keeps the blocks version 1 keeps over budget (the
/// returned indices), 600 blocks and the `// CD-<iii>` sentinels; the
/// budget rule then runs unchanged. Only pass 2's text differs: it is
/// drawn for the new shapes.
func codeDenseLighten(_ shapes: inout [CodeDenseShape], version: Int, summary: inout CodeDenseSummary) -> [Int]? {
    precondition(version >= 1 && version <= 3, "code-dense: CodeDenseSpec.version must be 1, 2 or 3")
    summary.version = version
    guard version > 1 else { return nil }

    let kept = codeDenseKeptOverBudget(shapes)
    let keptSet = Set(kept)
    let tallest = CodeDenseSpec.lineBuckets.count - 1
    let widest = CodeDenseSpec.widthBuckets.count - 1
    let tallFrom = CodeDenseSpec.lineBuckets[tallest].lowerBound
    let tallTo = CodeDenseSpec.lineBuckets[tallest - 1]
    let wideFrom = CodeDenseSpec.widthBuckets[widest].lowerBound
    let wideTo = CodeDenseSpec.widthBuckets[widest - 1]
    var tallRank = 0
    var wideRank = 0
    for index in 0 ..< shapes.count {
        let shape = shapes[index]
        var lineBucket = shape.lineBucket
        var widthBucket = shape.widthBucket
        var lineCount = shape.lineCount
        var columns = shape.columns
        if keptSet.contains(index) {
            // Kept over budget: only version 3 touches it, and only when
            // it is in the tallest bucket. Its width bucket label stays.
            if version == 3 && shape.lineBucket == tallest {
                lineCount = tallTo.lowerBound + (shape.lineCount - tallFrom) % tallTo.count
                lineBucket = tallest - 1
                columns = max(shape.columns, smallestColumnsOverBudget(lineCount: lineCount))
                summary.reshapedKept += 1
            }
        } else {
            if shape.lineBucket == tallest {
                if version == 3 || tallRank % 2 == 1 {
                    lineCount = tallTo.lowerBound + (shape.lineCount - tallFrom) % tallTo.count
                    lineBucket = tallest - 1
                    summary.lightenedTall += 1
                }
                tallRank += 1
            }
            if shape.widthBucket == widest {
                if version == 3 || wideRank % 2 == 1 {
                    columns = wideTo.lowerBound + (shape.columns - wideFrom) % wideTo.count
                    widthBucket = widest - 1
                    summary.lightenedWide += 1
                }
                wideRank += 1
            }
        }
        shapes[index] = CodeDenseShape(
            lineBucket: lineBucket, widthBucket: widthBucket,
            lineCount: lineCount, columns: columns
        )
    }
    return kept
}

/// Pass 2: the lines of block `index`. Line 0 starts with `// CD-<iii>`
/// (and is exactly that unless the block has one line, which continues as
/// a comment to the block's width). One later line, drawn at random, is
/// exactly `shape.columns` wide; the others are capped at a width drawn
/// from 12…64 (never above the block's width), one in six of them from the
/// upper half of the block's width instead.
func codeDenseLines(_ rng: inout LCG, index: Int, shape: CodeDenseShape) -> [String] {
    let sentinel = "// CD-" + pad3(index)
    if shape.lineCount == 1 {
        var line = sentinel
        _ = extendCodeLine(&rng, &line, columns: shape.columns, inComment: true)
        padCodeLine(&rng, &line, columns: shape.columns, inComment: true)
        return [line]
    }
    var lines = [sentinel]
    let widestRow = rng.int(1 ..< shape.lineCount)
    var depth = 0
    for row in 1 ..< shape.lineCount {
        depth = max(0, min(3, depth + rng.int(0 ..< 3) - 1))
        let columns: Int
        if row == widestRow {
            columns = shape.columns
        } else if rng.oneIn(6) {
            columns = rng.int(shape.columns / 2 ..< shape.columns + 1)
        } else {
            let typical = min(shape.columns, 64)
            columns = rng.int(min(12, typical) ..< typical + 1)
        }
        lines.append(codeLine(&rng, columns: columns, indent: 4 * depth, exact: row == widestRow))
    }
    return lines
}

/// The frozen budget rule (part of the generator, not a tuning pass):
/// while the block is not declared under budget, shorten its widest line
/// (at a token boundary) to at most the widest length that is. The TRUE
/// maximum is recomputed across all lines after every cut, so a second
/// line that was nearly as wide is shortened too. Returns how many lines
/// were shortened.
func shortenCodeLinesToBudget(_ lines: inout [String]) -> Int {
    var cuts = 0
    while true {
        var widest = 0
        var widestIndex = 0
        for (index, line) in lines.enumerated() where line.utf16.count > widest {
            widest = line.utf16.count
            widestIndex = index
        }
        if codeBudgetVerdict(lineCount: lines.count, maxColumns: widest) == .under {
            return cuts
        }
        let target = largestColumnsUnderBudget(lineCount: lines.count)
        precondition(target >= 16 && target < widest,
                     "code-dense: \(lines.count) lines cannot be brought under budget by shortening (target \(target))")
        lines[widestIndex] = shortenedCodeLine(lines[widestIndex], to: target)
        cuts += 1
    }
}

func codeDenseLanguage(index: Int) -> String? {
    switch index % 20 {
    case 3: return nil
    case 13: return ""
    default: return CodeDenseSpec.languages[index % CodeDenseSpec.languages.count]
    }
}

/// A breakout mark on `i % 20 == 7` (30 blocks, 5 %): `wide` in even
/// twenties, `full-width` in odd ones (15 each).
func codeDenseBreakout(index: Int) -> String? {
    guard index % 20 == 7 else { return nil }
    return (index / 20) % 2 == 0 ? "wide" : "full-width"
}

/// 600 top-level code blocks and nothing else. Three passes on one seed:
/// shapes, then text, then the budget rule — which keeps
/// `CodeDenseSpec.overBudgetCount` of the blocks drawn over budget (evenly
/// spaced through them, in index order) and shortens every other block
/// that is not declared under budget. Between the first two passes the
/// lighten ladder (`codeDenseLighten`) re-shapes some blocks in versions 2
/// and 3; in version 1 it does nothing.
func makeCodeDense(summary: inout CodeDenseSummary) -> CodeFixture {
    var rng = LCG(seed: 0x5EED_C600)
    var shapes = codeDenseShapes(&rng)
    // nil in version 1; in versions 2 and 3 the blocks version 1 keeps.
    let ladderKept = codeDenseLighten(&shapes, version: CodeDenseSpec.version, summary: &summary)

    var blockLines: [[String]] = []
    blockLines.reserveCapacity(shapes.count)
    for (index, shape) in shapes.enumerated() {
        blockLines.append(codeDenseLines(&rng, index: index, shape: shape))
    }

    summary.drawnJoint = [[Int]](
        repeating: [Int](repeating: 0, count: CodeDenseSpec.widthBuckets.count),
        count: CodeDenseSpec.lineBuckets.count
    )
    var drawnOver: [Int] = []
    for (index, shape) in shapes.enumerated() {
        summary.drawnJoint[shape.lineBucket][shape.widthBucket] += 1
        // Measured on the text, not taken from the drawn shape.
        let measured = codeTextShape(blockLines[index].joined(separator: "\n"))
        precondition(measured.lineCount == shape.lineCount && measured.maxLineUTF16 == shape.columns,
                     "code-dense CD-\(pad3(index)): emitted text does not have its drawn shape")
        switch codeBudgetVerdict(lineCount: measured.lineCount, maxColumns: measured.maxLineUTF16) {
        case .over: drawnOver.append(index)
        case .marginal: summary.drawnMarginal += 1
        case .under: break
        }
    }
    summary.drawnOver = drawnOver.count
    precondition(drawnOver.count >= CodeDenseSpec.overBudgetCount,
                 "code-dense: only \(drawnOver.count) blocks drew over budget; \(CodeDenseSpec.overBudgetCount) must be kept")
    var keptOver = Set<Int>()
    if let ladderKept {
        // Versions 2 and 3: the same blocks as version 1, whatever else
        // still draws over budget after the lightening.
        keptOver = Set(ladderKept)
    } else {
        for k in 0 ..< CodeDenseSpec.overBudgetCount {
            keptOver.insert(drawnOver[k * drawnOver.count / CodeDenseSpec.overBudgetCount])
        }
    }
    precondition(keptOver.count == CodeDenseSpec.overBudgetCount, "code-dense: kept over-budget blocks must be distinct")
    summary.keptOver = keptOver.sorted()

    var blocks: [[String: Any]] = []
    var records: [CodeBlockRecord] = []
    blocks.reserveCapacity(shapes.count)
    records.reserveCapacity(shapes.count)
    for index in 0 ..< blockLines.count {
        var lines = blockLines[index]
        let kept = keptOver.contains(index)
        if !kept {
            let cuts = shortenCodeLinesToBudget(&lines)
            if cuts > 0 {
                summary.shortenedBlocks.append(index)
                summary.shortenedLines += cuts
            }
        }
        let text = lines.joined(separator: "\n")
        let shape = codeTextShape(text)
        let verdict = codeBudgetVerdict(lineCount: shape.lineCount, maxColumns: shape.maxLineUTF16)
        let label = "CD-" + pad3(index)
        // The eligible-code contract of this fixture: admitted-cohort text
        // and no shape a parity rule could exclude (no blank or
        // whitespace-only line, no trailing space, no trailing newline).
        precondition(shape.isPrintableASCIIAndLF && shape.trailingNewlineCount == 0,
                     "code-dense \(label): text must be printable ASCII and line feeds with no trailing newline")
        precondition(!lines.contains(where: { $0.isEmpty || $0.hasSuffix(" ") }),
                     "code-dense \(label): no line may be blank or end in a space")
        precondition(lines[0].hasPrefix("// " + label), "code-dense \(label): the first line must start with the sentinel")
        precondition(verdict == (kept ? CodeBudgetVerdict.over : CodeBudgetVerdict.under),
                     "code-dense \(label): measured \(verdict.rawValue) after the budget rule")
        let language = codeDenseLanguage(index: index)
        let breakout = codeDenseBreakout(index: index)
        records.append(CodeBlockRecord(
            index: index, label: label, note: kept ? "kept over budget" : "",
            language: language, breakoutMode: breakout, shape: shape
        ))
        blocks.append(codeBlockNode(language: language, text: text, breakoutMode: breakout))
    }
    return CodeFixture(document: doc(blocks), records: records)
}

// MARK: - Fixture 12: code-tall.json

enum CodeTallSpec {
    /// Width of the two large blocks.
    static let columns = 60
    /// CT-TALL: over the height limit and the byte budget at any scale.
    static let tallLineCount = 400

    /// One block of the near-limit sequence: the dimension that is given.
    /// The other one is the largest that is still declared under budget.
    enum SequenceShape {
        /// That many columns, and as many lines as stay under budget.
        case columns(Int)
        /// That many lines, and as wide as stays under budget.
        case lines(Int)
    }

    /// CT-SEQ-1 … CT-SEQ-8, in this order: from narrow and tall to wide and
    /// short, so the last four fit on one screen together where the
    /// autoscroll ends. No width is under 40 columns (the header line must
    /// fit).
    static let sequence: [SequenceShape] = [
        .columns(40), .columns(50), .columns(64), .columns(80),
        .lines(18), .lines(13), .lines(9), .lines(6),
    ]
}

/// Eleven top-level code blocks and one heading:
///   0.0 CT-TALL  400 lines × 60 columns, over budget (SwiftUI in both
///                arms). Every 50th line is a `// CT-L<iii>` marker.
///   0.1 CT-NEAR  60 columns × the most lines declared under budget: the
///                largest eligible canvas of the default configuration.
///   0.2 CT-END   a short block after it, so an autoscroll leg crosses all
///                of CT-NEAR.
///   0.3          heading `CT-SEQ …`
///   0.4 … 0.11   CT-SEQ-1 … CT-SEQ-8, the bounded near-limit sequence:
///                eight consecutive blocks, each just under the canvas
///                budget (`CodeTallSpec.sequence`), to read how many
///                near-limit canvases are live at once. Appended after the
///                first three blocks, so their ids and text do not depend
///                on it.
func makeCodeTall() -> CodeFixture {
    var rng = LCG(seed: 0x5EED_C400)
    let columns = CodeTallSpec.columns
    let tallLineCount = CodeTallSpec.tallLineCount
    var blocks: [[String: Any]] = []
    var records: [CodeBlockRecord] = []

    func code(_ label: String, _ note: String, _ text: String, expect: CodeBudgetVerdict) {
        let shape = codeTextShape(text)
        let verdict = codeBudgetVerdict(lineCount: shape.lineCount, maxColumns: shape.maxLineUTF16)
        precondition(shape.isPrintableASCIIAndLF && text.hasPrefix("// " + label),
                     "code-tall \(label): text must be printable ASCII and line feeds and start with its label")
        precondition(verdict == expect,
                     "code-tall \(label): declared \(expect.rawValue), measured \(verdict.rawValue); re-size it or correct CodeCanvasModel")
        records.append(CodeBlockRecord(
            index: blocks.count, label: label, note: note,
            language: "swift", breakoutMode: nil, shape: shape
        ))
        blocks.append(codeBlockNode(language: "swift", text: text))
    }

    var tall = ["// CT-TALL \(tallLineCount) lines x \(columns) columns: over the budget"]
    var depth = 0
    for row in 2 ... tallLineCount {
        if row % 50 == 0 {
            tall.append("// CT-L" + pad3(row) + " line \(row) of \(tallLineCount)")
            continue
        }
        depth = max(0, min(3, depth + rng.int(0 ..< 3) - 1))
        // Every tenth line is exactly `columns` wide; the rest are capped
        // at a width drawn from 20…columns.
        let exact = row % 10 == 5
        let width = exact ? columns : rng.int(20 ..< columns + 1)
        tall.append(codeLine(&rng, columns: width, indent: 4 * depth, exact: exact))
    }
    let tallText = tall.joined(separator: "\n")
    precondition(codeTextShape(tallText).maxLineUTF16 == columns && tall.count == tallLineCount,
                 "code-tall CT-TALL must be exactly \(tallLineCount) lines x \(columns) columns")
    code("CT-TALL", "\(tallLineCount) lines x \(columns) columns, over budget", tallText, expect: .over)

    let nearLines = largestLineCountUnderBudget(columns: columns)
    let nearText = generatedCodeBlock(
        &rng, header: "// CT-NEAR just under budget: \(nearLines) lines x \(columns) columns",
        lineCount: nearLines, columns: columns, minColumns: 20
    )
    code("CT-NEAR", "the most lines declared under budget at \(columns) columns", nearText, expect: .under)

    code("CT-END", "short closing block", "// CT-END closing block\nlet done = true", expect: .under)

    // The near-limit sequence. Drawn after everything above, from the same
    // random stream, so the three blocks above are the same with or
    // without it.
    blocks.append(headingNode(level: 2, "CT-SEQ near-limit sequence: eight blocks just under the canvas budget"))
    for (offset, entry) in CodeTallSpec.sequence.enumerated() {
        let seqLines: Int
        let seqColumns: Int
        switch entry {
        case .columns(let count):
            seqColumns = count
            seqLines = largestLineCountUnderBudget(columns: count)
        case .lines(let count):
            seqLines = count
            seqColumns = largestColumnsUnderBudget(lineCount: count)
        }
        let label = "CT-SEQ-\(offset + 1)"
        // Just under: one more line, or one more column, is no longer
        // declared under budget.
        precondition(codeBudgetVerdict(lineCount: seqLines + 1, maxColumns: seqColumns) != .under
                         || codeBudgetVerdict(lineCount: seqLines, maxColumns: seqColumns + 1) != .under,
                     "code-tall \(label): \(seqLines) lines x \(seqColumns) columns is not at the edge of the budget")
        let seqText = generatedCodeBlock(
            &rng, header: "// \(label) \(seqLines) lines x \(seqColumns) columns",
            lineCount: seqLines, columns: seqColumns, minColumns: 20
        )
        code(label, "near-limit sequence: \(seqLines) lines x \(seqColumns) columns, just under budget", seqText, expect: .under)
    }
    return CodeFixture(document: doc(blocks), records: records)
}

// MARK: - Container and caption fixtures: node builders

/// A panel. `panelType` is one of the seven palettes; a custom panel may
/// carry an emoji icon and a colour.
func panelNode(_ panelType: String, _ content: [[String: Any]], icon: String? = nil, color: String? = nil) -> [String: Any] {
    var attrs: [String: Any] = ["panelType": panelType]
    if let icon { attrs["panelIcon"] = icon }
    if let color { attrs["panelColor"] = color }
    return ["type": "panel", "attrs": attrs, "content": content]
}

func quoteNode(_ content: [[String: Any]]) -> [String: Any] {
    ["type": "blockquote", "content": content]
}

/// A bodied extension (macro). Its placeholder shows `title` (the `text`
/// attribute) above the body.
func bodiedExtensionNode(key: String, title: String, localId: String, _ content: [[String: Any]]) -> [String: Any] {
    let attrs: [String: Any] = [
        "extensionType": "com.atlassian.confluence.macro.core",
        "extensionKey": key,
        "text": title,
        "layout": "default",
        "localId": localId,
    ]
    return ["type": "bodiedExtension", "attrs": attrs, "content": content]
}

/// A bodiless extension: a placeholder with a title and no text.
func extensionNode(key: String, title: String, localId: String) -> [String: Any] {
    let attrs: [String: Any] = [
        "extensionType": "com.atlassian.confluence.macro.core",
        "extensionKey": key,
        "text": title,
        "layout": "default",
        "localId": localId,
    ]
    return ["type": "extension", "attrs": attrs]
}

/// One layout column. `width` is the percentage attribute as written,
/// zero and negative values included.
func layoutColumnNode(width: Int, _ content: [[String: Any]]) -> [String: Any] {
    let attrs: [String: Any] = ["width": width]
    return ["type": "layoutColumn", "attrs": attrs, "content": content]
}

func layoutSectionNode(_ columns: [[String: Any]]) -> [String: Any] {
    ["type": "layoutSection", "content": columns]
}

func expandNode(_ title: String, _ content: [[String: Any]]) -> [String: Any] {
    let attrs: [String: Any] = ["title": title]
    return ["type": "expand", "attrs": attrs, "content": content]
}

/// A `nestedExpand`. The schema allows it in an expand, a table cell and a
/// layout column; the parser and the views accept it anywhere, nested
/// expands included.
func nestedExpandNode(_ title: String, _ content: [[String: Any]]) -> [String: Any] {
    let attrs: [String: Any] = ["title": title]
    return ["type": "nestedExpand", "attrs": attrs, "content": content]
}

/// A paragraph with an `indentation` mark (levels 1–6, 24 pt each).
func indentedParagraphNode(level: Int, _ content: [[String: Any]]) -> [String: Any] {
    let markAttrs: [String: Any] = ["level": level]
    let mark: [String: Any] = ["type": "indentation", "attrs": markAttrs]
    let marks: [[String: Any]] = [mark]
    return ["type": "paragraph", "content": content, "marks": marks]
}

/// A reference-only sync block: no inline copy, so it prepares to a
/// "Synced block" placeholder with no text.
func syncBlockNode(resourceId: String, localId: String) -> [String: Any] {
    let attrs: [String: Any] = ["resourceId": resourceId, "localId": localId]
    return ["type": "syncBlock", "attrs": attrs]
}

/// A bodied sync block: transparent, its content prepares in place.
func bodiedSyncBlockNode(resourceId: String, localId: String, _ content: [[String: Any]]) -> [String: Any] {
    let attrs: [String: Any] = ["resourceId": resourceId, "localId": localId]
    return ["type": "bodiedSyncBlock", "attrs": attrs, "content": content]
}

/// A table: one header row (`header`, one block list per cell) and body
/// rows (`rows`, each one block list per cell).
func tableNode(header: [[[String: Any]]], rows: [[[[String: Any]]]]) -> [String: Any] {
    var tableRows: [[String: Any]] = []
    let headerCells: [[String: Any]] = header.map { ["type": "tableHeader", "content": $0] }
    tableRows.append(["type": "tableRow", "content": headerCells])
    for row in rows {
        let cells: [[String: Any]] = row.map { ["type": "tableCell", "content": $0] }
        tableRows.append(["type": "tableRow", "content": cells])
    }
    let attrs: [String: Any] = ["isNumberColumnEnabled": false, "layout": "default"]
    return ["type": "table", "attrs": attrs, "content": tableRows]
}

func embedCardNode(url: String) -> [String: Any] {
    let attrs: [String: Any] = [
        "url": url, "layout": "center", "width": 100, "originalWidth": 640, "originalHeight": 360,
    ]
    return ["type": "embedCard", "attrs": attrs]
}

/// A `placeholder` inline node: prepared as a grey italic text run (not an
/// atom).
func placeholderTextNode(_ text: String) -> [String: Any] {
    let attrs: [String: Any] = ["text": text]
    return ["type": "placeholder", "attrs": attrs]
}

/// An external `media` node. The demo's provider draws every URL as an
/// offline gradient; no network.
func externalMediaNode(url: String, width: Int, height: Int, alt: String) -> [String: Any] {
    let attrs: [String: Any] = ["type": "external", "url": url, "width": width, "height": height, "alt": alt]
    return ["type": "media", "attrs": attrs]
}

/// A `mediaSingle` at a fixed pixel width. `caption` nil emits no caption
/// node; `[]` emits an empty one.
func mediaSingleNode(layout: String, pixelWidth: Int, media: [String: Any], caption: [[String: Any]]?) -> [String: Any] {
    let attrs: [String: Any] = ["layout": layout, "width": pixelWidth, "widthType": "pixel"]
    var content: [[String: Any]] = [media]
    if let caption {
        content.append(["type": "caption", "content": caption])
    }
    return ["type": "mediaSingle", "attrs": attrs, "content": content]
}

// MARK: - Container fixtures: estimator and prepared-root mirrors

/// Characters the autoscroll estimator counts for inline `content`: text
/// as grapheme clusters, a hard break as one, an emoji with a Unicode form
/// as its text, a placeholder as its text, any other inline atom as 10
/// (`BlockHeightEstimator.characterCount`, on the composer's output).
func estimatorCharacters(_ inline: [[String: Any]]) -> Int {
    var count = 0
    for node in inline {
        let attrs = node["attrs"] as? [String: Any]
        switch node["type"] as? String {
        case "text":
            count += (node["text"] as? String ?? "").count
        case "hardBreak":
            count += 1
        case "emoji":
            if let text = attrs?["text"] as? String, !text.isEmpty {
                count += text.count
            } else {
                count += 10
            }
        case "placeholder":
            count += (attrs?["text"] as? String ?? "").count
        default:
            count += 10
        }
    }
    return count
}

func estimatorIsList(_ type: String?) -> Bool {
    type == "bulletList" || type == "orderedList" || type == "taskList" || type == "decisionList"
}

/// One list row: `BlockHeightEstimator`'s `.listRows` term.
func estimatorListRowPoints(characters: Int, depth: Int, trailing: Double) -> Double {
    let indent = Double(depth) * 24 + 28
    let charsPerLine = max(16, (360 - indent) / 8)
    let lines = max(1, Int((Double(characters) / charsPerLine).rounded(.up)))
    return Double(lines) * 22 + 6 + trailing
}

/// The rows of one list node, flattened as `ListPreparer` does: a row per
/// item at its depth, nested lists one level deeper, blocks after the
/// leader on the item's row (a marker-less continuation row of its own
/// once a nested list came first).
func estimatorListPoints(_ list: [String: Any], depth: Int) -> Double {
    var total = 0.0
    for item in list["content"] as? [[String: Any]] ?? [] {
        let itemType = item["type"] as? String
        let children = item["content"] as? [[String: Any]] ?? []
        if estimatorIsList(itemType) {
            total += estimatorListPoints(item, depth: depth + 1)
        } else if itemType == "taskItem" || itemType == "decisionItem" {
            total += estimatorListRowPoints(characters: estimatorCharacters(children), depth: depth, trailing: 0)
        } else {
            var leaderCharacters = 0
            var rest = children[...]
            if let first = children.first, first["type"] as? String == "paragraph" {
                leaderCharacters = estimatorCharacters(first["content"] as? [[String: Any]] ?? [])
                rest = children.dropFirst()
            }
            var trailing = 0.0
            var nested = 0.0
            var continuation = 0.0
            var sawNested = false
            for child in rest {
                if estimatorIsList(child["type"] as? String) {
                    nested += estimatorListPoints(child, depth: depth + 1)
                    sawNested = true
                } else if sawNested {
                    if continuation == 0 { continuation = estimatorListRowPoints(characters: 0, depth: depth, trailing: 0) }
                    continuation += estimatorPoints(child)
                } else {
                    trailing += estimatorPoints(child)
                }
            }
            total += estimatorListRowPoints(characters: leaderCharacters, depth: depth, trailing: trailing) + nested + continuation
        }
    }
    return total
}

/// The autoscroll estimator's height of one block node, in points: a
/// mirror of `BlockHeightEstimator` (Demo/ADFReader/AutoScroller.swift) on
/// emitted nodes, for every kind the PR 4 fixtures emit. The demo applies
/// it to prepared top-level blocks and paces 1,200 pt/s; a closed expand
/// is 48 pt whatever its body, and layout columns count their tallest
/// column (side by side), so stacked columns scroll faster than estimated.
func estimatorPoints(_ node: [String: Any]) -> Double {
    let content = node["content"] as? [[String: Any]] ?? []
    let attrs = node["attrs"] as? [String: Any]
    func sum(_ nodes: [[String: Any]]) -> Double { nodes.reduce(0) { $0 + estimatorPoints($1) } }
    func textLines(_ characters: Int) -> Int { max(1, (characters + 44) / 45) }
    switch node["type"] as? String {
    case "paragraph":
        return Double(textLines(estimatorCharacters(content))) * 22 + 12
    case "heading":
        let lineHeight: Double
        switch attrs?["level"] as? Int ?? 1 {
        case 1: lineHeight = 38
        case 2: lineHeight = 32
        case 3: lineHeight = 27
        default: lineHeight = 24
        }
        return Double(textLines(estimatorCharacters(content))) * lineHeight + 12
    case "panel":
        return 24 + sum(content)
    case "blockquote":
        return 8 + sum(content)
    case "bodiedExtension":
        return 56 + sum(content)
    case "extension":
        return 56
    case "syncBlock", "bodiedSyncBlock":
        return content.isEmpty ? 56 : sum(content)
    case "expand", "nestedExpand":
        return 48
    case "layoutSection":
        return content.reduce(0) { tallest, column in
            max(tallest, sum(column["content"] as? [[String: Any]] ?? []))
        }
    case "codeBlock":
        let text = content.compactMap { $0["text"] as? String }.joined()
        return Double(text.utf8.filter { $0 == 0x0A }.count + 1) * 19 + 28
    case "rule":
        return 20
    case "bulletList", "orderedList", "taskList", "decisionList":
        return estimatorListPoints(node, depth: 0)
    case "mediaSingle":
        let media = content.first { $0["type"] as? String == "media" }
        let mediaAttrs = media?["attrs"] as? [String: Any]
        let hasCaption = content.contains { $0["type"] as? String == "caption" }
        var height = 220.0
        if let width = mediaAttrs?["width"] as? Int, let mediaHeight = mediaAttrs?["height"] as? Int, width > 0 {
            let displayWidth: Double
            if attrs?["widthType"] as? String == "pixel", let pixel = attrs?["width"] as? Int {
                displayWidth = min(Double(pixel), 360)
            } else {
                displayWidth = min(Double(width), 360)
            }
            height = Double(mediaHeight) / Double(width) * displayWidth
        }
        return height + (hasCaption ? 24 : 0)
    case "table":
        // One header slice and one slice per two body rows; a row of
        // one-line cells is 37 pt (rough: no PR 4 fixture is sized by it).
        return Double(content.count) * 37
    case "embedCard", "blockCard":
        return 76
    default:
        return 36
    }
}

/// The estimate of a whole document, in points.
func estimatorDocumentPoints(_ document: [String: Any]) -> Double {
    (document["content"] as? [[String: Any]] ?? []).reduce(0) { $0 + estimatorPoints($1) }
}

/// The prepared top-level block ids of `content` (`DocumentPreparer.prepare`):
/// `<parent>.<index>` per node, except a table (a `#header` slice when its
/// first row is all header cells, then a `#rows<k>` slice per two body
/// rows) and a sync block with content (transparent: its children's blocks
/// in place). Covers every kind the PR 4 fixtures put at the top level.
func preparedRootIDs(_ content: [[String: Any]], parentID: String = "0") -> [String] {
    var ids: [String] = []
    for (index, node) in content.enumerated() {
        let id = "\(parentID).\(index)"
        let children = node["content"] as? [[String: Any]] ?? []
        switch node["type"] as? String {
        case "table":
            var rows = children[...]
            if let first = rows.first,
               let cells = first["content"] as? [[String: Any]], !cells.isEmpty,
               cells.allSatisfy({ $0["type"] as? String == "tableHeader" }) {
                ids.append(id + "#header")
                rows = rows.dropFirst()
            }
            for slice in 0 ..< (rows.count + 1) / 2 {
                ids.append(id + "#rows\(slice)")
            }
        case "syncBlock", "bodiedSyncBlock":
            if children.isEmpty {
                ids.append(id)
            } else {
                ids += preparedRootIDs(children, parentID: id)
            }
        default:
            ids.append(id)
        }
    }
    return ids
}

// MARK: - Container fixtures: landmark and owner tables (`--landmarks`)

/// The first sentinel token in `text`: from the earliest occurrence of one
/// of `prefixes`, the longest run of A–Z, 0–9 and "-" (a trailing "-"
/// dropped).
func sentinelToken(in text: String, prefixes: [String]) -> String? {
    var start: String.Index?
    for prefix in prefixes {
        if let range = text.range(of: prefix), start.map({ range.lowerBound < $0 }) ?? true {
            start = range.lowerBound
        }
    }
    guard let start else { return nil }
    var end = start
    while end < text.endIndex, let ascii = text[end].asciiValue,
          (65 ... 90).contains(ascii) || (48 ... 57).contains(ascii) || ascii == 45 {
        end = text.index(after: end)
    }
    var token = String(text[start ..< end])
    while token.hasSuffix("-") {
        token.removeLast()
    }
    return token.isEmpty ? nil : token
}

/// The text of inline `content`: text runs and placeholders, in order.
func inlinePlainText(_ content: [[String: Any]]) -> String {
    var text = ""
    for node in content {
        if let string = node["text"] as? String {
            text += string
        } else if node["type"] as? String == "placeholder", let attrs = node["attrs"] as? [String: Any] {
            text += attrs["text"] as? String ?? ""
        }
    }
    return text
}

/// One text owner a test can name: its owner id (`RenderBlock.id`, a list
/// row's item id, or a caption's media id), its sentinel, what it is and
/// the containers around it, outermost first.
struct FixtureOwner {
    let id: String
    let token: String
    let role: String
    let chain: [String]

    /// The census class of §6.5 this owner falls in when it draws on
    /// TextKit 2 (or why it is out of PR 4's scope).
    var censusClass: String {
        if role == "code" { return chain.isEmpty ? "code (root)" : "code (nested)" }
        if role == "caption" { return chain.isEmpty ? "caption" : "caption (in \(chain.joined(separator: ">")))" }
        if chain.contains("table") { return "out of scope: table" }
        if chain.first == "list" { return "out of scope: inside a list item" }
        let isListText = role == "list-leader" || role == "task" || role == "decision"
        if chain.isEmpty { return isListText ? "list" : "root" }
        return isListText ? "container (nested list)" : "container"
    }

    var inClosedExpand: Bool {
        chain.contains { $0 == "expand" || $0 == "nestedExpand" }
    }
}

/// Every text owner of `document` that carries a sentinel, in document
/// order.
func fixtureOwners(_ document: [String: Any], prefixes: [String]) -> [FixtureOwner] {
    var owners: [FixtureOwner] = []
    func add(_ id: String, _ text: String, _ role: String, _ chain: [String]) {
        if let token = sentinelToken(in: text, prefixes: prefixes) {
            owners.append(FixtureOwner(id: id, token: token, role: role, chain: chain))
        }
    }
    func walk(_ nodes: [[String: Any]], parent: String, chain: [String]) {
        for (index, node) in nodes.enumerated() {
            visit(node, path: "\(parent).\(index)", chain: chain)
        }
    }
    func visit(_ node: [String: Any], path: String, chain: [String]) {
        let content = node["content"] as? [[String: Any]] ?? []
        let attrs = node["attrs"] as? [String: Any]
        switch node["type"] as? String {
        case "paragraph":
            add(path, inlinePlainText(content), "paragraph", chain)
        case "heading":
            add(path, inlinePlainText(content), "heading", chain)
        case "codeBlock":
            add(path, inlinePlainText(content), "code", chain)
        case "bulletList", "orderedList", "taskList", "decisionList":
            for (index, item) in content.enumerated() {
                let itemPath = "\(path).\(index)"
                let itemContent = item["content"] as? [[String: Any]] ?? []
                switch item["type"] as? String {
                case "listItem":
                    var rest = itemContent[...]
                    if let first = itemContent.first, first["type"] as? String == "paragraph" {
                        add(itemPath, inlinePlainText(first["content"] as? [[String: Any]] ?? []), "list-leader", chain)
                        rest = itemContent.dropFirst()
                    }
                    for childIndex in rest.indices {
                        visit(itemContent[childIndex], path: "\(itemPath).\(childIndex)", chain: chain + ["list"])
                    }
                case "taskItem":
                    add(itemPath, inlinePlainText(itemContent), "task", chain)
                case "decisionItem":
                    add(itemPath, inlinePlainText(itemContent), "decision", chain)
                default:
                    visit(item, path: itemPath, chain: chain)
                }
            }
        case "mediaSingle":
            if let mediaIndex = content.firstIndex(where: { $0["type"] as? String == "media" }),
               let caption = content.first(where: { $0["type"] as? String == "caption" }) {
                add("\(path).\(mediaIndex)", inlinePlainText(caption["content"] as? [[String: Any]] ?? []), "caption", chain)
            }
        case "panel":
            walk(content, parent: path, chain: chain + ["panel(\(attrs?["panelType"] as? String ?? "?"))"])
        case "blockquote":
            walk(content, parent: path, chain: chain + ["quote"])
        case "bodiedExtension":
            walk(content, parent: path, chain: chain + ["extension"])
        case "layoutSection":
            for (index, column) in content.enumerated() {
                let width = (column["attrs"] as? [String: Any])?["width"] as? Int ?? 0
                walk(column["content"] as? [[String: Any]] ?? [], parent: "\(path).\(index)",
                     chain: chain + ["column(\(width)%)"])
            }
        case "expand":
            walk(content, parent: path, chain: chain + ["expand"])
        case "nestedExpand":
            walk(content, parent: path, chain: chain + ["nestedExpand"])
        case "table":
            for (rowIndex, row) in content.enumerated() {
                for (cellIndex, cell) in (row["content"] as? [[String: Any]] ?? []).enumerated() {
                    walk(cell["content"] as? [[String: Any]] ?? [], parent: "\(path).\(rowIndex).\(cellIndex)",
                         chain: chain + ["table"])
                }
            }
        case "bodiedSyncBlock":
            walk(content, parent: path, chain: chain)
        default:
            break
        }
    }
    walk(document["content"] as? [[String: Any]] ?? [], parent: "0", chain: [])
    return owners
}

/// The `-scrollToFraction` value (4 decimals) that lands on prepared block
/// `index` of `count`: the demo lands on `Int(fraction × count)`.
func landingFraction(index: Int, count: Int) -> String {
    var tenThousandths = ((2 * index + 1) * 10_000) / (2 * count)
    while (tenThousandths * count) / 10_000 < index {
        tenThousandths += 1
    }
    precondition((tenThousandths * count) / 10_000 == index, "landingFraction: no 4-decimal fraction lands on \(index) of \(count)")
    let whole = tenThousandths / 10_000
    let fraction = String(tenThousandths % 10_000)
    return "\(whole)." + String(repeating: "0", count: 4 - fraction.count) + fraction
}

/// Markdown: the top-level landmark table (every root `rootFilter` keeps:
/// its node, its first prepared block, the fraction that lands on it and
/// its first sentinel) and the owner table (every sentinel owner
/// `ownerFilter` keeps).
func printLandmarks(
    fixture: String, document: [String: Any], prefixes: [String], summary: String,
    rootFilter: (Int, [String: Any]) -> Bool, ownerFilter: (FixtureOwner) -> Bool
) {
    let roots = document["content"] as? [[String: Any]] ?? []
    let prepared = preparedRootIDs(roots)
    let owners = fixtureOwners(document, prefixes: prefixes)
    print("## \(fixture)")
    print("")
    print(summary)
    print("")
    print("\(roots.count) top-level nodes, \(prepared.count) prepared top-level blocks"
        + " (`-scrollToFraction f` lands on prepared block `Int(f × \(prepared.count))`).")
    print("")
    print("| node | first prepared block (index) | fraction | type | landmark / first sentinel |")
    print("|---|---|---|---|---|")
    for (index, root) in roots.enumerated() where rootFilter(index, root) {
        let path = "0.\(index)"
        guard let preparedIndex = prepared.firstIndex(where: { $0 == path || $0.hasPrefix(path + "#") || $0.hasPrefix(path + ".") }) else {
            continue
        }
        var type = root["type"] as? String ?? "?"
        let attrs = root["attrs"] as? [String: Any]
        if type == "panel" { type += "(\(attrs?["panelType"] as? String ?? "?"))" }
        if type == "heading" { type += "(\(attrs?["level"] as? Int ?? 0))" }
        if type == "layoutSection" {
            let widths = (root["content"] as? [[String: Any]] ?? []).map { column in
                String((column["attrs"] as? [String: Any])?["width"] as? Int ?? 0)
            }
            type += "(\(widths.joined(separator: "/")))"
        }
        var landmark = owners.first { $0.id == path || $0.id.hasPrefix(path + ".") }?.token ?? ""
        if type == "expand" || type == "nestedExpand" {
            landmark = sentinelToken(in: attrs?["title"] as? String ?? "", prefixes: prefixes).map { "title " + $0 } ?? landmark
        }
        if landmark.isEmpty, type == "extension" || type == "bodiedExtension" {
            landmark = sentinelToken(in: attrs?["text"] as? String ?? "", prefixes: prefixes).map { "title " + $0 } ?? ""
        }
        let block = prepared[preparedIndex]
        let fraction = landingFraction(index: preparedIndex, count: prepared.count)
        print("| \(path) | `\(block)` (\(preparedIndex)) | \(fraction) | \(type) | \(landmark.isEmpty ? "(no text)" : "`\(landmark)`") |")
    }
    let kept = owners.filter(ownerFilter)
    guard !kept.isEmpty else {
        print("")
        return
    }
    print("")
    print("Owners (\(kept.count) of \(owners.count) sentinel owners): the id a `tk2-row:<id>` label carries,"
        + " the census class of §6.5, and whether a closed expand hides it at launch.")
    print("")
    print("| owner id | sentinel | role | containers (outermost first) | class | in a closed expand |")
    print("|---|---|---|---|---|---|")
    for owner in kept {
        let chain = owner.chain.isEmpty ? "—" : owner.chain.joined(separator: " > ")
        print("| `\(owner.id)` | `\(owner.token)` | \(owner.role) | \(chain) | \(owner.censusClass) | \(owner.inClosedExpand ? "yes" : "no") |")
    }
    print("")
}

// MARK: - Fixture 14: containers-parity.json

enum ContainersParitySpec {
    /// The sentinel prefix: every owner's text carries a unique `KP-…`
    /// token (code carries it on its first line).
    static let prefix = "KP-"
    /// Nested code inside the admitted cohort: printable ASCII and line
    /// feeds, no blank line, no trailing space or newline, declared under
    /// the canvas budget; wide enough to pan in any container.
    static let codeColumns = 100
    static let codeLines = 6
    /// KP-CODE-OVER: over the canvas budget at 3x and at 2x.
    static let overBudgetColumns = 120
}

/// Hand-authored (the RNG only draws code lines). Top-level node index →
/// node; block ids are `0.<index>` (the bodied sync block at 43 is
/// transparent: its paragraph is block `0.43.0`; the table at 81 prepares
/// to `0.81#header` and `0.81#rows0`). Every heading `KP-S<n>` is a
/// section landmark, and every section ends with a root paragraph
/// `KP-AFTER-…` that follows its last container, so a height error shows
/// below it. Append new cases just before the `KP-S11` tail, never reorder.
///
///   0 heading KP-S1 Panels      1–6 panel info/note/tip/warning/error/success,
///                               7 custom (emoji icon, colour), 8 custom (no colour),
///                               9 KP-PANEL-EMPTY-BEFORE, 10 empty panel,
///                               11 multi-block panel (h2, p, p, h5, p), 12 panel with only an h1,
///                               13 KP-AFTER-PANELS
///  14 heading KP-S2 Text shapes 15 panel: marks (sub/sup beside a second paragraph),
///                               16 panel: link, 17 panel: hard breaks, 18 panel: whitespace-only URL,
///                               19 quote: Unicode, 20 quote: Hebrew + mixed direction,
///                               21 panel: Arabic, 22 extension body: marks/link/breaks,
///                               23 panel: atoms (SwiftUI), 24 quote: atoms (SwiftUI),
///                               25 KP-AFTER-SHAPES
///  26 heading KP-S3 Quotes      27 one paragraph, 28 p/h3/p, 29 three nested quote levels,
///                               30 KP-AFTER-QUOTES
///  31 heading KP-S4 Nested      32 panel in quote, 33 quote in panel, 34 panel in extension,
///                               35 quote in extension, 36 quote > panel > quote,
///                               37 KP-AFTER-NESTED
///  38 heading KP-S5 Extensions  39 bodied (p/h4/p), 40 bodiless extension,
///                               41 bodied with an empty body, 42 reference-only sync block,
///                               43 bodied sync block (transparent: block 0.43.0),
///                               44 KP-AFTER-EXTENSIONS
///  45 heading KP-S6 Columns     46 25/75, 47 33/67, 48 50/50 holding a panel and a quote,
///                               49 33/33/33, 50 KP-AFTER-COLUMNS
///  51 heading KP-S7 Column edge cases
///                               52 0/100 (paragraph + code in the 0 % column),
///                               53 −25/100, 54 25/75 with a level-6 indented paragraph,
///                               55 0/−10 (positive control: equal columns),
///                               56 KP-AFTER-COLUMN-EDGES
///  57 heading KP-S8 Expands     58 expand with a nested expand, 59 expand holding a panel
///                               and a quote, 60 50/50 with a nested expand in a column,
///                               61 KP-AFTER-EXPANDS
///  62 heading KP-S9 Lists       63 list in a panel, 64 quote: ordered, rule-A row
///                               (a panel in an item), task list, 65 quote: RTL list,
///                               66 expand: bullet/task/decision, 67 extension: ordered + nested,
///                               68 25/75: three-deep list in the 25 % column,
///                               69 KP-AFTER-LISTS
///  70 heading KP-S10 Code       71 panel, 72 quote, 73 panel > quote, 74 expand,
///                               75 extension, 76 50/50 (code in both columns),
///                               77 panel with three code blocks, 78 panel with KP-CODE-OVER,
///                               79 KP-AFTER-CODE
///  80 heading KP-S11 Negative scope (the final landmark: nothing parks below it)
///                               81 table (a panel, a paragraph and code in cells),
///                               82 expand holding a table, 83 panel holding a plugin
///                               block (a YouTube embed the demo claims), 84 root bullet
///                               list whose item holds a panel and a quote
///  85 paragraph KP-END
///
/// No captioned media (a percentage-width media row is the media
/// livelock's shape). Tables and the plugin block come last, after the
/// final landmark heading: their assertions are hosted tests.
func makeContainersParity() -> [String: Any] {
    var rng = LCG(seed: 0x5EED_4A01)
    var blocks: [[String: Any]] = []
    let linkBase = "https://example.com/containers-parity/"

    func p(_ text: String) -> [String: Any] { paragraph([textNode(text)]) }
    func h(_ level: Int, _ text: String) -> [String: Any] { headingNode(level: level, text) }
    func li(_ content: [String: Any]...) -> [String: Any] { listItemNode(content) }
    func ul(_ items: [String: Any]...) -> [String: Any] { bulletListNode(items) }
    func ol(_ order: Int?, _ items: [String: Any]...) -> [String: Any] { orderedListNode(order: order, items) }
    func link(_ text: String, _ href: String) -> [String: Any] { textNode(text, marks: [linkMark(href)]) }
    func col(_ width: Int, _ content: [String: Any]...) -> [String: Any] { layoutColumnNode(width: width, content) }
    func section(_ title: String) { blocks.append(h(2, title)) }

    /// Nested code in the admitted cohort, `// <label> <note>` first.
    func code(_ label: String, _ note: String, lines: Int = ContainersParitySpec.codeLines,
              columns: Int = ContainersParitySpec.codeColumns) -> [String: Any] {
        let text = generatedCodeBlock(&rng, header: "// \(label) \(note)", lineCount: lines, columns: columns, minColumns: 24)
        let shape = codeTextShape(text)
        precondition(shape.isPrintableASCIIAndLF && shape.trailingNewlineCount == 0,
                     "containers-parity \(label): code must be printable ASCII and line feeds, no trailing newline")
        precondition(!text.components(separatedBy: "\n").contains { $0.isEmpty || $0.hasSuffix(" ") },
                     "containers-parity \(label): no blank line and no trailing space")
        precondition(codeBudgetVerdict(lineCount: shape.lineCount, maxColumns: shape.maxLineUTF16) == .under
                         && codeBudgetVerdict(lineCount: shape.lineCount, maxColumns: shape.maxLineUTF16, scale: 2) == .under,
                     "containers-parity \(label): must be declared under the canvas budget at 3x and 2x")
        return codeBlockNode(language: "swift", text: text)
    }

    let marked: [[String: Any]] = [
        textNode("KP-MARKS-PANEL "),
        textNode("strong", marks: [["type": "strong"]]),
        textNode(" "),
        textNode("emphasis", marks: [["type": "em"]]),
        textNode(" "),
        textNode("inline code", marks: [["type": "code"]]),
        textNode(" "),
        textNode("struck", marks: [["type": "strike"]]),
        textNode(" "),
        textNode("underlined", marks: [["type": "underline"]]),
        textNode(" "),
        textNode("red text", marks: [["type": "textColor", "attrs": ["color": "#ff5630"]]]),
        textNode(" "),
        textNode("highlighted", marks: [["type": "backgroundColor", "attrs": ["color": "#fffae6"]]]),
        textNode(" H"),
        textNode("2", marks: [["type": "subsup", "attrs": ["type": "sub"]]]),
        textNode("O and x"),
        textNode("2", marks: [["type": "subsup", "attrs": ["type": "sup"]]]),
    ]

    // KP-S1: every panel palette, an empty panel and multi-block panels.
    section("KP-S1 Panels: every palette, empty and multi-block")
    for (panelType, label, article) in [
        ("info", "INFO", "an"), ("note", "NOTE", "a"), ("tip", "TIP", "a"),
        ("warning", "WARNING", "a"), ("error", "ERROR", "an"), ("success", "SUCCESS", "a"),
    ] {
        blocks.append(panelNode(panelType, [p("KP-PANEL-\(label) a plain paragraph in \(article) \(panelType) panel")]))
    }
    blocks.append(panelNode("custom", [
        p("KP-PANEL-CUSTOM a plain paragraph in a custom panel with an emoji icon and its own colour"),
    ], icon: ":rocket:", color: "#6554c0"))
    blocks.append(panelNode("custom", [
        p("KP-PANEL-CUSTOM-GREY a custom panel without a colour draws in grey"),
    ], icon: ":star:"))
    blocks.append(p("KP-PANEL-EMPTY-BEFORE the next panel has no content"))
    blocks.append(panelNode("info", []))
    blocks.append(panelNode("note", [
        h(2, "KP-PANEL-MULTI-H2 a heading inside a panel"),
        p("KP-PANEL-MULTI-P1 the first paragraph of a multi-block panel, long enough to wrap across "
            + "several lines at phone width, so the icon must stay on the first baseline"),
        p("KP-PANEL-MULTI-P2 a second paragraph"),
        h(5, "KP-PANEL-MULTI-H5 a small heading"),
        p("KP-PANEL-MULTI-P3 the last paragraph of the panel"),
    ]))
    blocks.append(panelNode("tip", [h(1, "KP-PANEL-H1 a level-one heading alone in a panel")]))
    blocks.append(p("KP-AFTER-PANELS a root paragraph after the panels"))

    // KP-S2: marks, links, hard breaks, Unicode, right-to-left text, atoms.
    section("KP-S2 Text shapes inside containers")
    blocks.append(panelNode("info", [
        paragraph(marked),
        p("KP-MARKS-PANEL-NEXT a plain paragraph after the marked one"),
    ]))
    blocks.append(panelNode("tip", [paragraph([
        textNode("KP-LINK-PANEL see "),
        link("the linked docs", linkBase + "link-panel"),
        textNode(" for details"),
    ])]))
    blocks.append(panelNode("warning", [paragraph([
        textNode("KP-BREAK-PANEL first line"),
        hardBreakNode(),
        textNode("second line after a hard break"),
        hardBreakNode(),
        textNode("third line"),
    ])]))
    blocks.append(panelNode("note", [paragraph([
        textNode("KP-LINK-BLANK-PANEL a link whose URL is whitespace only: "),
        link("blank target", "   "),
    ])]))
    blocks.append(quoteNode([paragraph([
        textNode("KP-UNICODE-QUOTE café naïve Zoë 日本語 中文 한국어 👩🏽‍💻 🇯🇵 e\u{0301} ✅ ❤️ "),
        ["type": "emoji", "attrs": ["shortName": ":rocket:", "id": "1f680", "text": "🚀"]],
        textNode(" text emoji"),
    ])]))
    blocks.append(quoteNode([
        p("שלום עולם — פסקה מימין לשמאל KP-RTL-QUOTE"),
        p("KP-RTL-MIXED-QUOTE left-to-right text with עברית: שלום עולם and العربية: مرحبا بالعالم"),
    ]))
    blocks.append(panelNode("success", [p("مرحبا بالعالم — فقرة من اليمين إلى اليسار KP-RTL-PANEL")]))
    blocks.append(bodiedExtensionNode(key: "excerpt", title: "KP-EXT-SHAPES excerpt macro", localId: "kp-ext-shapes", [
        paragraph([
            textNode("KP-MARKS-EXT "),
            textNode("bold", marks: [["type": "strong"]]),
            textNode(" and "),
            textNode("italic", marks: [["type": "em"]]),
            textNode(" in an extension body"),
        ]),
        paragraph([
            textNode("KP-LINK-EXT open "),
            link("the extension link", linkBase + "link-ext"),
        ]),
        paragraph([
            textNode("KP-BREAK-EXT before the break"),
            hardBreakNode(),
            textNode("after the break"),
        ]),
    ]))
    blocks.append(panelNode("error", [paragraph([
        textNode("KP-ATOM-PANEL ping "),
        mentionNode(id: "kp-user-1", text: "@KP Reviewer"),
        textNode(" today, state "),
        statusNode("BLOCKED", color: "red", localId: "kp-status-1"),
    ])]))
    blocks.append(quoteNode([paragraph([
        textNode("KP-ATOM-QUOTE due "),
        date(400),
        textNode(" with a custom emoji "),
        emojiAtomNode(shortName: ":kp-custom:"),
    ])]))
    blocks.append(p("KP-AFTER-SHAPES a root paragraph after the text shapes"))

    // KP-S3: quotes.
    section("KP-S3 Quotes")
    blocks.append(quoteNode([
        p("KP-QUOTE-ONE a single-paragraph quote that wraps across several lines at phone width, "
            + "so the bar must run the full height of the text"),
    ]))
    blocks.append(quoteNode([
        p("KP-QUOTE-MULTI-P1 the first paragraph of a quote"),
        h(3, "KP-QUOTE-MULTI-H3 a heading inside a quote"),
        p("KP-QUOTE-MULTI-P2 the paragraph after the heading"),
    ]))
    blocks.append(quoteNode([
        p("KP-QUOTE-OUTER the outer quote"),
        quoteNode([
            p("KP-QUOTE-INNER a quote inside a quote"),
            quoteNode([p("KP-QUOTE-INNERMOST a third quote level")]),
        ]),
        p("KP-QUOTE-OUTER-AFTER back in the outer quote"),
    ]))
    blocks.append(p("KP-AFTER-QUOTES a root paragraph after the quotes"))

    // KP-S4: containers inside containers.
    section("KP-S4 Nested containers")
    blocks.append(quoteNode([
        p("KP-NEST-QP-OUTER a quote holding a panel"),
        panelNode("info", [p("KP-NEST-QP-INNER a panel inside a quote")]),
    ]))
    blocks.append(panelNode("note", [
        p("KP-NEST-PQ-OUTER a panel holding a quote"),
        quoteNode([p("KP-NEST-PQ-INNER a quote inside a panel")]),
    ]))
    blocks.append(bodiedExtensionNode(key: "excerpt", title: "KP-NEST-EXT-PANEL extension holding a panel", localId: "kp-nest-ep", [
        p("KP-NEST-EP-OUTER an extension body holding a panel"),
        panelNode("tip", [p("KP-NEST-EP-INNER a panel inside an extension body")]),
    ]))
    blocks.append(bodiedExtensionNode(key: "excerpt", title: "KP-NEST-EXT-QUOTE extension holding a quote", localId: "kp-nest-eq", [
        quoteNode([p("KP-NEST-EQ-INNER a quote inside an extension body")]),
    ]))
    blocks.append(quoteNode([
        panelNode("warning", [quoteNode([p("KP-NEST-DEEP a quote inside a panel inside a quote")])]),
    ]))
    blocks.append(p("KP-AFTER-NESTED a root paragraph after the nested containers"))

    // KP-S5: extension bodies; bodiless and reference-only placeholders
    // add no text.
    section("KP-S5 Extension bodies")
    blocks.append(bodiedExtensionNode(key: "excerpt", title: "KP-EXT-BODY excerpt macro with a body", localId: "kp-ext-body", [
        p("KP-EXT-P1 the first paragraph of an extension body"),
        h(4, "KP-EXT-H4 a heading in an extension body"),
        p("KP-EXT-P2 the last paragraph of the extension body"),
    ]))
    blocks.append(extensionNode(key: "toc", title: "KP-EXT-BODYLESS table of contents macro (no body)", localId: "kp-ext-bodyless"))
    blocks.append(bodiedExtensionNode(key: "details", title: "KP-EXT-EMPTY bodied macro with an empty body", localId: "kp-ext-empty", []))
    blocks.append(syncBlockNode(resourceId: "ari:cloud:confluence:site/kp-sync-ref", localId: "kp-sync-ref"))
    blocks.append(bodiedSyncBlockNode(resourceId: "ari:cloud:confluence:site/kp-sync-body", localId: "kp-sync-body", [
        p("KP-SYNC-BODY a paragraph in a bodied sync block, prepared in place as a root paragraph"),
    ]))
    blocks.append(p("KP-AFTER-EXTENSIONS a root paragraph after the extensions"))

    // KP-S6: layout columns (stacked on a phone, side by side on a
    // regular-width host).
    section("KP-S6 Layout columns")
    blocks.append(layoutSectionNode([
        col(25,
            p("KP-COL25-A short text in the 25 % column"),
            p("KP-COL25-B a second paragraph")),
        col(75,
            p("KP-COL75-A longer text in the 75 % column, enough to wrap at least once beside the narrow one"),
            h(4, "KP-COL75-H4 a heading in a column"),
            p("KP-COL75-B the last paragraph of the wide column")),
    ]))
    blocks.append(layoutSectionNode([
        col(33, p("KP-COL33-A text in the 33 % column")),
        col(67,
            p("KP-COL67-A text in the 67 % column that wraps beside the narrower one"),
            paragraph([textNode("KP-LINK-COL67 a "), link("link in a column", linkBase + "link-col67")])),
    ]))
    blocks.append(layoutSectionNode([
        col(50, panelNode("info", [p("KP-COL50-PANEL a panel in a column")])),
        col(50, quoteNode([p("KP-COL50-QUOTE a quote in a column")])),
    ]))
    blocks.append(layoutSectionNode([
        col(33, p("KP-COL3-A the first of three columns")),
        col(33, p("KP-COL3-B the second of three columns")),
        col(33, p("KP-COL3-C the third of three columns")),
    ]))
    blocks.append(p("KP-AFTER-COLUMNS a root paragraph after the columns"))

    // KP-S7: the negative-scope column cases and the positive control.
    section("KP-S7 Column edge cases: zero, negative, indented, all non-positive")
    blocks.append(layoutSectionNode([
        col(0,
            p("KP-COL0-ZERO a paragraph in a zero-percent column"),
            code("KP-CODE-COL0", "code in a zero-percent column", lines: 4, columns: 60)),
        col(100, p("KP-COL0-POSITIVE a paragraph beside a zero-percent column")),
    ]))
    blocks.append(layoutSectionNode([
        col(-25, p("KP-COLNEG-NEGATIVE a paragraph in a negative-percent column")),
        col(100, p("KP-COLNEG-POSITIVE a paragraph beside a negative-percent column")),
    ]))
    blocks.append(layoutSectionNode([
        col(25, indentedParagraphNode(level: 6, [textNode("KP-INDENT6 a level-6 indented paragraph in the 25 % column")])),
        col(75, p("KP-INDENT6-BESIDE the 75 % column beside the indented paragraph")),
    ]))
    blocks.append(layoutSectionNode([
        col(0, p("KP-COLALL0-A all columns at or below zero percent lay out as equal columns")),
        col(-10, p("KP-COLALL0-B the second column of the positive control")),
    ]))
    blocks.append(p("KP-AFTER-COLUMN-EDGES a root paragraph after the column edge cases"))

    // KP-S8: expands, closed in the bytes (tests open them).
    section("KP-S8 Expands, closed until a test opens them")
    blocks.append(expandNode("KP-EXPAND-OUTER outer expand", [
        p("KP-EXPAND-P1 the first paragraph of an expand body"),
        h(3, "KP-EXPAND-H3 a heading in an expand body"),
        paragraph([
            textNode("KP-EXPAND-MARKS "),
            textNode("bold", marks: [["type": "strong"]]),
            textNode(" text and "),
            link("a link in an expand", linkBase + "link-expand"),
        ]),
        nestedExpandNode("KP-EXPAND-NESTED nested expand", [
            p("KP-EXPAND-NESTED-P1 the first paragraph of a nested expand body"),
            p("KP-EXPAND-NESTED-P2 the second paragraph of the nested body"),
        ]),
        p("KP-EXPAND-P2 a paragraph after the nested expand"),
    ]))
    blocks.append(expandNode("KP-EXPAND-CONTAINERS expand holding a panel and a quote", [
        panelNode("success", [p("KP-EXPAND-PANEL a panel in an expand body")]),
        quoteNode([p("KP-EXPAND-QUOTE a quote in an expand body")]),
    ]))
    blocks.append(layoutSectionNode([
        col(50,
            p("KP-COL-EXPAND-A a paragraph above a nested expand in a column"),
            nestedExpandNode("KP-COL-NESTED-EXPAND nested expand in a column", [
                p("KP-COL-NESTED-EXPAND-P the body of the nested expand in a column"),
            ])),
        col(50, p("KP-COL-EXPAND-B the column beside the nested expand")),
    ]))
    blocks.append(p("KP-AFTER-EXPANDS a root paragraph after the expands"))

    // KP-S9: lists inside every container, a row rule A rejects (it holds
    // a panel), a task list and a right-to-left list.
    section("KP-S9 Lists inside containers")
    blocks.append(panelNode("info", [
        p("KP-LIST-PANEL-INTRO a list inside a panel"),
        ul(
            li(p("KP-LIST-PANEL-A the first bullet"), ol(nil, li(p("KP-LIST-PANEL-A1 a nested ordered item")))),
            li(p("KP-LIST-PANEL-B the second bullet"))
        ),
    ]))
    blocks.append(quoteNode([
        ol(3, li(p("KP-LIST-QUOTE-3 an ordered list starting at three")), li(p("KP-LIST-QUOTE-4 the next item"))),
        ul(
            li(p("KP-LIST-QUOTE-REJECT-A a row that holds a panel, which rule A keeps on SwiftUI"),
               panelNode("note", [p("KP-LIST-QUOTE-REJECT-PANEL a panel inside a list item inside a quote")])),
            li(p("KP-LIST-QUOTE-AFTER-REJECT the row after it"))
        ),
        taskListNode("kp-quote-tasks", [
            taskItemNode("kp-quote-task-a", done: false, [textNode("KP-LIST-QUOTE-TASK-A an open task in a quote")]),
            taskItemNode("kp-quote-task-b", done: true, [textNode("KP-LIST-QUOTE-TASK-B a done task in a quote")]),
        ]),
    ]))
    blocks.append(quoteNode([
        ul(
            li(p("שלום עולם — פריט ברשימה KP-LIST-RTL-A")),
            li(p("مرحبا بالعالم — عنصر في القائمة KP-LIST-RTL-B"))
        ),
    ]))
    blocks.append(expandNode("KP-LIST-EXPAND lists inside an expand", [
        ul(li(p("KP-LIST-EXPAND-A the first bullet in an expand")), li(p("KP-LIST-EXPAND-B the second bullet"))),
        taskListNode("kp-expand-tasks", [
            taskItemNode("kp-expand-task-a", done: false, [textNode("KP-LIST-EXPAND-TASK an open task in an expand")]),
        ]),
        decisionListNode("kp-expand-decisions", [
            decisionItemNode("kp-expand-decision-a", [textNode("KP-LIST-EXPAND-DECISION a decision in an expand")]),
        ]),
    ]))
    blocks.append(bodiedExtensionNode(key: "excerpt", title: "KP-LIST-EXT lists inside an extension body", localId: "kp-list-ext", [
        ol(nil,
           li(p("KP-LIST-EXT-1 the first ordered item")),
           li(p("KP-LIST-EXT-2 the second ordered item"), ul(li(p("KP-LIST-EXT-2A a nested bullet"))))),
    ]))
    blocks.append(layoutSectionNode([
        col(25, ul(li(
            p("KP-LIST-COL25-L1 a bullet in the 25 % column"),
            ul(li(
                p("KP-LIST-COL25-L2 one level deeper"),
                ul(li(p("KP-LIST-COL25-L3 the deepest row in the narrow column")))
            ))
        ))),
        col(75,
            ol(nil, li(p("KP-LIST-COL75-1 an ordered item in the 75 % column")), li(p("KP-LIST-COL75-2 the next item"))),
            decisionListNode("kp-col-decisions", [
                decisionItemNode("kp-col-decision-a", [textNode("KP-LIST-COL75-DECISION a decision in a column")]),
            ])),
    ]))
    blocks.append(p("KP-AFTER-LISTS a root paragraph after the lists"))

    // KP-S10: code inside containers, all in PR 3's admitted cohort but
    // one, KP-CODE-OVER, over the canvas budget.
    section("KP-S10 Code inside containers")
    blocks.append(panelNode("info", [
        p("KP-CODE-PANEL-INTRO a code block inside a panel"),
        code("KP-CODE-PANEL", "code inside a panel"),
    ]))
    blocks.append(quoteNode([code("KP-CODE-QUOTE", "code inside a quote")]))
    blocks.append(panelNode("note", [quoteNode([code("KP-CODE-PANEL-QUOTE", "code inside a quote inside a panel")])]))
    blocks.append(expandNode("KP-CODE-EXPAND code inside an expand", [
        p("KP-CODE-EXPAND-P a paragraph above the code in an expand body"),
        code("KP-CODE-EXPAND-BODY", "code inside an expand body"),
    ]))
    blocks.append(bodiedExtensionNode(key: "excerpt", title: "KP-CODE-EXT code inside an extension body", localId: "kp-code-ext", [
        code("KP-CODE-EXT-BODY", "code inside an extension body"),
    ]))
    blocks.append(layoutSectionNode([
        col(50, code("KP-CODE-COL-LEFT", "code in the left column", columns: 90)),
        col(50,
            p("KP-CODE-COL-RIGHT-P a paragraph above code in the right column"),
            code("KP-CODE-COL-RIGHT", "code in the right column", columns: 90)),
    ]))
    blocks.append(panelNode("tip", [
        code("KP-CODE-MULTI-1", "first of three code blocks in one panel", lines: 4),
        p("KP-CODE-MULTI-P a paragraph between code blocks"),
        code("KP-CODE-MULTI-2", "second code block", lines: 5),
        code("KP-CODE-MULTI-3", "third code block", lines: 3),
    ]))
    let overColumns = ContainersParitySpec.overBudgetColumns
    let overLines = max(
        smallestLineCountOverBudget(columns: overColumns, scale: CodeCanvasModel.displayScale),
        smallestLineCountOverBudget(columns: overColumns, scale: 2)
    )
    let overText = generatedCodeBlock(
        &rng, header: "// KP-CODE-OVER over the canvas budget at 3x and 2x: \(overLines) lines x \(overColumns) columns",
        lineCount: overLines, columns: overColumns, minColumns: 40
    )
    let overShape = codeTextShape(overText)
    precondition(overShape.isPrintableASCIIAndLF
                     && codeBudgetVerdict(lineCount: overShape.lineCount, maxColumns: overShape.maxLineUTF16) == .over
                     && codeBudgetVerdict(lineCount: overShape.lineCount, maxColumns: overShape.maxLineUTF16, scale: 2) == .over,
                 "containers-parity KP-CODE-OVER must be ASCII and over budget at 3x and 2x")
    blocks.append(panelNode("warning", [
        p("KP-CODE-OVER-INTRO the next code block is over the canvas budget"),
        codeBlockNode(language: "swift", text: overText),
    ]))
    blocks.append(p("KP-AFTER-CODE a root paragraph after the code"))

    // KP-S11: the negative-scope tail. Nothing parks below this heading.
    section("KP-S11 Negative scope: tables, a plugin block and containers in a list item")
    blocks.append(tableNode(
        header: [[p("KP-NEG-TH-1 header cell")], [p("KP-NEG-TH-2 header cell")]],
        rows: [[
            [panelNode("info", [p("KP-NEG-TABLE-PANEL a panel in a table cell")])],
            [p("KP-NEG-TABLE-TD a paragraph in a table cell"),
             code("KP-NEG-TABLE-CODE", "code in a table cell", lines: 3, columns: 48)],
        ]]
    ))
    blocks.append(expandNode("KP-NEG-EXPAND-TABLE a table inside an expand", [
        p("KP-NEG-EXPAND-P a paragraph above the table"),
        tableNode(header: [[p("KP-NEG-EXPAND-TH header cell")]], rows: [[[p("KP-NEG-EXPAND-TD body cell")]]]),
    ]))
    blocks.append(panelNode("info", [
        p("KP-NEG-PLUGIN-P a paragraph beside a plugin block in a panel"),
        embedCardNode(url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
    ]))
    blocks.append(ul(li(
        p("KP-NEG-LISTITEM-LEADER a root list item holding containers"),
        panelNode("note", [p("KP-NEG-LISTITEM-PANEL a panel inside a root list item")]),
        quoteNode([p("KP-NEG-LISTITEM-QUOTE a quote inside a root list item")])
    )))
    blocks.append(p("KP-END end of the containers parity fixture"))
    return doc(blocks)
}

// MARK: - Fixture 15: containers-dense.json

enum ContainersDenseKind: String {
    case panel
    case quote
    case extensionBody = "extension"
    case columns
}

/// The composition of containers-dense, declared in constants before any
/// timing of the fixture exists (plan §7.2; its percentages are a
/// proposal, not a measurement, `[UNSURE 1]`). Every share below is exact
/// by construction: quotas are dealt per group of 20 containers or per
/// run of 20 leaves and shuffled on the fixture's own seeds.
///
///   - Containers by `index % 20` (`kinds`): panel 30 %, quote 25 %,
///     layout columns 25 %, extension body 20 %. A closed expand follows
///     container 9 of every group (one per 21 roots, 4.8 %); its body is
///     never opened and never counted.
///   - Text leaves per container (`leafQuotas`, version 1): 1 (40 %),
///     2–3 (40 %), 4–8 (20 %), uniform inside a bucket.
///   - Of all container leaves, per run of 20 (`listLeadersPerRun`,
///     `classQuotas`): 15 % nested-list leaders, the rest prose; and
///     independently 65 % plain, 20 % marked, 10 % linked (TextKit
///     1-backed), 5 % atom-bearing (the declared SwiftUI fallback share).
///   - Bounded nesting: a container of 3 or more leaves whose index is
///     1 mod 4 holds its last 2 leaves in one nested panel (a quote, inside
///     a panel); never deeper. A container of 4 or more leaves opens with a
///     heading (h3–h6) when its first leaf is plain or marked prose.
///   - `nestedCodeCount` nested code blocks in every version, evenly
///     spaced, all in PR 3's admitted cohort and under the canvas budget.
///   - No table, no media, no captions.
///   - The first and the last `pinnedContainers` containers (a panel, a
///     quote and an extension body; a quote, a panel and a quote) open
///     with a plain prose leaf, so native container text is on the first
///     and the last screen.
///   - Every container's first leaf starts with its `KD-<iiii>` label.
enum ContainersDenseSpec {
    /// THE LIGHTEN LADDER: which version is emitted. 1 (the default) is the
    /// composition above. 2 and 3 are the two fixed lighter versions of
    /// `containersDenseShapes`, declared here before any timing of the
    /// fixture exists. There is no version 4, and no other parameter of
    /// this fixture may change once a timing has been seen.
    static let version = 1
    static let groupSize = 20
    /// Groups per version (20 containers and one closed expand each). Sizing
    /// only, not lightening: a lighter version needs more groups to keep
    /// its estimated autoscroll in `secondsBand`; the generator checks
    /// every version against the band on every run.
    static let groupCounts: [Int: Int] = [1: 40, 2: 52, 3: 60]
    static let kinds: [ContainersDenseKind] = [
        .panel, .quote, .extensionBody, .columns, .panel, .quote, .columns, .extensionBody, .panel, .columns,
        .quote, .panel, .columns, .extensionBody, .panel, .columns, .extensionBody, .quote, .panel, .quote,
    ]
    /// The group's closed expand follows its container with this offset.
    static let expandAfter = 9
    static let leafBuckets: [ClosedRange<Int>] = [1 ... 1, 2 ... 3, 4 ... 8]
    /// Containers per bucket in every group of 20 (version 1).
    static let leafQuotas = [8, 8, 4]
    static let roleRun = 20
    static let listLeadersPerRun = 3
    static let classQuotas: [(name: String, count: Int)] = [("plain", 13), ("marked", 4), ("linked", 2), ("atom", 1)]
    static let nestedCodeCount = 12
    static let nestEvery = 4
    static let nestedLeaves = 2
    static let pinnedContainers = 3
    /// Column widths by columns-container ordinal % 5.
    static let columnSplits: [[Int]] = [[50, 50], [33, 67], [25, 75], [67, 33], [33, 33, 33]]
    static let panelTypes = ["info", "note", "tip", "warning", "error", "success", "custom"]
    /// Words in a prose leaf and in a list leader (plain text; the marked,
    /// linked and atom shapes are three short runs).
    static let proseWords = 8 ..< 25
    static let leaderWords = 3 ..< 9
    /// The estimated autoscroll (1,200 pt/s) every version must land in.
    static let secondsBand = 100 ... 150
}

struct ContainersDenseShape {
    let kind: ContainersDenseKind
    var bucket: Int
    var leaves: Int
}

/// What containers-dense emitted, counted while emitting; printed by the
/// emit step.
struct ContainersDenseSummary {
    var version = 1
    var containers = 0
    var expands = 0
    var kinds: [String: Int] = [:]
    var buckets = [0, 0, 0]
    var leaves = 0
    var listLeaders = 0
    var classes: [String: Int] = [:]
    var headings = 0
    var nestedContainers = 0
    var lists: [String: Int] = [:]
    var code = 0
    var codeCanvas: [String] = []
    /// The ladder: containers moved from 4–8 leaves to 2–3 (versions 2
    /// and 3), and from 2–3 to 1 (version 3).
    var lightenedToTwoOrThree = 0
    var lightenedToOne = 0
    var estimatedPoints = 0.0
    var roots = 0
    var bytes = 0
}

/// Fisher–Yates on `rng`.
func shuffleInPlace<T>(_ values: inout [T], _ rng: inout LCG) {
    var i = values.count - 1
    while i > 0 {
        let j = rng.int(0 ..< i + 1)
        values.swapAt(i, j)
        i -= 1
    }
}

/// Pass 1: every container's kind, bucket and leaf count, drawn group by
/// group on the shape seed (so a version with more groups shares the first
/// groups' draws), then THE LIGHTEN LADDER, with no new draw:
///
///   - version 2: every 4–8-leaf container becomes a 2–3-leaf one,
///     `2 + (leaves − 4) % 2` (shares 40 / 60 / 0);
///   - version 3: version 2, then in each group every third 2–3-leaf
///     container in index order (ranks 2, 5, 8, 11) becomes a 1-leaf one
///     (shares 60 / 40 / 0).
///
/// The list-leader, class and nested-code shares are the same in every
/// version (they are dealt over the leaves the version has).
func containersDenseShapes(version: Int, summary: inout ContainersDenseSummary) -> [ContainersDenseShape] {
    precondition((1 ... 3).contains(version), "containers-dense: ContainersDenseSpec.version must be 1, 2 or 3")
    precondition(ContainersDenseSpec.kinds.count == ContainersDenseSpec.groupSize
                     && ContainersDenseSpec.leafQuotas.reduce(0, +) == ContainersDenseSpec.groupSize,
                 "containers-dense: kinds and quotas must cover one group exactly")
    let groups = ContainersDenseSpec.groupCounts[version] ?? 0
    var rng = LCG(seed: 0x5EED_4D01)
    var shapes: [ContainersDenseShape] = []
    for _ in 0 ..< groups {
        var buckets: [Int] = []
        for (bucket, quota) in ContainersDenseSpec.leafQuotas.enumerated() {
            buckets += [Int](repeating: bucket, count: quota)
        }
        shuffleInPlace(&buckets, &rng)
        var group: [ContainersDenseShape] = []
        for (offset, bucket) in buckets.enumerated() {
            let range = ContainersDenseSpec.leafBuckets[bucket]
            let leaves = rng.int(range.lowerBound ..< range.upperBound + 1)
            group.append(ContainersDenseShape(kind: ContainersDenseSpec.kinds[offset], bucket: bucket, leaves: leaves))
        }
        if version >= 2 {
            for i in group.indices where group[i].bucket == 2 {
                group[i].leaves = 2 + (group[i].leaves - 4) % 2
                group[i].bucket = 1
                summary.lightenedToTwoOrThree += 1
            }
        }
        if version == 3 {
            var rank = 0
            for i in group.indices where group[i].bucket == 1 {
                if rank % 3 == 2 {
                    group[i].leaves = 1
                    group[i].bucket = 0
                    summary.lightenedToOne += 1
                }
                rank += 1
            }
        }
        shapes += group
    }
    return shapes
}

struct ContainersDenseRole {
    var isListLeader: Bool
    var leafClass: String
}

/// Pass 2: each leaf's position (list leader or prose) and class, dealt
/// per run of 20 leaves from exact quotas. A pinned leaf is made plain
/// prose by swapping with the nearest unpinned leaf of its own run that
/// has what it needs (anywhere else only if its run has none), so the
/// document's totals stay exact.
func containersDenseRoles(count: Int, pinned: Set<Int>) -> [ContainersDenseRole] {
    var rng = LCG(seed: 0x5EED_4D02)
    let run = ContainersDenseSpec.roleRun
    var roles: [ContainersDenseRole] = []
    roles.reserveCapacity(count)
    while roles.count < count {
        var positions = [Bool](repeating: true, count: ContainersDenseSpec.listLeadersPerRun)
            + [Bool](repeating: false, count: run - ContainersDenseSpec.listLeadersPerRun)
        shuffleInPlace(&positions, &rng)
        var classes: [String] = []
        for quota in ContainersDenseSpec.classQuotas {
            classes += [String](repeating: quota.name, count: quota.count)
        }
        precondition(classes.count == run, "containers-dense: class quotas must add up to one run")
        shuffleInPlace(&classes, &rng)
        for k in 0 ..< run where roles.count < count {
            roles.append(ContainersDenseRole(isListLeader: positions[k], leafClass: classes[k]))
        }
    }
    func partner(of serial: Int, _ wanted: (ContainersDenseRole) -> Bool) -> Int? {
        let runStart = serial - serial % run
        let runEnd = min(runStart + run, count)
        let nearby = Array(runStart ..< runEnd).sorted { abs($0 - serial) < abs($1 - serial) }
        let everywhere = Array(0 ..< count).sorted { abs($0 - serial) < abs($1 - serial) }
        return (nearby + everywhere).first { $0 != serial && !pinned.contains($0) && wanted(roles[$0]) }
    }
    for serial in pinned.sorted() {
        if roles[serial].isListLeader, let other = partner(of: serial, { !$0.isListLeader }) {
            roles[other].isListLeader = true
            roles[serial].isListLeader = false
        }
        if roles[serial].leafClass != "plain", let other = partner(of: serial, { $0.leafClass == "plain" }) {
            roles[other].leafClass = roles[serial].leafClass
            roles[serial].leafClass = "plain"
        }
    }
    return roles
}

/// Pass 3: text and nodes, on the text seed. Returns the document.
func makeContainersDense(version: Int, summary: inout ContainersDenseSummary) -> [String: Any] {
    summary.version = version
    let shapes = containersDenseShapes(version: version, summary: &summary)
    let containerCount = shapes.count
    precondition(containerCount <= 10_000, "containers-dense: labels are 4 digits")
    var firstLeaf: [Int] = []
    var leafTotal = 0
    for shape in shapes {
        firstLeaf.append(leafTotal)
        leafTotal += shape.leaves
    }
    var pinned = Set<Int>()
    for c in 0 ..< ContainersDenseSpec.pinnedContainers {
        pinned.insert(firstLeaf[c])
        pinned.insert(firstLeaf[containerCount - 1 - c])
    }
    let roles = containersDenseRoles(count: leafTotal, pinned: pinned)
    var codeAt = Set<Int>()
    for k in 0 ..< ContainersDenseSpec.nestedCodeCount {
        codeAt.insert((k * containerCount) / ContainersDenseSpec.nestedCodeCount + 5)
    }
    precondition(codeAt.count == ContainersDenseSpec.nestedCodeCount, "containers-dense: code positions must be distinct")

    var rng = LCG(seed: 0x5EED_4D03)
    var panelOrdinal = 0
    var columnsOrdinal = 0
    var listOrdinal = 0
    var codeOrdinal = 0
    var blocks: [[String: Any]] = []

    func label(_ c: Int) -> String {
        let digits = String(c)
        return "KD-" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }

    /// A panel of the next palette in turn (every seventh is custom).
    func panel(_ content: [[String: Any]]) -> [String: Any] {
        let panelType = ContainersDenseSpec.panelTypes[panelOrdinal % ContainersDenseSpec.panelTypes.count]
        panelOrdinal += 1
        if panelType == "custom" {
            return panelNode(panelType, content, icon: ":rocket:", color: "#6554c0")
        }
        return panelNode(panelType, content)
    }

    func inline(_ role: ContainersDenseRole, serial: Int, label: String?, words: Range<Int>) -> [[String: Any]] {
        let lead = label.map { $0 + " " } ?? ""
        switch role.leafClass {
        case "marked":
            return [
                textNode(lead + sentence(&rng, wordCount: rng.int(2 ..< 6)) + " "),
                textNode(sentence(&rng, wordCount: rng.int(2 ..< 4)), marks: [listDenseMark(&rng)]),
                textNode(" " + sentence(&rng, wordCount: rng.int(2 ..< 6))),
            ]
        case "linked":
            return [
                textNode(lead + sentence(&rng, wordCount: rng.int(2 ..< 6)) + " "),
                textNode(sentence(&rng, wordCount: rng.int(2 ..< 4)),
                         marks: [linkMark("https://example.com/containers-dense/\(serial)")]),
                textNode(" " + sentence(&rng, wordCount: rng.int(2 ..< 6))),
            ]
        case "atom":
            let atom: [String: Any]
            switch serial % 4 {
            case 0: atom = mention(serial)
            case 1: atom = status(&rng, index: serial)
            case 2: atom = date(serial % 365)
            default: atom = emojiAtomNode(shortName: ":kd-custom-\(serial % 7):")
            }
            return [
                textNode(lead + sentence(&rng, wordCount: rng.int(2 ..< 6)) + " "),
                atom,
                textNode(" " + sentence(&rng, wordCount: rng.int(2 ..< 6))),
            ]
        default:
            var text = lead + sentence(&rng, wordCount: rng.int(words))
            if rng.oneIn(10) { text += " " + rng.pick(textEmoji) }
            if rng.oneIn(16) {
                return [textNode(text), hardBreakNode(), textNode(sentence(&rng, wordCount: rng.int(2 ..< 6)))]
            }
            return [textNode(text)]
        }
    }

    /// The blocks of leaves `serials`: consecutive list leaders form one
    /// list (bullet, ordered, task in turn; the third item of a bullet or
    /// ordered list nests under the second), prose leaves are paragraphs,
    /// and the first may be a heading.
    func leafBlocks(_ serials: Range<Int>, label: String?, headingLevel: Int?) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var items: [[[String: Any]]] = []
        var itemSerials: [Int] = []
        func flush() {
            guard !items.isEmpty else { return }
            let family = listOrdinal % 3
            listOrdinal += 1
            switch family {
            case 2:
                var tasks: [[String: Any]] = []
                for (k, item) in items.enumerated() {
                    tasks.append(taskItemNode("kd-task-\(itemSerials[k])", done: itemSerials[k] % 3 == 0, item))
                }
                out.append(taskListNode("kd-tasklist-\(listOrdinal)", tasks))
                summary.lists["taskList", default: 0] += 1
            default:
                let ordered = family == 1
                func make(_ list: [[String: Any]]) -> [String: Any] {
                    ordered ? orderedListNode(list) : bulletListNode(list)
                }
                var listItems: [[String: Any]] = []
                var k = 0
                while k < items.count {
                    var content: [[String: Any]] = [paragraph(items[k])]
                    if k == 1, items.count >= 3 {
                        content.append(make([listItemNode([paragraph(items[2])])]))
                        listItems.append(listItemNode(content))
                        k = 3
                        continue
                    }
                    listItems.append(listItemNode(content))
                    k += 1
                }
                out.append(make(listItems))
                summary.lists[ordered ? "orderedList" : "bulletList", default: 0] += 1
            }
            items.removeAll()
            itemSerials.removeAll()
        }
        for serial in serials {
            let role = roles[serial]
            let first = serial == serials.lowerBound
            summary.leaves += 1
            summary.classes[role.leafClass, default: 0] += 1
            if role.isListLeader {
                summary.listLeaders += 1
                items.append(inline(role, serial: serial, label: first ? label : nil, words: ContainersDenseSpec.leaderWords))
                itemSerials.append(serial)
                continue
            }
            flush()
            let content = inline(role, serial: serial, label: first ? label : nil, words: ContainersDenseSpec.proseWords)
            if first, let level = headingLevel, role.leafClass == "plain" || role.leafClass == "marked" {
                let attrs: [String: Any] = ["level": level]
                out.append(["type": "heading", "attrs": attrs, "content": content])
                summary.headings += 1
            } else {
                out.append(paragraph(content))
            }
        }
        flush()
        return out
    }

    func nestedCode() -> [String: Any] {
        let k = codeOrdinal
        codeOrdinal += 1
        let lineCount = 3 + k % 6
        let columns = 32 + (k * 7) % 25
        var lines = ["// KD-CODE-" + pad2(k) + " nested code"]
        var depth = 0
        while lines.count < lineCount {
            depth = max(0, min(2, depth + rng.int(0 ..< 3) - 1))
            lines.append(codeLine(&rng, columns: rng.int(16 ..< columns + 1), indent: 4 * depth))
        }
        let text = lines.joined(separator: "\n")
        let shape = codeTextShape(text)
        precondition(shape.isPrintableASCIIAndLF && shape.trailingNewlineCount == 0
                         && !lines.contains { $0.isEmpty || $0.hasSuffix(" ") }
                         && codeBudgetVerdict(lineCount: shape.lineCount, maxColumns: shape.maxLineUTF16) == .under,
                     "containers-dense KD-CODE-\(pad2(k)): must be in PR 3's admitted cohort and under budget")
        summary.code += 1
        summary.codeCanvas.append("\(shape.lineCount)x\(shape.maxLineUTF16)")
        return codeBlockNode(language: ["swift", "json", "python", "bash"][k % 4], text: text)
    }

    for (c, shape) in shapes.enumerated() {
        summary.containers += 1
        summary.kinds[shape.kind.rawValue, default: 0] += 1
        summary.buckets[shape.bucket] += 1
        let start = firstLeaf[c]
        let nests = shape.leaves >= 3 && c % ContainersDenseSpec.nestEvery == 1
        let outerEnd = start + shape.leaves - (nests ? ContainersDenseSpec.nestedLeaves : 0)
        let headingLevel = shape.leaves >= 4 ? 3 + c % 4 : nil
        let outer = leafBlocks(start ..< outerEnd, label: label(c), headingLevel: headingLevel)
        var tail: [[String: Any]] = []
        if nests {
            let inner = leafBlocks(outerEnd ..< start + shape.leaves, label: nil, headingLevel: nil)
            tail.append(shape.kind == .panel ? quoteNode(inner) : panel(inner))
            summary.nestedContainers += 1
        }
        if codeAt.contains(c) {
            tail.append(nestedCode())
        }
        switch shape.kind {
        case .panel:
            blocks.append(panel(outer + tail))
        case .quote:
            blocks.append(quoteNode(outer + tail))
        case .extensionBody:
            blocks.append(bodiedExtensionNode(key: "excerpt", title: label(c) + " excerpt macro",
                                              localId: "kd-ext-\(c)", outer + tail))
        case .columns:
            let widths = ContainersDenseSpec.columnSplits[columnsOrdinal % ContainersDenseSpec.columnSplits.count]
            columnsOrdinal += 1
            var columns: [[String: Any]] = []
            for (k, width) in widths.enumerated() {
                var content = Array(outer[(k * outer.count) / widths.count ..< ((k + 1) * outer.count) / widths.count])
                if k == widths.count - 1 { content += tail }
                if content.isEmpty { content = [rule()] }
                columns.append(layoutColumnNode(width: width, content))
            }
            blocks.append(layoutSectionNode(columns))
        }
        if c % ContainersDenseSpec.groupSize == ContainersDenseSpec.expandAfter {
            let group = c / ContainersDenseSpec.groupSize
            blocks.append(expandNode("KD-EXPAND-" + pad2(group) + " closed expand: the gate never opens it", [
                paragraph([textNode(sentence(&rng, wordCount: rng.int(8 ..< 20)))]),
                paragraph([textNode(sentence(&rng, wordCount: rng.int(8 ..< 20)))]),
            ]))
            summary.expands += 1
        }
    }
    let document = doc(blocks)
    summary.roots = blocks.count
    summary.estimatedPoints = estimatorDocumentPoints(document)
    return document
}

func printContainersDenseSummary(_ summaries: [ContainersDenseSummary]) {
    print("containers-dense (emitted: version \(ContainersDenseSpec.version); every version is generated and checked):")
    for s in summaries {
        let seconds = fixedDecimal(Int(s.estimatedPoints.rounded()), 1_200, places: 1)
        let containerKinds = ["panel", "quote", "columns", "extension"].map { "\($0)=\(s.kinds[$0] ?? 0)" }.joined(separator: " ")
        let leafClasses = ["plain", "marked", "linked", "atom"].map { "\($0)=\(s.classes[$0] ?? 0)" }.joined(separator: " ")
        let lists = ["bulletList", "orderedList", "taskList"].map { "\($0)=\(s.lists[$0] ?? 0)" }.joined(separator: " ")
        print("  version \(s.version): \(s.containers) containers + \(s.expands) closed expands = \(s.roots) top-level blocks, \(s.bytes) bytes")
        print("    kinds: \(containerKinds); nested containers: \(s.nestedContainers)")
        print("    leaves per container: 1=\(s.buckets[0]) 2-3=\(s.buckets[1]) 4-8=\(s.buckets[2])"
            + " (ladder moved \(s.lightenedToTwoOrThree) to 2-3, \(s.lightenedToOne) to 1)")
        print("    leaves: \(s.leaves); list leaders \(s.listLeaders) (\(fixedDecimal(100 * s.listLeaders, s.leaves, places: 1)) %);"
            + " \(leafClasses); headings \(s.headings)")
        print("    lists: \(lists); nested code: \(s.code) (lines x columns: \(s.codeCanvas.joined(separator: " ")))")
        print("    estimate: \(Int(s.estimatedPoints.rounded())) pt = \(seconds) s at 1,200 pt/s")
    }
}

// MARK: - Fixture 16: containers-expand.json

enum ContainersExpandSpec {
    /// The search sentinel: one token, exactly once in the document, alone
    /// in its own paragraph in the deepest body of block 0's chain.
    static let sentinel = "CXOPENSENTINEL"
    /// CE-TALL's body: exactly this many plain paragraphs.
    static let tallParagraphs = 300
    /// Eligible leaves in the outer body of CE-OPEN-1 … CE-OPEN-5
    /// (paragraphs, headings, list and task leaders), each body also
    /// holding one code block and one nested expand of four paragraphs.
    static let openLeafCounts = [30, 33, 35, 37, 40]
    /// Filler after CE-TALL and after each CE-OPEN expand: plain text of at
    /// least this many estimated points (four screens of an iPhone 17 Pro,
    /// 874 pt each), so an open expand's row leaves the render region
    /// before the next landmark `[UNSURE 16]`.
    static let fillerPoints = 4 * 874.0
    /// The whole document's estimated autoscroll: at least this long, so
    /// arm A reports at least 2,000 frames at 60 Hz (33.3 s) with margin.
    /// The tail after block 0 is sized to reach it.
    static let minimumSeconds = 40
}

/// Block 0 is the search-opened chain; then a plain tail sized for the
/// frame floor; then the lifecycle landmarks, each a heading `CE-S<n>`
/// before its root expand, with filler between them:
///
///   0  expand CE-CHAIN (closed in the bytes; `-searchQuery CXOPENSENTINEL`
///      opens 0.0, its nested expand 0.0.2 and that one's nested expand
///      0.0.2.2; the sentinel paragraph is 0.0.2.2.1). The outer body
///      holds paragraphs and a task list, the middle body a code block,
///      the deepest body two eligible paragraphs around the sentinel.
///   1  heading CE-S1, then the plain tail (CE-TAIL-<nnn> paragraphs, an
///      h3 every eighth)
///   heading CE-S2, expand CE-TALL (300 paragraphs CE-TALL-001 …
///      CE-TALL-300), filler CE-FILL-T-<nnn>
///   heading CE-S3 … CE-S7, expand CE-OPEN-1 … CE-OPEN-5, filler
///      CE-FILL-<k>-<nnn> after each
///   paragraph CE-END
///
/// The chain's third level is a nestedExpand inside a nestedExpand, which
/// the ADF schema does not allow but the parser, the views and search all
/// accept; it makes "the full chain" longer than one link. No table, no
/// media. Each section draws on its own seed, so the tail's length (fixed
/// last) changes no other section's bytes.
func makeContainersExpand() -> [String: Any] {
    func p(_ text: String) -> [String: Any] { paragraph([textNode(text)]) }
    func h(_ level: Int, _ text: String) -> [String: Any] { headingNode(level: level, text) }

    /// Plain filler of at least `points` estimated points: paragraphs
    /// `<tag>-<nnn> …`, every eighth an h3.
    func filler(_ tag: String, seed: UInt64, points: Double) -> [[String: Any]] {
        var rng = LCG(seed: seed)
        var out: [[String: Any]] = []
        var height = 0.0
        while height < points {
            let label = "\(tag)-" + pad3(out.count + 1)
            let node: [String: Any]
            if out.count % 8 == 7 {
                node = h(3, label + " " + sentence(&rng, wordCount: rng.int(2 ..< 5)))
            } else {
                node = p(label + " " + sentence(&rng, wordCount: rng.int(10 ..< 31)))
            }
            height += estimatorPoints(node)
            out.append(node)
        }
        return out
    }

    func admittedCode(_ rng: inout LCG, header: String, lines: Int, columns: Int) -> [String: Any] {
        let text = generatedCodeBlock(&rng, header: header, lineCount: lines, columns: columns, minColumns: 24)
        let shape = codeTextShape(text)
        precondition(shape.isPrintableASCIIAndLF && shape.trailingNewlineCount == 0
                         && !text.components(separatedBy: "\n").contains { $0.isEmpty || $0.hasSuffix(" ") }
                         && codeBudgetVerdict(lineCount: shape.lineCount, maxColumns: shape.maxLineUTF16) == .under
                         && codeBudgetVerdict(lineCount: shape.lineCount, maxColumns: shape.maxLineUTF16, scale: 2) == .under,
                     "containers-expand: \(header) must be in PR 3's admitted cohort and under budget")
        return codeBlockNode(language: "swift", text: text)
    }

    // Block 0: the search-opened chain.
    var chainRNG = LCG(seed: 0x5EED_4E01)
    let chain = expandNode("CE-CHAIN outer expand: the search opens this chain", [
        p("CE-CHAIN-L1-A a paragraph in the outer body"),
        taskListNode("ce-chain-tasks", [
            taskItemNode("ce-chain-task-a", done: false, [textNode("CE-CHAIN-TASK-A an open task in the outer body")]),
            taskItemNode("ce-chain-task-b", done: true, [textNode("CE-CHAIN-TASK-B a done task in the outer body")]),
        ]),
        nestedExpandNode("CE-CHAIN-L2 nested expand", [
            p("CE-CHAIN-L2-A a paragraph in the nested body"),
            admittedCode(&chainRNG, header: "// CE-CHAIN-CODE a code block in the nested body", lines: 5, columns: 60),
            nestedExpandNode("CE-CHAIN-L3 deepest expand", [
                p("CE-CHAIN-L3-A an eligible paragraph before the sentinel"),
                p(ContainersExpandSpec.sentinel),
                p("CE-CHAIN-L3-B an eligible paragraph after the sentinel"),
            ]),
            p("CE-CHAIN-L2-B a paragraph after the deepest expand"),
        ]),
        p("CE-CHAIN-L1-B the last paragraph of the outer body"),
    ])

    // CE-TALL: exactly 300 plain eligible paragraphs.
    var tallRNG = LCG(seed: 0x5EED_4E02)
    var tallBody: [[String: Any]] = []
    for n in 1 ... ContainersExpandSpec.tallParagraphs {
        tallBody.append(p("CE-TALL-" + pad3(n) + " " + sentence(&tallRNG, wordCount: tallRNG.int(4 ..< 10))))
    }
    let tall = expandNode("CE-TALL tall expand: \(ContainersExpandSpec.tallParagraphs) plain paragraphs", tallBody)

    // CE-OPEN-1 … CE-OPEN-5.
    func openExpand(_ k: Int, leaves: Int) -> [String: Any] {
        var rng = LCG(seed: 0x5EED_4E10 + UInt64(k))
        let tag = "CE-OPEN-\(k)"
        var body: [[String: Any]] = []
        var leafCount = 0
        var serial = 0
        var listDone = false
        var codeDone = false
        var tasksDone = false
        var nestedDone = false
        func nextLabel() -> String {
            serial += 1
            return "\(tag)-B" + pad2(serial)
        }
        body.append(p("\(nextLabel()) the first paragraph of open expand \(k)"))
        leafCount += 1
        while leafCount < leaves - 1 {
            if !listDone, leafCount >= 8 {
                body.append(bulletListNode([
                    listItemNode([p("\(tag)-L1 the first bullet of open expand \(k)")]),
                    listItemNode([p("\(tag)-L2 the second bullet")]),
                    listItemNode([p("\(tag)-L3 the third bullet")]),
                ]))
                leafCount += 3
                listDone = true
            } else if !codeDone, leafCount >= 14 {
                body.append(admittedCode(&rng, header: "// \(tag)-CODE code child of open expand \(k)", lines: 6, columns: 90))
                codeDone = true
            } else if !tasksDone, leafCount >= 18 {
                body.append(taskListNode("ce-open-\(k)-tasks", [
                    taskItemNode("ce-open-\(k)-task-1", done: false, [textNode("\(tag)-T1 an open task in open expand \(k)")]),
                    taskItemNode("ce-open-\(k)-task-2", done: true, [textNode("\(tag)-T2 a done task")]),
                ]))
                leafCount += 2
                tasksDone = true
            } else if !nestedDone, leafCount >= 24 {
                body.append(nestedExpandNode("\(tag)-NESTED nested expand of open expand \(k)", [
                    p("\(tag)-N1 the first paragraph of the nested body"),
                    p("\(tag)-N2 " + sentence(&rng, wordCount: rng.int(8 ..< 16))),
                    p("\(tag)-N3 " + sentence(&rng, wordCount: rng.int(8 ..< 16))),
                    p("\(tag)-N4 the last paragraph of the nested body"),
                ]))
                nestedDone = true
            } else if serial % 6 == 5 {
                body.append(h(3, "\(nextLabel()) " + sentence(&rng, wordCount: rng.int(2 ..< 5))))
                leafCount += 1
            } else {
                body.append(p("\(nextLabel()) " + sentence(&rng, wordCount: rng.int(8 ..< 20))))
                leafCount += 1
            }
        }
        body.append(p("\(nextLabel()) the last paragraph of open expand \(k)"))
        leafCount += 1
        precondition(leafCount == leaves && listDone && codeDone && tasksDone && nestedDone,
                     "containers-expand \(tag): \(leafCount) leaves, list \(listDone) code \(codeDone) tasks \(tasksDone) nested \(nestedDone)")
        return expandNode("\(tag) open expand \(k): \(leaves) leaves and a nested expand", body)
    }

    var lifecycle: [[String: Any]] = [h(2, "CE-S2 Tall expand: 300 plain paragraphs (testK8)"), tall]
    lifecycle += filler("CE-FILL-T", seed: 0x5EED_4E03, points: ContainersExpandSpec.fillerPoints)
    for (offset, leaves) in ContainersExpandSpec.openLeafCounts.enumerated() {
        let k = offset + 1
        lifecycle.append(h(2, "CE-S\(k + 2) Open expand \(k) (testK5, testK6, testK7)"))
        lifecycle.append(openExpand(k, leaves: leaves))
        lifecycle += filler("CE-FILL-\(k)", seed: 0x5EED_4E20 + UInt64(k), points: ContainersExpandSpec.fillerPoints)
    }
    lifecycle.append(p("CE-END end of the containers expand fixture"))

    // The tail, sized last: the whole document must reach the frame floor.
    let head: [[String: Any]] = [chain, h(2, "CE-S1 Plain tail: the static scroll after the search-opened chain")]
    let fixedPoints = (head + lifecycle).reduce(0) { $0 + estimatorPoints($1) }
    let targetPoints = Double(ContainersExpandSpec.minimumSeconds * 1_200)
    let tail = filler("CE-TAIL", seed: 0x5EED_4E04, points: max(ContainersExpandSpec.fillerPoints, targetPoints - fixedPoints))
    let document = doc(head + tail + lifecycle)
    precondition(estimatorDocumentPoints(document) >= targetPoints, "containers-expand: under the frame floor")
    return document
}

// MARK: - Fixture 17: captions-parity.json

/// Hand-authored, no RNG. Every media is an external `placeholder://` URL
/// (the demo draws it offline) at a fixed pixel width: no percentage-width
/// media row, so no lifecycle test parks on the media livelock's shape.
/// Caption owners are the media nodes (`0.<index>.0`, or deeper inside a
/// container). Top-level node index → node:
///
///   0 heading CAP-S1 Caption shapes
///   1 CAP-01 no caption node (control: no caption row)
///   2 CAP-02 an empty caption node (no row)
///   3 CAP-03 plain           4 CAP-04 marks            5 CAP-05 a link
///   6 CAP-06 a link whose URL is whitespace only
///   7 CAP-07 author colours (text and background)
///   8 CAP-08 a placeholder node (a grey italic text run)
///   9 CAP-09 atoms: mention, date, status (stays SwiftUI)
///  10 CAP-10 a long caption that wraps, with a hard break
///  11 CAP-11 Unicode, emoji, Hebrew and Arabic
///  12 heading CAP-S2 Captions inside containers
///  13 panel (paragraph, CAP-12)   14 50/50 columns (CAP-13 | paragraph)
///  15 expand (paragraph, CAP-14; closed in the bytes)
///  16 heading CAP-S3 Captions under each media layout
///  17–23 CAP-L-CENTER, -WRAP-LEFT, -WRAP-RIGHT, -ALIGN-START, -ALIGN-END,
///        -WIDE, -FULL-WIDTH
///  24 paragraph CAP-END
///
/// The images in 1–11 and 13–15 are 240 pt wide (a 640 × 480 source), the
/// layout row's 200 pt; every media carries alt text `CAP-<nn> image`.
func makeCaptionsParity() -> [String: Any] {
    var blocks: [[String: Any]] = []
    let linkBase = "https://example.com/captions-parity/"
    func p(_ text: String) -> [String: Any] { paragraph([textNode(text)]) }
    func image(_ label: String, layout: String = "center", width: Int = 240, caption: [[String: Any]]?) -> [String: Any] {
        let media = externalMediaNode(url: "placeholder://captions-parity/" + label.lowercased(),
                                      width: 640, height: 480, alt: "\(label) image")
        return mediaSingleNode(layout: layout, pixelWidth: width, media: media, caption: caption)
    }

    blocks.append(headingNode(level: 2, "CAP-S1 Caption shapes"))
    blocks.append(image("CAP-01", caption: nil))
    blocks.append(image("CAP-02", caption: []))
    blocks.append(image("CAP-03", caption: [textNode("CAP-03 a plain caption under a centred image")]))
    blocks.append(image("CAP-04", caption: [
        textNode("CAP-04 "),
        textNode("bold", marks: [["type": "strong"]]),
        textNode(" "),
        textNode("italic", marks: [["type": "em"]]),
        textNode(" "),
        textNode("code", marks: [["type": "code"]]),
        textNode(" "),
        textNode("struck", marks: [["type": "strike"]]),
        textNode(" "),
        textNode("underlined", marks: [["type": "underline"]]),
        textNode(" x"),
        textNode("2", marks: [["type": "subsup", "attrs": ["type": "sup"]]]),
        textNode(" H"),
        textNode("2", marks: [["type": "subsup", "attrs": ["type": "sub"]]]),
        textNode("O"),
    ]))
    blocks.append(image("CAP-05", caption: [
        textNode("CAP-05 a caption with "),
        textNode("a linked source", marks: [linkMark(linkBase + "cap-05")]),
        textNode(" and more text"),
    ]))
    blocks.append(image("CAP-06", caption: [
        textNode("CAP-06 a caption whose link URL is whitespace only: "),
        textNode("blank target", marks: [linkMark("   ")]),
    ]))
    blocks.append(image("CAP-07", caption: [
        textNode("CAP-07 "),
        textNode("red caption text", marks: [["type": "textColor", "attrs": ["color": "#ff5630"]]]),
        textNode(" and "),
        textNode("highlighted text", marks: [["type": "backgroundColor", "attrs": ["color": "#fffae6"]]]),
    ]))
    blocks.append(image("CAP-08", caption: [
        textNode("CAP-08 a caption with a placeholder: "),
        placeholderTextNode("Add a caption here"),
    ]))
    blocks.append(image("CAP-09", caption: [
        textNode("CAP-09 by "),
        mentionNode(id: "cap-user-1", text: "@CAP Author"),
        textNode(" on "),
        date(500),
        textNode(" "),
        statusNode("DRAFT", color: "purple", localId: "cap-status-1"),
    ]))
    blocks.append(image("CAP-10", caption: [
        textNode("CAP-10 a long caption that wraps across several lines at phone width, so the caption's "
            + "height and its line breaks must match under the image"),
        hardBreakNode(),
        textNode("and a second line after a hard break"),
    ]))
    blocks.append(image("CAP-11", caption: [
        textNode("CAP-11 café 日本語 👩🏽‍💻 ✅ "),
        ["type": "emoji", "attrs": ["shortName": ":rocket:", "id": "1f680", "text": "🚀"]],
        textNode(" שלום עולם مرحبا"),
    ]))

    blocks.append(headingNode(level: 2, "CAP-S2 Captions inside containers"))
    blocks.append(panelNode("info", [
        p("CAP-PANEL-P a paragraph above the captioned image in a panel"),
        image("CAP-12", caption: [textNode("CAP-12 a caption inside a panel")]),
    ]))
    blocks.append(layoutSectionNode([
        layoutColumnNode(width: 50, [image("CAP-13", caption: [textNode("CAP-13 a caption inside a column")])]),
        layoutColumnNode(width: 50, [p("CAP-COLUMN-P a paragraph beside the captioned image")]),
    ]))
    blocks.append(expandNode("CAP-EXPAND a captioned image inside an expand", [
        p("CAP-EXPAND-P a paragraph above the captioned image in an expand"),
        image("CAP-14", caption: [textNode("CAP-14 a caption inside an expand")]),
    ]))

    blocks.append(headingNode(level: 2, "CAP-S3 Captions under each media layout"))
    for layout in ["center", "wrap-left", "wrap-right", "align-start", "align-end", "wide", "full-width"] {
        let label = "CAP-L-" + layout.uppercased()
        blocks.append(image(label, layout: layout, width: 200, caption: [
            textNode("\(label) a caption under a \(layout) image"),
        ]))
    }
    blocks.append(p("CAP-END end of the captions parity fixture"))
    return doc(blocks)
}

// MARK: - Emit

/// At most one argument. `--check` regenerates every fixture in memory,
/// writes nothing, compares each with the bytes in Fixtures/ and exits 1 if
/// any differs or is missing (0 when all match). `--landmarks` writes
/// nothing and prints the PR 4 fixtures' landmark and owner tables as
/// Markdown. Anything else is a usage error (exit 2). With no argument the
/// generator writes every fixture, as before.
let checkOnly: Bool
let landmarksOnly: Bool
switch Array(CommandLine.arguments.dropFirst()) {
case []:
    checkOnly = false
    landmarksOnly = false
case ["--check"]:
    checkOnly = true
    landmarksOnly = false
case ["--landmarks"]:
    checkOnly = false
    landmarksOnly = true
default:
    FileHandle.standardError.write(Data("usage: swift Tools/make-fixtures.swift [--check | --landmarks]\n".utf8))
    exit(2)
}

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // …/Tools
    .deletingLastPathComponent() // repo root
let fixturesDir = repoRoot.appendingPathComponent("Fixtures")
if !checkOnly && !landmarksOnly {
    try FileManager.default.createDirectory(at: fixturesDir, withIntermediateDirectories: true)
}

let stress5K = makeStress5K()
var listDenseTally = ListDenseTally()
let listDense = makeListDense(tally: &listDenseTally)
let codeParity = makeCodeParity()
var codeDenseSummary = CodeDenseSummary()
let codeDense = makeCodeDense(summary: &codeDenseSummary)
let codeTall = makeCodeTall()
let containersParity = makeContainersParity()
// Every version of the ladder is generated and checked against the band;
// the one `ContainersDenseSpec.version` names is emitted.
var containersDenseSummaries: [ContainersDenseSummary] = []
var containersDense: [String: Any] = [:]
for version in 1 ... 3 {
    var summary = ContainersDenseSummary()
    let document = makeContainersDense(version: version, summary: &summary)
    summary.bytes = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).count
    let seconds = summary.estimatedPoints / 1_200
    precondition(Double(ContainersDenseSpec.secondsBand.lowerBound) <= seconds
                     && seconds <= Double(ContainersDenseSpec.secondsBand.upperBound),
                 "containers-dense version \(version): estimated \(Int(seconds)) s is outside \(ContainersDenseSpec.secondsBand) s")
    containersDenseSummaries.append(summary)
    if version == ContainersDenseSpec.version {
        containersDense = document
    }
}
let containersExpand = makeContainersExpand()
let captionsParity = makeCaptionsParity()
let fixtures: [(name: String, document: [String: Any])] = [
    ("stress-5k.json", stress5K),
    ("stress-1k.json", makeStress1K(from: stress5K)),
    ("giant-table.json", makeGiantTable()),
    ("media-gallery.json", makeMediaGallery()),
    ("text-dense.json", makeTextDense()),
    ("long-paragraph.json", makeLongParagraph()),
    ("lists-parity.json", makeListsParity()),
    ("list-dense.json", listDense),
    ("list-tall.json", makeListTall()),
    ("lists-links.json", makeListsLinks()),
    ("code-parity.json", codeParity.document),
    ("code-dense.json", codeDense.document),
    ("code-tall.json", codeTall.document),
    ("containers-parity.json", containersParity),
    ("containers-dense.json", containersDense),
    ("containers-expand.json", containersExpand),
    ("captions-parity.json", captionsParity),
]

if landmarksOnly {
    func size(_ document: [String: Any]) -> String {
        let bytes = (try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).count) ?? 0
        let seconds = fixedDecimal(Int(estimatorDocumentPoints(document).rounded()), 1_200, places: 1)
        return "\(bytes) bytes; estimated autoscroll \(seconds) s at 1,200 pt/s (closed expands count 48 pt)."
    }
    print("# PR 4 fixture landmarks and owners")
    print("")
    print("Generated by `swift Tools/make-fixtures.swift --landmarks`. A fraction lands on the block named"
        + " (`ReaderView.fractionTarget`); tables prepare to slices and a bodied sync block is transparent,"
        + " so prepared indices can differ from node indices. Owner ids are what `tk2-row:<id>` carries.")
    print("")
    printLandmarks(
        fixture: "containers-parity", document: containersParity, prefixes: ["KP-"], summary: size(containersParity),
        rootFilter: { _, _ in true }, ownerFilter: { _ in true }
    )
    let denseRoots = (containersDense["content"] as? [[String: Any]] ?? []).count
    let denseSummary = containersDenseSummaries[ContainersDenseSpec.version - 1]
    printLandmarks(
        fixture: "containers-dense (version \(ContainersDenseSpec.version))", document: containersDense, prefixes: ["KD-"],
        summary: size(containersDense) + " \(denseSummary.containers) containers, \(denseSummary.leaves) leaves."
            + " Every container's first leaf starts with `KD-<iiii>` (its container index); rows shown:"
            + " the first six, every 105th and the last four.",
        rootFilter: { index, _ in index < 6 || index % 105 == 0 || index >= denseRoots - 4 },
        ownerFilter: { _ in false }
    )
    let tallMiddle = Set((2 ..< ContainersExpandSpec.tallParagraphs).map { "CE-TALL-" + pad3($0) })
    let expandRoots = (containersExpand["content"] as? [[String: Any]] ?? []).count
    printLandmarks(
        fixture: "containers-expand", document: containersExpand, prefixes: ["CE-", "CX"],
        summary: size(containersExpand) + " Rows shown: the h2 section headings, the expands and the last root"
            + " (the filler's h3 headings are left out); owners shown: all but the filler and"
            + " CE-TALL-002 … CE-TALL-299.",
        rootFilter: { index, root in
            let type = root["type"] as? String
            let level = (root["attrs"] as? [String: Any])?["level"] as? Int
            return (type == "heading" && level == 2) || type == "expand" || index == expandRoots - 1
        },
        ownerFilter: { owner in
            !owner.token.hasPrefix("CE-TAIL") && !owner.token.hasPrefix("CE-FILL") && !tallMiddle.contains(owner.token)
        }
    )
    printLandmarks(
        fixture: "captions-parity", document: captionsParity, prefixes: ["CAP-"], summary: size(captionsParity),
        rootFilter: { _, _ in true }, ownerFilter: { _ in true }
    )
    exit(0)
}

if checkOnly {
    var differing: [String] = []
    for (name, document) in fixtures {
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        let url = fixturesDir.appendingPathComponent(name)
        guard let committed = try? Data(contentsOf: url) else {
            print("MISSING \(name): regenerated \(data.count) bytes, no file in Fixtures/")
            differing.append(name)
            continue
        }
        if committed == data {
            print("same    \(name): \(data.count) bytes")
        } else {
            print("DIFFERS \(name): regenerated \(data.count) bytes, Fixtures/ has \(committed.count)")
            differing.append(name)
        }
    }
    if differing.isEmpty {
        print("check: all \(fixtures.count) generated fixtures match Fixtures/ byte for byte; nothing written")
        exit(0)
    }
    print("check: \(differing.count) of \(fixtures.count) generated fixtures differ: \(differing.joined(separator: " ")); nothing written")
    exit(1)
}

for (name, document) in fixtures {
    let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    let url = fixturesDir.appendingPathComponent(name)
    try data.write(to: url)
    let blockCount = (document["content"] as? [[String: Any]])?.count ?? 0
    print("wrote \(name): \(blockCount) top-level blocks, \(data.count) bytes")
}

func sortedTally(_ counts: [String: Int]) -> String {
    counts.keys.sorted().map { "\($0)=\(counts[$0] ?? 0)" }.joined(separator: " ")
}

print("list-dense tally (emitted nodes, not preparer output):")
print("  root lists: \(sortedTally(listDenseTally.rootLists))")
print("  items (marker rows): \(listDenseTally.items); continuation rows: \(listDenseTally.continuationRows)")
print("  leaders: \(sortedTally(listDenseTally.leaders))")
print("  extra paragraphs: \(sortedTally(listDenseTally.extraParagraphs))")
print("  continuation paragraphs: \(sortedTally(listDenseTally.continuationParagraphs))")
print("  trailing headings: \(listDenseTally.trailingHeadings)")

// MARK: - Code fixture summaries

/// `numerator / denominator` with `places` decimals, rounded half up
/// (integer arithmetic: locale-free).
func fixedDecimal(_ numerator: Int, _ denominator: Int, places: Int) -> String {
    var scale = 1
    for _ in 0 ..< places {
        scale *= 10
    }
    let scaled = (2 * numerator * scale + denominator) / (2 * denominator)
    guard places > 0 else { return String(scaled) }
    let whole = String(scaled / scale)
    let fraction = String(scaled % scale)
    let padding = String(repeating: "0", count: places - fraction.count)
    return "\(whole).\(padding)\(fraction)"
}

func codeLanguageLabel(_ language: String?) -> String {
    guard let language else { return "nil" }
    return language.isEmpty ? "empty" : language
}

/// Where a block's text stands against the admitted cohort's content rule.
func codeCohortLabel(_ shape: CodeTextShape) -> String {
    if shape.isEmpty { return "empty" }
    if shape.isAllNewlines { return "newlines-only" }
    if shape.isPrintableASCIIAndLF { return "ascii+lf" }
    var reasons: [String] = []
    if shape.hasTabs { reasons.append("tabs") }
    if shape.hasNonASCII { reasons.append("non-ascii") }
    if reasons.isEmpty { reasons.append("control") }
    return reasons.joined(separator: "+")
}

func codeVerdictLabel(_ shape: CodeTextShape, scale: Int) -> String {
    codeBudgetVerdict(lineCount: shape.lineCount, maxColumns: shape.maxLineUTF16, scale: scale).rawValue
}

/// The bound at the documented metrics (no margin), for the record.
func codeCanvasLabel(_ shape: CodeTextShape, scale: Int) -> String {
    let estimate = codeCanvasEstimate(lineCount: shape.lineCount, maxColumns: shape.maxLineUTF16, scale: scale)
    let mebibytes = fixedDecimal(estimate.bytes, 1_048_576, places: 2)
    return "\(estimate.widthPixels)x\(estimate.heightPixels)px=\(mebibytes)MiB"
}

func codeRangeName(_ range: ClosedRange<Int>) -> String {
    if range.lowerBound == range.upperBound {
        return String(range.lowerBound)
    }
    return "\(range.lowerBound)-\(range.upperBound)"
}

/// `sum(19 x lines + 28)`: the autoscroll estimator's height of these
/// code blocks, in points (`BlockHeightEstimator`, AutoScroller.swift).
func codeEstimatorPoints(_ records: [CodeBlockRecord]) -> Int {
    var points = 0
    for record in records {
        points += 19 * record.shape.lineCount + 28
    }
    return points
}

func codeHistogram(_ values: [Int], bins: [ClosedRange<Int>]) -> String {
    var parts: [String] = []
    var counted = 0
    for bin in bins {
        var count = 0
        for value in values where bin.contains(value) {
            count += 1
        }
        counted += count
        let name = codeRangeName(bin)
        parts.append("\(name)=\(count)")
    }
    let other = values.count - counted
    parts.append("other=\(other)")
    return parts.joined(separator: " ")
}

func printCodeBlockTable(_ title: String, _ fixture: CodeFixture) {
    print(title)
    let scale = CodeCanvasModel.displayScale
    for record in fixture.records {
        let shape = record.shape
        let language = codeLanguageLabel(record.language)
        let breakout = record.breakoutMode ?? "-"
        let cohort = codeCohortLabel(shape)
        let verdict = codeVerdictLabel(shape, scale: scale)
        let verdict2x = codeVerdictLabel(shape, scale: 2)
        let canvas = codeCanvasLabel(shape, scale: scale)
        var fields: [String] = []
        fields.append("0.\(record.index)")
        fields.append(record.label)
        fields.append("lines=\(shape.lineCount)")
        fields.append("cols=\(shape.maxLineUTF16)")
        fields.append("trailingLF=\(shape.trailingNewlineCount)")
        fields.append("lang=\(language)")
        fields.append("breakout=\(breakout)")
        fields.append("cohort=\(cohort)")
        fields.append("budget=\(verdict)")
        fields.append("budget2x=\(verdict2x)")
        fields.append("bound=\(canvas)")
        if !record.note.isEmpty {
            fields.append(" # \(record.note)")
        }
        let row = fields.joined(separator: " ")
        print("  \(row)")
    }
    for note in fixture.notes {
        print("  nested: \(note)")
    }
    let points = codeEstimatorPoints(fixture.records)
    let seconds = fixedDecimal(points, 1_200, places: 1)
    print("  top-level code blocks: \(fixture.records.count); estimator height of the code blocks: \(points) pt = \(seconds) s at 1,200 pt/s")
}

func printCodeDenseSummary(_ fixture: CodeFixture, _ summary: CodeDenseSummary) {
    let records = fixture.records
    let scale = CodeCanvasModel.displayScale
    let overName = CodeBudgetVerdict.over.rawValue
    var lineCounts: [Int] = []
    var widths: [Int] = []
    var totalLines = 0
    var totalUnits = 0
    var languages: [String: Int] = [:]
    var breakouts: [String: Int] = [:]
    var scale2: [String: Int] = [:]
    var overLabels: [String] = []
    var overAt2x: [String] = []
    for record in records {
        let shape = record.shape
        lineCounts.append(shape.lineCount)
        widths.append(shape.maxLineUTF16)
        totalLines += shape.lineCount
        totalUnits += shape.utf16Count
        languages[codeLanguageLabel(record.language), default: 0] += 1
        breakouts[record.breakoutMode ?? "none", default: 0] += 1
        let verdict2x = codeVerdictLabel(shape, scale: 2)
        scale2[verdict2x, default: 0] += 1
        if verdict2x == overName {
            overAt2x.append(record.label)
        }
        if codeVerdictLabel(shape, scale: scale) == overName {
            overLabels.append("\(record.label)(\(shape.lineCount)x\(shape.maxLineUTF16))")
        }
    }
    let blockCount = records.count
    let points = codeEstimatorPoints(records)
    var legPoints = points
    if let last = records.last {
        legPoints -= 19 * last.shape.lineCount + 28
    }
    var joint: [String] = []
    for (bucket, row) in summary.drawnJoint.enumerated() {
        let name = codeRangeName(CodeDenseSpec.lineBuckets[bucket])
        let counts = row.map { String($0) }.joined(separator: "/")
        joint.append("\(name) lines: \(counts)")
    }
    // Blocks per drawn width bucket: the quotas in version 1, the ladder's
    // counts in versions 2 and 3.
    var widthQuotas: [String] = []
    for (bucket, range) in CodeDenseSpec.widthBuckets.enumerated() {
        let name = codeRangeName(range)
        var drawn = 0
        for row in summary.drawnJoint {
            drawn += row[bucket]
        }
        widthQuotas.append("\(name)=\(drawn)")
    }
    var firstScreen: [String] = []
    for record in records.prefix(CodeDenseSpec.firstScreenBlocks) {
        let verdict = codeVerdictLabel(record.shape, scale: scale)
        firstScreen.append("\(record.label) \(record.shape.lineCount)x\(record.shape.maxLineUTF16) \(verdict)")
    }
    let meanLines = fixedDecimal(totalLines, max(blockCount, 1), places: 2)
    let seconds = fixedDecimal(points, 1_200, places: 1)
    let legSeconds = fixedDecimal(legPoints, 1_200, places: 1)
    let lineHistogram = codeHistogram(lineCounts, bins: CodeDenseSpec.lineBuckets)
    let emittedBins: [ClosedRange<Int>] = [1 ... 15, 16 ... 40, 41 ... 59, 60 ... 120, 121 ... 149, 150 ... 220]
    let widthHistogram = codeHistogram(widths, bins: emittedBins)
    let widthQuotaLine = widthQuotas.joined(separator: " ")
    let jointLine = joint.joined(separator: "; ")
    let shortenedLine = summary.shortenedBlocks.map { "CD-" + pad3($0) }.joined(separator: " ")
    let overShare = fixedDecimal(100 * overLabels.count, max(blockCount, 1), places: 1)
    let overLine = overLabels.joined(separator: " ")
    let over2xLine = overAt2x.isEmpty ? "none" : overAt2x.joined(separator: " ")
    let scale2Line = sortedTally(scale2)
    let languageLine = sortedTally(languages)
    let breakoutLine = sortedTally(breakouts)
    let firstScreenLine = firstScreen.joined(separator: ", ")

    print("code-dense summary (emitted text measured by the generator, not preparer output):")
    print("  lighten ladder: version \(summary.version) of 3 (CodeDenseSpec.version); moved down a bucket: \(summary.lightenedTall) of the tallest, \(summary.lightenedWide) of the widest; kept blocks re-shaped: \(summary.reshapedKept)")
    print("  blocks: \(blockCount), all top-level code blocks; lines: \(totalLines), mean \(meanLines); UTF-16 units: \(totalUnits)")
    print("  autoscroll estimate: sum(19 x lines + 28) = \(points) pt = \(seconds) s at 1,200 pt/s (\(legSeconds) s of scroll legs: the last block is only a target)")
    print("  line counts (LF + 1): \(lineHistogram)")
    print("  widths drawn (blocks per bucket before the budget rule; widest line in columns): \(widthQuotaLine)")
    print("  widths emitted (true widest line, after the budget rule): \(widthHistogram)")
    print("  drawn pairs, by width bucket in that order: \(jointLine)")
    print("  budget rule: drawn over=\(summary.drawnOver) marginal=\(summary.drawnMarginal); kept over=\(summary.keptOver.count); shortened blocks=\(summary.shortenedBlocks.count) (lines cut=\(summary.shortenedLines))")
    print("  shortened: \(shortenedLine)")
    print("  declared over budget (\(scale)x, default size): \(overLabels.count) of \(blockCount) = \(overShare) %: \(overLine)")
    print("  at 2x, default size: \(scale2Line); over: \(over2xLine)")
    print("  language: \(languageLine) (nil: i % 20 == 3; empty: i % 20 == 13)")
    print("  breakout: \(breakoutLine) (i % 20 == 7; wide in even twenties)")
    print("  first screen: \(firstScreenLine)")
}

func printCodeCanvasModel() {
    let advance = fixedDecimal(CodeCanvasModel.advanceMilliPoints, 1_000, places: 3)
    let lineHeight = fixedDecimal(CodeCanvasModel.lineHeightMilliPoints, 1_000, places: 3)
    let rounding = fixedDecimal(CodeCanvasModel.roundingReserveMilliPoints, 1_000, places: 1)
    let margin = fixedDecimal(CodeCanvasModel.metricMarginPermille, 10, places: 1)
    print("code canvas model (CodeCanvasModel: constants for the default configuration; advance from the font file, line height measured at Large on iOS 26.3):")
    print("  advance \(advance) pt, line height \(lineHeight) pt, scale \(CodeCanvasModel.displayScale)x; caps \(CodeCanvasModel.maximumDimensionPixels) px per dimension and \(CodeCanvasModel.maximumBytes) bytes")
    print("  bound = (ceil(cols x advance x scale) + \(CodeCanvasModel.widthReservePixels)) x ceil(((lines + \(CodeCanvasModel.inkReserveLines)) x lineHeight + \(rounding)) x scale) px, x \(CodeCanvasModel.bytesPerPixel) bytes")
    print("  under = within the caps with both metrics \(margin) % larger; over = past a cap with both \(margin) % smaller")
}

printCodeCanvasModel()
printCodeBlockTable("code-parity top-level code blocks (id, label, lines = LF + 1, cols = widest line in UTF-16 units):", codeParity)
printCodeDenseSummary(codeDense, codeDenseSummary)
printCodeBlockTable("code-tall blocks:", codeTall)

// MARK: - Container and caption fixture summaries

printContainersDenseSummary(containersDenseSummaries)
for (name, document) in [
    ("containers-parity", containersParity), ("containers-expand", containersExpand), ("captions-parity", captionsParity),
] {
    let roots = document["content"] as? [[String: Any]] ?? []
    let seconds = fixedDecimal(Int(estimatorDocumentPoints(document).rounded()), 1_200, places: 1)
    print("\(name): \(roots.count) top-level nodes, \(preparedRootIDs(roots).count) prepared top-level blocks,"
        + " estimated autoscroll \(seconds) s (closed expands at 48 pt)")
}
print("PR 4 landmark and owner tables: swift Tools/make-fixtures.swift --landmarks")
