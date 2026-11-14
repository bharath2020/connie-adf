import Foundation
import SwiftUI
import Testing
import ADFModel
import ADFPreparation

private typealias SUI = AttributeScopes.SwiftUIAttributes

/// A parsed fixture (`Fixtures/<name>.json`) and its blocks prepared under
/// `theme`.
private func preparedCodeFixture(
    _ name: String, theme: ADFTheme = .default
) async throws -> (document: ADFDocument, blocks: [RenderBlock]) {
    let document = try await ADFParser().parse(try fixtureData("\(name).json"))
    return (document, DocumentPreparer(theme: theme).prepare(document))
}

/// One prepared code block: its block id, language and code string.
private struct PreparedCode {
    let id: String
    let language: String?
    let code: AttributedString
}

/// Every prepared code block of a block tree with its block id, in prepared
/// order: the top-level ones and those inside prepared containers (a list
/// row's trailing blocks, panels, quotes, table cells, layout columns,
/// extension bodies). An expand's body stays unprepared, so code there is
/// not listed.
private func preparedCode(in blocks: [RenderBlock]) -> [PreparedCode] {
    var found: [PreparedCode] = []
    for block in blocks {
        switch block.kind {
        case .codeBlock(let language, let code):
            found.append(PreparedCode(id: block.id, language: language, code: code))
        case .panel(_, let children), .quote(let children), .extensionPlaceholder(_, let children):
            found += preparedCode(in: children)
        case .listRows(let rows):
            found += preparedCode(in: rows.flatMap(\.trailingBlocks))
        case .tableSlice(_, let rows, _):
            found += preparedCode(in: rows.flatMap { $0.cells.flatMap(\.blocks) })
        case .layoutColumns(let columns):
            found += preparedCode(in: columns.flatMap(\.blocks))
        case .richText, .divider, .media, .mediaStrip, .expand, .card, .custom, .unknown:
            break
        }
    }
    return found
}

/// The text of every code block node under `node`, by node id, read from
/// the parsed document rather than from the preparer under test.
private func sourceCode(under node: ADFNode, into found: inout [String: String]) {
    if case .codeBlock(_, let text, _) = node.kind { found[node.id] = text }
    for child in node.children { sourceCode(under: child, into: &found) }
}

/// The code block's preparation stamp (plan 3.1): next to the theme's code
/// font, every non-empty code string carries the theme's code font spec
/// (when the theme has one) and the shape of its text, over one uniform
/// run. SwiftUI reads neither, so nothing else about a prepared document may
/// change: not a block id, not a block count, not a character.
///
/// The pins below were counted from the fixtures' JSON with a standalone
/// script (a walk of `content`, a code block's text being the joined `text`
/// of its children), never from the preparer.
@Suite("Code fixture preparation")
struct CodeFixturePreparationTests {
    static let fixtures = ["kitchen-sink", "stress-1k", "lists-parity"]

    /// A theme whose code font is a raw SwiftUI `Font`: no spec.
    static let rawCodeFontTheme = ADFTheme(code: .system(size: 13, design: .monospaced))

    /// kitchen-sink: 37 top-level nodes, 38 prepared roots. Node 21 is a
    /// table of a header row and two body rows (a header slice and one rows
    /// slice); node 35 is an empty sync block (one placeholder); node 36 is
    /// a bodied sync block of one paragraph, which is transparent.
    static let kitchenSinkIDs: [String] = {
        var ids = (0...20).map { "0.\($0)" }
        ids += ["0.21#header", "0.21#rows0"]
        ids += (22...35).map { "0.\($0)" }
        ids.append("0.36.0")
        return ids
    }()

    /// lists-parity: 20 top-level nodes, 21 prepared roots (node 16 is a
    /// table of a header row and one body row).
    static let listsParityIDs: [String] = [
        "0.0", "0.1", "0.2", "0.3", "0.4", "0.5", "0.6", "0.7", "0.8", "0.9",
        "0.10", "0.11", "0.12", "0.13", "0.14", "0.15", "0.16#header", "0.16#rows0",
        "0.17", "0.18", "0.19",
    ]

    /// stress-1k: 1,000 top-level nodes, each one prepared root; its 80
    /// top-level code blocks sit at every index ending in 5 but those 45
    /// past a multiple of 50 (20 more are inside expand bodies, which stay
    /// unprepared).
    static let stressCodeIDs: [String] = (0..<1_000).filter { $0 % 10 == 5 && $0 % 50 != 45 }.map { "0.\($0)" }

    /// The ids of the prepared code blocks per fixture: kitchen-sink's one
    /// top-level block, stress-1k's 80, and the two inside list items of
    /// lists-parity (it has no top-level code).
    static let preparedCodeIDs: [String: [String]] = [
        "kitchen-sink": ["0.12"],
        "stress-1k": stressCodeIDs,
        "lists-parity": ["0.8.12.0", "0.10.2.1"],
    ]

    /// Top-level code blocks per fixture.
    static let topLevelCodeCounts: [String: Int] = ["kitchen-sink": 1, "stress-1k": 80, "lists-parity": 0]

    @Test("the stamp changes no block id and no block count")
    func blockIDsAndCounts() async throws {
        let kitchenSink = try await preparedCodeFixture("kitchen-sink")
        #expect(kitchenSink.blocks.count == 38)
        #expect(kitchenSink.blocks.map(\.id) == Self.kitchenSinkIDs)

        let stress = try await preparedCodeFixture("stress-1k")
        #expect(stress.blocks.count == 1_000)
        #expect(stress.blocks.map(\.id) == (0..<1_000).map { "0.\($0)" })

        let lists = try await preparedCodeFixture("lists-parity")
        #expect(lists.blocks.count == 21)
        #expect(lists.blocks.map(\.id) == Self.listsParityIDs)

        // The spec is stamped only when the theme has one: with or without
        // it the blocks are the same blocks.
        for fixture in Self.fixtures {
            let described = try await preparedCodeFixture(fixture)
            let raw = try await preparedCodeFixture(fixture, theme: Self.rawCodeFontTheme)
            #expect(described.blocks.map(\.id) == raw.blocks.map(\.id), "\(fixture)")
        }
    }

    @Test("the prepared code blocks are the fixtures' code nodes, id for id", arguments: fixtures)
    func preparedCodeBlocks(fixture: String) async throws {
        let (document, blocks) = try await preparedCodeFixture(fixture)
        var source: [String: String] = [:]
        sourceCode(under: document.root, into: &source)
        let prepared = preparedCode(in: blocks)
        #expect(prepared.map(\.id) == Self.preparedCodeIDs[fixture], "\(fixture)")
        // Top-level ones, as the renderer's scope counts them.
        let topLevel = blocks.filter { if case .codeBlock = $0.kind { return true } else { return false } }
        #expect(topLevel.count == Self.topLevelCodeCounts[fixture], "\(fixture)")
        for entry in prepared {
            let text = try #require(source[entry.id], "\(fixture) \(entry.id): no code node with this id")
            // The characters are the node's, scalar for scalar.
            #expect(Array(String(entry.code.characters).unicodeScalars) == Array(text.unicodeScalars), "\(fixture) \(entry.id)")
        }
    }

    @Test("every non-empty prepared code string is one uniform run: the code font, the theme's spec and the text's shape",
          arguments: fixtures)
    func oneUniformRun(fixture: String) async throws {
        let theme = ADFTheme.default
        #expect(theme.codeFontSpec == ADFFontSpec(textStyle: .body, monospaced: true))
        let (document, blocks) = try await preparedCodeFixture(fixture, theme: theme)
        var source: [String: String] = [:]
        sourceCode(under: document.root, into: &source)
        let prepared = preparedCode(in: blocks)
        #expect(!prepared.isEmpty, "\(fixture): no code prepared")
        for entry in prepared {
            let label = "\(fixture) \(entry.id)"
            let text = try #require(source[entry.id], "\(label): no code node with this id")
            // No fixture has an empty code block.
            #expect(!text.isEmpty, "\(label)")
            #expect(entry.code.runs.count == 1, "\(label): \(entry.code.runs.count) runs")
            guard let run = entry.code.runs.first else { continue }
            #expect(run.range.lowerBound == entry.code.startIndex && run.range.upperBound == entry.code.endIndex, "\(label)")
            #expect(run.attributes[SUI.FontAttribute.self] == theme.code, "\(label)")
            #expect(run.adfFontSpec == theme.codeFontSpec, "\(label)")
            #expect(run.adfCodeShape == ADFCodeShape(text), "\(label)")
        }
    }

    @Test("the stamped spec is the theme's code font spec, whatever it describes")
    func specFollowsTheme() async throws {
        let specs = [
            ADFFontSpec(textStyle: .body, monospaced: true),
            ADFFontSpec(textStyle: .footnote, bold: true, monospaced: true),
            // Not monospaced: the preparer stamps it as it is; the renderer
            // decides what it may draw.
            ADFFontSpec(textStyle: .callout),
        ]
        for spec in specs {
            let theme = ADFTheme(codeFontSpec: spec)
            #expect(theme.codeFontSpec == spec)
            let (_, blocks) = try await preparedCodeFixture("kitchen-sink", theme: theme)
            let entry = try #require(preparedCode(in: blocks).first { $0.id == "0.12" })
            #expect(entry.code.runs.count == 1, "\(spec)")
            let run = try #require(entry.code.runs.first)
            #expect(run.adfFontSpec == spec)
            #expect(run.attributes[SUI.FontAttribute.self] == Font(adfFontSpec: spec), "\(spec)")
            #expect(run.adfCodeShape == ADFCodeShape(lineCount: 2, maxLineUTF16: 28), "\(spec)")
        }
    }

    @Test("a theme whose code font is a raw Font leaves the spec out and still stamps the shape", arguments: fixtures)
    func rawCodeFontLeavesSpecNil(fixture: String) async throws {
        let theme = Self.rawCodeFontTheme
        #expect(theme.codeFontSpec == nil)
        // Only the code font is raw: body text keeps its spec.
        #expect(theme.bodyFontSpec == ADFFontSpec(textStyle: .body))
        let (document, blocks) = try await preparedCodeFixture(fixture, theme: theme)
        var source: [String: String] = [:]
        sourceCode(under: document.root, into: &source)
        let prepared = preparedCode(in: blocks)
        #expect(prepared.map(\.id) == Self.preparedCodeIDs[fixture], "\(fixture)")
        for entry in prepared {
            let label = "\(fixture) \(entry.id)"
            let text = try #require(source[entry.id], "\(label): no code node with this id")
            #expect(entry.code.runs.count == 1, "\(label): \(entry.code.runs.count) runs")
            guard let run = entry.code.runs.first else { continue }
            #expect(run.adfFontSpec == nil, "\(label)")
            #expect(run.attributes[SUI.FontAttribute.self] == theme.code, "\(label)")
            #expect(run.adfCodeShape == ADFCodeShape(text), "\(label)")
        }
    }

    @Test("without the two attributes a prepared code string is exactly the string main builds", arguments: fixtures)
    func strippedIsTheMainString(fixture: String) async throws {
        for theme in [ADFTheme.default, Self.rawCodeFontTheme] {
            let (document, blocks) = try await preparedCodeFixture(fixture, theme: theme)
            var source: [String: String] = [:]
            sourceCode(under: document.root, into: &source)
            for entry in preparedCode(in: blocks) {
                let label = "\(fixture) \(entry.id) spec \(String(describing: theme.codeFontSpec))"
                let text = try #require(source[entry.id], "\(label): no code node with this id")
                // What main prepares: the text in the theme's code font.
                var main = AttributedString(text)
                main[SUI.FontAttribute.self] = theme.code
                var stripped = entry.code
                stripped.adfFontSpec = nil
                stripped.adfCodeShape = nil
                #expect(stripped == main, "\(label)")
                // And there was a stamp to remove.
                #expect(entry.code != main, "\(label): nothing stamped")
            }
        }
    }

    @Test("an empty code block carries neither attribute; text is stamped as written, never normalised")
    func emptyNewlineOnlyAndControlText() async throws {
        let doc = try await parseDoc(#"""
        {"version":1,"type":"doc","content":[
          {"type":"codeBlock","attrs":{"language":"swift"}},
          {"type":"codeBlock","content":[{"type":"text","text":"\n"}]},
          {"type":"codeBlock","content":[{"type":"text","text":"a\tb\r\nc"}]}
        ]}
        """#)
        let theme = ADFTheme.default
        let prepared = preparedCode(in: DocumentPreparer(theme: theme).prepare(doc))
        #expect(prepared.map(\.id) == ["0.0", "0.1", "0.2"])
        guard prepared.count == 3 else { return }

        // An empty string has no run to carry an attribute: it is main's
        // empty string.
        #expect(prepared[0].language == "swift")
        #expect(prepared[0].code.runs.count == 0)
        #expect(prepared[0].code == AttributedString(""))

        // Newline-only code is not empty: one stamped run.
        #expect(String(prepared[1].code.characters) == "\n")
        #expect(prepared[1].code.runs.count == 1)
        #expect(prepared[1].code.runs.first?.adfFontSpec == theme.codeFontSpec)
        #expect(prepared[1].code.runs.first?.adfCodeShape == ADFCodeShape(
            lineCount: 2, maxLineUTF16: 0, trailingNewlineCount: 1, isAllNewlines: true
        ))

        // A tab and a CRLF stay a tab and a CRLF (no expansion, no line
        // break normalisation), and the shape says so.
        let written = "a\tb\r\nc"
        #expect(Array(String(prepared[2].code.characters).unicodeScalars) == Array(written.unicodeScalars))
        #expect(prepared[2].code.runs.count == 1)
        #expect(prepared[2].code.runs.first?.adfCodeShape == ADFCodeShape(
            lineCount: 2, maxLineUTF16: 4, isPrintableASCIIAndLF: false, hasTabs: true, hasOtherLineBreaks: true
        ))
        var main = AttributedString(written)
        main[SUI.FontAttribute.self] = theme.code
        var stripped = prepared[2].code
        stripped.adfFontSpec = nil
        stripped.adfCodeShape = nil
        #expect(stripped == main)
    }

    @Test("the shapes of named fixture blocks match hand counts from the JSON")
    func handCountedShapes() async throws {
        // Counted from the JSON: the number of lines (LF count + 1) and the
        // UTF-16 length of the longest line. All six are printable ASCII
        // and LF with no trailing newline.
        // - kitchen-sink 0.12 (swift, breakout wide): `let greeting = "Hello, ADF!"`
        //   (28) and `print(greeting)` (15).
        // - stress-1k 0.5 (swift): lines of 34, 35, 34.
        // - stress-1k 0.15 (sql): lines of 35, 35, 34, 34, 35, 37.
        // - stress-1k 0.985 (json): lines of 35, 34, 35, 35, 39.
        // - lists-parity 0.8.12.0 (swift, in a list item):
        //   `let lpCodeFirst = true // LP-CODE-FIRST` (39).
        // - lists-parity 0.10.2.1 (json, in a list item):
        //   `{"sentinel": "LP-EMBED-CODE"}` (29).
        let expected: [(fixture: String, id: String, language: String, shape: ADFCodeShape)] = [
            ("kitchen-sink", "0.12", "swift", ADFCodeShape(lineCount: 2, maxLineUTF16: 28)),
            ("stress-1k", "0.5", "swift", ADFCodeShape(lineCount: 3, maxLineUTF16: 35)),
            ("stress-1k", "0.15", "sql", ADFCodeShape(lineCount: 6, maxLineUTF16: 37)),
            ("stress-1k", "0.985", "json", ADFCodeShape(lineCount: 5, maxLineUTF16: 39)),
            ("lists-parity", "0.8.12.0", "swift", ADFCodeShape(lineCount: 1, maxLineUTF16: 39)),
            ("lists-parity", "0.10.2.1", "json", ADFCodeShape(lineCount: 1, maxLineUTF16: 29)),
        ]
        var prepared: [String: [PreparedCode]] = [:]
        for fixture in Self.fixtures {
            let blocks = try await preparedCodeFixture(fixture).blocks
            prepared[fixture] = preparedCode(in: blocks)
        }
        for pin in expected {
            let label = "\(pin.fixture) \(pin.id)"
            let entry = try #require(prepared[pin.fixture]?.first { $0.id == pin.id }, "\(label): not prepared")
            #expect(entry.language == pin.language, "\(label)")
            #expect(entry.code.runs.first?.adfCodeShape == pin.shape, "\(label)")
        }

        // kitchen-sink's code block keeps its breakout mark and language.
        let kitchenSink = try await preparedCodeFixture("kitchen-sink").blocks
        let wide = try #require(kitchenSink.first { $0.id == "0.12" })
        #expect(wide.breakout != nil)

        // stress-1k's 80 top-level blocks, as a whole: printable ASCII and
        // LF, no trailing newline, at most 8 lines of 34 to 39 columns.
        let stressCode = prepared["stress-1k"] ?? []
        let shapes = stressCode.compactMap { $0.code.runs.first?.adfCodeShape }
        #expect(shapes.count == 80)
        #expect(shapes.allSatisfy { $0.isPrintableASCIIAndLF && $0.trailingNewlineCount == 0 && !$0.isAllNewlines })
        #expect(shapes.map(\.maxLineUTF16).max() == 39)
        #expect(shapes.map(\.maxLineUTF16).min() == 34)
        #expect(shapes.map(\.lineCount).max() == 8)
    }
}

/// What `ADFCodeShape` says about a text (plan 3.1): lines split at LF only
/// and measured in UTF-16 units; newlines counted as `Character.isNewline`
/// counts them; and the four content flags a text engine decides from.
@Suite("Code shape")
struct CodeShapeTests {
    /// Derived by hand from the rules in `ADFCodeShape`'s documentation.
    static let cases: [(text: String, shape: ADFCodeShape, note: String)] = [
        // Empty and newline-only text.
        ("", ADFCodeShape(lineCount: 1, maxLineUTF16: 0), "empty: one empty line, not all newlines"),
        ("\n", ADFCodeShape(lineCount: 2, maxLineUTF16: 0, trailingNewlineCount: 1, isAllNewlines: true), "one LF"),
        ("\n\n", ADFCodeShape(lineCount: 3, maxLineUTF16: 0, trailingNewlineCount: 2, isAllNewlines: true), "two LF"),
        // Lines and trailing line feeds.
        ("a", ADFCodeShape(lineCount: 1, maxLineUTF16: 1), "one character"),
        (" ~", ADFCodeShape(lineCount: 1, maxLineUTF16: 2), "the ends of printable ASCII"),
        ("a\nbb", ADFCodeShape(lineCount: 2, maxLineUTF16: 2), "the longest line is the last"),
        ("ab\ncdef\ngh", ADFCodeShape(lineCount: 3, maxLineUTF16: 4), "the longest line is in the middle"),
        ("\na", ADFCodeShape(lineCount: 2, maxLineUTF16: 1), "a leading LF is not a trailing one"),
        ("a\n", ADFCodeShape(lineCount: 2, maxLineUTF16: 1, trailingNewlineCount: 1), "a trailing LF opens an empty last line"),
        ("a\n\n", ADFCodeShape(lineCount: 3, maxLineUTF16: 1, trailingNewlineCount: 2), "two trailing LF"),
        ("a\n\n\n", ADFCodeShape(lineCount: 4, maxLineUTF16: 1, trailingNewlineCount: 3), "three trailing LF"),
        ("a\n \n", ADFCodeShape(lineCount: 3, maxLineUTF16: 1, trailingNewlineCount: 1), "a space between LFs ends the trailing run"),
        // CR and CRLF: one newline character, but not a line split by
        // itself; the CR is a unit of its line.
        ("a\r\nb", ADFCodeShape(lineCount: 2, maxLineUTF16: 2, isPrintableASCIIAndLF: false, hasOtherLineBreaks: true), "CRLF inside"),
        ("a\r\n", ADFCodeShape(lineCount: 2, maxLineUTF16: 2, trailingNewlineCount: 1, isPrintableASCIIAndLF: false, hasOtherLineBreaks: true), "a trailing CRLF is one newline"),
        ("\r\n", ADFCodeShape(lineCount: 2, maxLineUTF16: 1, trailingNewlineCount: 1, isAllNewlines: true, isPrintableASCIIAndLF: false, hasOtherLineBreaks: true), "CRLF only"),
        ("a\rb", ADFCodeShape(lineCount: 1, maxLineUTF16: 3, isPrintableASCIIAndLF: false, hasOtherLineBreaks: true), "a lone CR splits no line"),
        ("a\r", ADFCodeShape(lineCount: 1, maxLineUTF16: 2, trailingNewlineCount: 1, isPrintableASCIIAndLF: false, hasOtherLineBreaks: true), "a trailing CR is a newline"),
        ("\r\r\n", ADFCodeShape(lineCount: 2, maxLineUTF16: 2, trailingNewlineCount: 2, isAllNewlines: true, isPrintableASCIIAndLF: false, hasOtherLineBreaks: true), "CR then CRLF: two newlines"),
        ("\n\r\n", ADFCodeShape(lineCount: 3, maxLineUTF16: 1, trailingNewlineCount: 2, isAllNewlines: true, isPrintableASCIIAndLF: false, hasOtherLineBreaks: true), "LF then CRLF: two newlines"),
        // The other line breaks.
        ("a\u{2028}b", ADFCodeShape(lineCount: 1, maxLineUTF16: 3, isPrintableASCIIAndLF: false, hasNonASCII: true, hasOtherLineBreaks: true), "U+2028 inside"),
        ("a\u{2029}", ADFCodeShape(lineCount: 1, maxLineUTF16: 2, trailingNewlineCount: 1, isPrintableASCIIAndLF: false, hasNonASCII: true, hasOtherLineBreaks: true), "a trailing U+2029"),
        ("a\u{0B}b", ADFCodeShape(lineCount: 1, maxLineUTF16: 3, isPrintableASCIIAndLF: false, hasOtherLineBreaks: true), "VT is ASCII"),
        ("a\u{0C}", ADFCodeShape(lineCount: 1, maxLineUTF16: 2, trailingNewlineCount: 1, isPrintableASCIIAndLF: false, hasOtherLineBreaks: true), "a trailing FF"),
        ("a\u{85}", ADFCodeShape(lineCount: 1, maxLineUTF16: 2, trailingNewlineCount: 1, isPrintableASCIIAndLF: false, hasNonASCII: true, hasOtherLineBreaks: true), "a trailing NEL"),
        // Tabs.
        ("\t", ADFCodeShape(lineCount: 1, maxLineUTF16: 1, isPrintableASCIIAndLF: false, hasTabs: true), "a tab is not a newline"),
        ("\tfoo", ADFCodeShape(lineCount: 1, maxLineUTF16: 4, isPrintableASCIIAndLF: false, hasTabs: true), "a tab is one unit"),
        ("a\tb\n\tc", ADFCodeShape(lineCount: 2, maxLineUTF16: 3, isPrintableASCIIAndLF: false, hasTabs: true), "tabs on two lines"),
        // Beyond ASCII: UTF-16 units, not characters.
        ("\u{E9}", ADFCodeShape(lineCount: 1, maxLineUTF16: 1, isPrintableASCIIAndLF: false, hasNonASCII: true), "precomposed e-acute"),
        ("e\u{301}", ADFCodeShape(lineCount: 1, maxLineUTF16: 2, isPrintableASCIIAndLF: false, hasNonASCII: true), "e and a combining acute: two units"),
        ("\u{1F600}", ADFCodeShape(lineCount: 1, maxLineUTF16: 2, isPrintableASCIIAndLF: false, hasNonASCII: true), "an emoji is a surrogate pair"),
        ("a\u{1F600}\nbc", ADFCodeShape(lineCount: 2, maxLineUTF16: 3, isPrintableASCIIAndLF: false, hasNonASCII: true), "an emoji on the longest line"),
        // Other control characters: not printable, and none of the flags.
        ("a\u{0}b", ADFCodeShape(lineCount: 1, maxLineUTF16: 3, isPrintableASCIIAndLF: false), "NUL"),
        ("\u{1F}", ADFCodeShape(lineCount: 1, maxLineUTF16: 1, isPrintableASCIIAndLF: false), "U+001F, just below printable ASCII"),
        ("a\u{7F}", ADFCodeShape(lineCount: 1, maxLineUTF16: 2, isPrintableASCIIAndLF: false), "DEL, just above it"),
        // Every flag at once.
        ("\t\r\u{E9}", ADFCodeShape(lineCount: 1, maxLineUTF16: 3, isPrintableASCIIAndLF: false, hasTabs: true, hasNonASCII: true, hasOtherLineBreaks: true), "tab, CR and e-acute"),
    ]

    static func scalars(_ text: String) -> String {
        text.unicodeScalars.map { "U+" + String($0.value, radix: 16, uppercase: true) }.joined(separator: " ")
    }

    @Test("empty, newline-only, LF, CRLF, CR, U+2028, U+2029, tabs, non-ASCII and trailing newlines")
    func semantics() {
        for item in Self.cases {
            #expect(ADFCodeShape(item.text) == item.shape, "\(item.note) [\(Self.scalars(item.text))]: \(ADFCodeShape(item.text))")
        }
    }

    @Test("the memberwise initialiser defaults describe plain printable text")
    func memberwiseDefaults() {
        let shape = ADFCodeShape(lineCount: 3, maxLineUTF16: 7)
        #expect(shape.lineCount == 3 && shape.maxLineUTF16 == 7)
        #expect(shape.trailingNewlineCount == 0)
        #expect(!shape.isAllNewlines)
        #expect(shape.isPrintableASCIIAndLF)
        #expect(!shape.hasTabs && !shape.hasNonASCII && !shape.hasOtherLineBreaks)
        #expect(shape == ADFCodeShape("abcdefg\nab\ncd"))
    }

    /// The same facts from a plain scan of the string, each by its own
    /// definition: UTF-16 line lengths from a split at LF, the newline facts
    /// from `Character.isNewline`, the flags from the scalars.
    static func scanned(_ text: String) -> ADFCodeShape {
        let lines = text.utf16.split(separator: 0x0A, omittingEmptySubsequences: false)
        let printable: ClosedRange<UInt32> = 0x20...0x7E
        let otherBreaks: Set<UInt32> = [0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029]
        let values = text.unicodeScalars.map(\.value)
        let lengths = lines.map(\.count)
        let trailing = text.reversed().prefix(while: \.isNewline).count
        let allNewlines = !text.isEmpty && text.allSatisfy(\.isNewline)
        return ADFCodeShape(
            lineCount: lines.count,
            maxLineUTF16: lengths.max() ?? 0,
            trailingNewlineCount: trailing,
            isAllNewlines: allNewlines,
            isPrintableASCIIAndLF: values.allSatisfy { $0 == 0x0A || printable.contains($0) },
            hasTabs: values.contains(0x09),
            hasNonASCII: values.contains { $0 > 0x7F },
            hasOtherLineBreaks: values.contains { otherBreaks.contains($0) }
        )
    }

    static let alphabet: [Unicode.Scalar] = [
        "a", " ", "~", "\n", "\r", "\t", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}",
        "\u{E9}", "\u{301}", "\u{1F600}", "\u{0}", "\u{7F}",
    ]

    /// Every string of up to `length` scalars of `alphabet`.
    static func strings(upTo length: Int) -> [String] {
        var all = [""]
        var previous = [""]
        for _ in 0..<length {
            var next: [String] = []
            for prefix in previous {
                for scalar in alphabet {
                    var view = prefix.unicodeScalars
                    view.append(scalar)
                    next.append(String(view))
                }
            }
            all += next
            previous = next
        }
        return all
    }

    @Test("the one-pass measurement agrees with a plain scan for every string of up to three scalars of sixteen kinds")
    func agreesWithAScan() {
        let corpus = Self.strings(upTo: 3) + Self.cases.map { $0.text }
        #expect(corpus.count == 1 + 16 + 256 + 4_096 + Self.cases.count)
        var mismatches: [String] = []
        for text in corpus where ADFCodeShape(text) != Self.scanned(text) {
            mismatches.append("[\(Self.scalars(text))]: \(ADFCodeShape(text)) vs scan \(Self.scanned(text))")
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches, first: \(mismatches.prefix(3))")
    }

    @Test("the hand-derived table agrees with the scan too")
    func tableAgreesWithAScan() {
        for item in Self.cases {
            #expect(Self.scanned(item.text) == item.shape, "\(item.note) [\(Self.scalars(item.text))]: scan \(Self.scanned(item.text))")
        }
    }
}
