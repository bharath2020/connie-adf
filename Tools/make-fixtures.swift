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
//   giant-table.json    800 data rows x 6 columns, header row, sprinkled
//                       colspans and cell backgrounds
//   media-gallery.json  300 mediaSingle nodes with width/height attrs,
//                       external urls "placeholder://<n>", every layout value
//
// Fully deterministic: seeded LCG, no Date(), no system randomness.
// Output is byte-stable across runs (JSONSerialization + .sortedKeys,
// integer-only numbers).

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

// MARK: - Fixture 4: atom-stress.json (Task 24)

/// One atom-dense paragraph: mention, emoji, date, status, inlineCard,
/// mediaInline, inlineExtension — all seven non-text `InlineAtom` kinds
/// (`Sources/ADFPreparation/InlineComposer.swift`) in one paragraph, joined
/// by short connective text runs, mirroring kitchen-sink.json's ¶26 shape
/// (`Ping [mention] [emoji] due [date] see [inlineCard] … [mediaInline]
/// [inlineExtension]`) but WITHOUT its `placeholder` node (placeholder isn't
/// an `InlineAtom` / pill — irrelevant to the atom-pill stress this fixture
/// targets) and WITH a `status` atom added (kitchen-sink keeps status
/// badges in a separate paragraph; this fixture wants every pill kind
/// stressed together, per paragraph).
func atomParagraph(_ rng: inout LCG, index: Int) -> [String: Any] {
    paragraph([
        textNode("Ping "),
        mention(index),
        textNode(" "),
        emoji(&rng),
        textNode(" due "),
        date(index),
        textNode(" "),
        status(&rng, index: index),
        textNode(" see "),
        inlineCard(index),
        textNode(" "),
        mediaInline(index),
        textNode(" "),
        ["type": "inlineExtension", "attrs": extensionAttrs("status-macro", index: index)] as [String: Any],
        textNode(" \(sentence(&rng, wordCount: rng.int(2 ..< 5)))."),
    ])
}

/// 2,000 atom-dense paragraphs (pill-heavy, stress-scale — phase-3 known-gap
/// #6: "no atom-heavy stress fixture exists" to check the pill draw path's
/// behavior at stress-5k-like scale). Every paragraph carries all 7 atom
/// kinds (14,000 pill attachments total across the fixture), following
/// kitchen-sink.json's doc-wrapper shape (`{"version":1,"type":"doc",
/// "content":[…]}`) and atom-attrs shapes (same `mention`/`date`/`status`/
/// `emoji`/`inlineCard`/`mediaInline`/extension builders the other
/// generated fixtures already use — kitchen-sink itself is hand-authored
/// pretty JSON; this one is machine-generated minified JSON like
/// stress-5k/giant-table/media-gallery, picked up by the SAME `../Fixtures`
/// glob either way).
func makeAtomStress() -> [String: Any] {
    var rng = LCG(seed: 0x5EED_A70A)
    var blocks: [[String: Any]] = []
    blocks.reserveCapacity(2001)
    blocks.append(["type": "heading", "attrs": ["level": 1], "content": [textNode("Atom stress: 2,000 pill-dense paragraphs")]])
    for i in 0 ..< 2000 {
        blocks.append(atomParagraph(&rng, index: i))
    }
    return doc(blocks)
}

// MARK: - Emit

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // …/Tools
    .deletingLastPathComponent() // repo root
let fixturesDir = repoRoot.appendingPathComponent("Fixtures")
try FileManager.default.createDirectory(at: fixturesDir, withIntermediateDirectories: true)

let fixtures: [(name: String, document: [String: Any])] = [
    ("stress-5k.json", makeStress5K()),
    ("giant-table.json", makeGiantTable()),
    ("media-gallery.json", makeMediaGallery()),
    ("atom-stress.json", makeAtomStress()),
]

for (name, document) in fixtures {
    let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    let url = fixturesDir.appendingPathComponent(name)
    try data.write(to: url)
    let blockCount = (document["content"] as? [[String: Any]])?.count ?? 0
    print("wrote \(name): \(blockCount) top-level blocks, \(data.count) bytes")
}
