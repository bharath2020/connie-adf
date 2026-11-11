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

// MARK: - Emit

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // …/Tools
    .deletingLastPathComponent() // repo root
let fixturesDir = repoRoot.appendingPathComponent("Fixtures")
try FileManager.default.createDirectory(at: fixturesDir, withIntermediateDirectories: true)

let stress5K = makeStress5K()
var listDenseTally = ListDenseTally()
let listDense = makeListDense(tally: &listDenseTally)
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
