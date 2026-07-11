#!/usr/bin/env swift
// make-fixtures.swift — deterministic stress-fixture generator for ADFKit.
//
// Run from anywhere (paths resolve relative to this file):
//     swift Tools/make-fixtures.swift
//
// Emits into <repo-root>/Fixtures/:
//   stress-5k.json      5,000 mixed top-level blocks (paragraphs with mixed
//                       marks, headings, 4-deep lists, code blocks, panels,
//                       a blockquote every ~10 blocks)
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

// MARK: - Fixture 1: stress-5k.json

func makeStress5K() -> [String: Any] {
    var rng = LCG(seed: 0x5EED_5000)
    var blocks: [[String: Any]] = []
    blocks.reserveCapacity(5000)
    for i in 0 ..< 5000 {
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
]

for (name, document) in fixtures {
    let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    let url = fixturesDir.appendingPathComponent(name)
    try data.write(to: url)
    let blockCount = (document["content"] as? [[String: Any]])?.count ?? 0
    print("wrote \(name): \(blockCount) top-level blocks, \(data.count) bytes")
}
