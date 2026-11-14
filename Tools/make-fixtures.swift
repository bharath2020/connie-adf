#!/usr/bin/env swift
// make-fixtures.swift — deterministic stress-fixture generator for ADFKit.
//
// Run from anywhere (paths resolve relative to this file):
//     swift Tools/make-fixtures.swift
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
/// The generator cannot link UIKit, so the two font metrics are constants
/// read from the font file's tables (SF Mono, `SFUIMono.ttf`, the same in
/// the iOS 18.2 to 27.1 simulator runtimes), not measured in the app: the
/// gate measures them from the resolved font at run time
/// (`TextKit2CodeMetrics`). The reserves and caps are copies.
/// CORRECT THEM HERE, and only here: every "over budget" and "just under
/// budget" block of code-parity, code-dense and code-tall is sized and
/// declared through `codeBudgetVerdict`, which reads nothing else. A change
/// moves fixture bytes (code-parity CP-16 and CP-17, code-dense's shortened
/// and kept blocks, code-tall's CT-NEAR), so settle the values before the
/// fixtures are frozen.
enum CodeCanvasModel {
    /// Advance of one code glyph, in 1/1000 pt. 17 pt SF Mono: every
    /// printable ASCII glyph advances 1266/2048 em = 10.509 pt; rounded up.
    /// (The plan's "about 10.2 pt" is Menlo's 1233/2048 em.)
    static let advanceMilliPoints = 10_510
    /// Height of one code line, in 1/1000 pt. 17 pt SF Mono: ascender 1950
    /// and descender 494 of 2048, no line gap = 20.287 pt; rounded up.
    static let lineHeightMilliPoints = 20_300
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
}

/// Three top-level code blocks and nothing else:
///   0.0 CT-TALL  400 lines × 60 columns, over budget (SwiftUI in both
///                arms). Every 50th line is a `// CT-L<iii>` marker.
///   0.1 CT-NEAR  60 columns × the most lines declared under budget: the
///                largest eligible canvas of the default configuration.
///   0.2 CT-END   a short closing block, so the autoscroll's last leg
///                crosses CT-NEAR.
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
    return CodeFixture(document: doc(blocks), records: records)
}

// MARK: - Emit

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // …/Tools
    .deletingLastPathComponent() // repo root
let fixturesDir = repoRoot.appendingPathComponent("Fixtures")
try FileManager.default.createDirectory(at: fixturesDir, withIntermediateDirectories: true)

let stress5K = makeStress5K()
var listDenseTally = ListDenseTally()
let listDense = makeListDense(tally: &listDenseTally)
let codeParity = makeCodeParity()
var codeDenseSummary = CodeDenseSummary()
let codeDense = makeCodeDense(summary: &codeDenseSummary)
let codeTall = makeCodeTall()
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
]

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
    print("code canvas model (CodeCanvasModel: documented constants for the default configuration, not measurements):")
    print("  advance \(advance) pt, line height \(lineHeight) pt, scale \(CodeCanvasModel.displayScale)x; caps \(CodeCanvasModel.maximumDimensionPixels) px per dimension and \(CodeCanvasModel.maximumBytes) bytes")
    print("  bound = (ceil(cols x advance x scale) + \(CodeCanvasModel.widthReservePixels)) x ceil(((lines + \(CodeCanvasModel.inkReserveLines)) x lineHeight + \(rounding)) x scale) px, x \(CodeCanvasModel.bytesPerPixel) bytes")
    print("  under = within the caps with both metrics \(margin) % larger; over = past a cap with both \(margin) % smaller")
}

printCodeCanvasModel()
printCodeBlockTable("code-parity top-level code blocks (id, label, lines = LF + 1, cols = widest line in UTF-16 units):", codeParity)
printCodeDenseSummary(codeDense, codeDenseSummary)
printCodeBlockTable("code-tall blocks:", codeTall)
