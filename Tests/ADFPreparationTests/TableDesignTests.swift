import Foundation
import Testing
import ADFModel
import ADFPreparation

/// The Direction A table look's pure geometry (ADF-TBL1 B1a): rowspan
/// placement, numeric columns, content-aware widths and the header-column
/// pin decision — plus the per-table layout the preparer derives from them.
@Suite("Table design")
struct TableDesignTests {
    private let preparer = DocumentPreparer(theme: .default)

    // MARK: - JSON helpers

    private func cell(_ text: String, header: Bool = false, attrs: String? = nil) -> String {
        let type = header ? "tableHeader" : "tableCell"
        let attrsJSON = attrs.map { ",\"attrs\":{\($0)}" } ?? ""
        let content = text.isEmpty
            ? "[]"
            : "[{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"\(text)\"}]}]"
        return "{\"type\":\"\(type)\"\(attrsJSON),\"content\":\(content)}"
    }

    private func row(_ cells: [String]) -> String {
        "{\"type\":\"tableRow\",\"content\":[\(cells.joined(separator: ","))]}"
    }

    private func tableDoc(_ rows: [String], tableAttrs: String? = nil) async throws -> ADFDocument {
        let attrs = tableAttrs.map { ",\"attrs\":{\($0)}" } ?? ""
        return try await parseDoc("""
        {"version":1,"type":"doc","content":[
          {"type":"table"\(attrs),"content":[\(rows.joined(separator: ","))]}
        ]}
        """)
    }

    private func slices(_ doc: ADFDocument) -> [(id: String, layout: PreparedTableLayout, rows: [PreparedTableRow], isHeader: Bool)] {
        preparer.prepare(doc).compactMap { block in
            guard case .tableSlice(let layout, let rows, let isHeader) = block.kind else { return nil }
            return (block.id, layout, rows, isHeader)
        }
    }

    private func spans(_ rows: [[(Int, Int)]]) -> [[TableCellSpan]] {
        rows.map { $0.map { TableCellSpan(colspan: $0.0, rowspan: $0.1) } }
    }

    // MARK: - Rowspan placement

    @Test("a rowspan reserves its column so later rows' cells land under their own headers")
    func rowspanReservesCoveredColumns() throws {
        // A spans rows 0–1 in column 0; row 1's two cells belong in 1 and 2.
        let placement = TableGridPlacement.place(spans([
            [(1, 2), (1, 1), (1, 1)],
            [(1, 1), (1, 1)],
        ]))
        #expect(placement.cellColumns == [[0, 1, 2], [1, 2]])
        #expect(placement.columnCount == 3)
        #expect(placement.continuations[0].isEmpty)
        let covered = try #require(placement.continuations[1].first)
        #expect(covered.column == 0)
        #expect(covered.originRow == 0)
        #expect(covered.originCell == 0)
        #expect(covered.continuesBelow == false)
    }

    @Test("a middle-column rowspan with colspan covers every spanned position, and spans clamp to the table")
    func middleRowspanWithColspan() {
        let placement = TableGridPlacement.place(spans([
            [(1, 1), (2, 3), (1, 1)],
            [(1, 1), (1, 1)],
            [(1, 1), (1, 1)],
            [(1, 1), (1, 1), (1, 1), (1, 1)],
        ]))
        #expect(placement.cellColumns[1] == [0, 3])
        #expect(placement.cellColumns[2] == [0, 3])
        #expect(placement.cellColumns[3] == [0, 1, 2, 3])
        #expect(placement.continuations[1].map(\.column) == [1])
        #expect(placement.continuations[1].map(\.colspan) == [2])
        #expect(placement.continuations[1].map(\.continuesBelow) == [true])
        #expect(placement.continuations[2].map(\.continuesBelow) == [false])
        #expect(placement.continuations[3].isEmpty)

        let clamped = TableGridPlacement.place(spans([[(1, 9), (1, 1)], [(1, 1)]]))
        #expect(clamped.rowspans == [[2, 1], [1]])
        #expect(clamped.cellColumns == [[0, 1], [1]])
    }

    @Test("rowspan placement survives the 2-row slice boundary")
    func rowspanAcrossSlices() async throws {
        let doc = try await tableDoc([
            row([cell("Region", header: true), cell("Q1", header: true), cell("Q2", header: true)]),
            row([cell("North", attrs: "\"rowspan\":3"), cell("1"), cell("2")]),
            row([cell("3"), cell("4")]),
            row([cell("5"), cell("6")]),
            row([cell("South"), cell("7"), cell("8")]),
        ])
        let tableSlices = slices(doc)
        #expect(tableSlices.map(\.isHeader) == [true, false, false])
        let bodyRows = tableSlices.filter { !$0.isHeader }.flatMap(\.rows)
        #expect(bodyRows.map(\.index) == [1, 2, 3, 4])

        // Row 3 lives in the second row slice, yet still skips column 0.
        #expect(bodyRows[0].cellColumns == [0, 1, 2])
        #expect(bodyRows[0].cells.first?.rowspan == 3)
        #expect(bodyRows[1].cellColumns == [1, 2])
        #expect(bodyRows[1].continuations.map(\.column) == [0])
        #expect(bodyRows[1].continuations.map(\.continuesBelow) == [true])
        #expect(bodyRows[2].cellColumns == [1, 2])
        #expect(bodyRows[2].continuations.map(\.continuesBelow) == [false])
        #expect(bodyRows[2].continuations.first?.originRow == 1)
        #expect(bodyRows[3].cellColumns == [0, 1, 2])
        #expect(bodyRows[3].continuations.isEmpty)

        let layout = try #require(tableSlices.first).layout
        #expect(layout.columnCount == 3)
        #expect(layout.rowCount == 5)
        #expect(layout.hasHeaderRow)
        #expect(tableSlices.allSatisfy { $0.layout == layout })
    }

    // MARK: - Numeric columns

    @Test("numbers and percentages read as numeric; text, ranges and bare signs do not")
    func numericPattern() {
        for text in ["1,234", "-5", "\u{2212}3.5", "+12%", "45%", " 0.75 ", "1.000.000"] {
            #expect(TableColumnAnalysis.isNumeric(text), "\(text)")
        }
        for text in ["", "abc", "1-2", ".", "-", "%", "12 kg", "$5", "1e5", "v2"] {
            #expect(!TableColumnAnalysis.isNumeric(text), "\(text)")
        }
    }

    @Test("a column is numeric only when every non-empty single-column body cell is a number")
    func numericColumnDetection() {
        let cells: [TableColumnAnalysis.Cell] = [
            // Column 0: all numbers under a text header; one empty cell.
            .init(column: 0, colspan: 1, isHeader: true, lines: ["Total"]),
            .init(column: 0, colspan: 1, isHeader: false, lines: ["12"]),
            .init(column: 0, colspan: 1, isHeader: false, lines: [""]),
            .init(column: 0, colspan: 1, isHeader: false, lines: ["7.5%"]),
            // Column 1: one text cell breaks it.
            .init(column: 1, colspan: 1, isHeader: false, lines: ["3"]),
            .init(column: 1, colspan: 1, isHeader: false, lines: ["n/a"]),
            // Column 2: only empty and header cells — not numeric.
            .init(column: 2, colspan: 1, isHeader: true, lines: ["42"]),
            .init(column: 2, colspan: 1, isHeader: false, lines: [String]()),
            // Column 3: a number spanning columns 3–4 is ignored; col 3 has
            // a real number, col 4 nothing.
            .init(column: 3, colspan: 2, isHeader: false, lines: ["text"]),
            .init(column: 3, colspan: 1, isHeader: false, lines: ["9"]),
            // Column 5: two paragraphs is not one number.
            .init(column: 5, colspan: 1, isHeader: false, lines: ["1", "2"]),
        ]
        let analysis = TableColumnAnalysis.analyze(
            cells: cells, columnCount: 6, padding: 20, maxAdvancePerCharacter: 100,
            measure: { Double($0.text.count) * 10 }
        )
        #expect(analysis.numericColumns == [true, false, false, true, false, false])
    }

    @Test("the preparer trailing-aligns numeric columns' paragraphs, header included")
    func numericColumnsAlignTrailing() async throws {
        let doc = try await tableDoc([
            row([cell("Item", header: true), cell("Cost", header: true)]),
            row([cell("Apples"), cell("1,200")]),
            row([cell("Pears"), cell("-3.5")]),
        ])
        let tableSlices = slices(doc)
        let layout = try #require(tableSlices.first).layout
        #expect(layout.numericColumns == [false, true])

        func alignment(_ cell: PreparedTableCell) -> ADFAlignment? {
            guard case .richText(_, let style) = cell.blocks.first?.kind else { return nil }
            return style.alignment
        }
        let allRows = tableSlices.flatMap(\.rows)
        #expect(allRows.map { alignment($0.cells[0]) } == [nil, nil, nil])
        #expect(allRows.map { alignment($0.cells[1]) } == [.end, .end, .end])
    }

    // MARK: - Content-aware widths

    @Test("natural width is the widest single-column line plus padding, headers measured semibold")
    func naturalWidthAnalysis() {
        let cells: [TableColumnAnalysis.Cell] = [
            .init(column: 0, colspan: 1, isHeader: true, lines: ["Name"]),
            .init(column: 0, colspan: 1, isHeader: false, lines: ["abc"]),
            .init(column: 1, colspan: 1, isHeader: false, lines: ["short", "a longer line"]),
            .init(column: 0, colspan: 2, isHeader: false, lines: ["ignored because it spans two columns"]),
        ]
        let analysis = TableColumnAnalysis.analyze(
            cells: cells, columnCount: 3, padding: 20, maxAdvancePerCharacter: 12,
            measure: { Double($0.text.count) * ($0.isSemibold ? 12 : 10) }
        )
        // "Name" semibold 48 > "abc" 30; "a longer line" 130; column 2 empty.
        #expect(analysis.naturalWidths == [68, 150, 0])
        #expect(analysis.samples[0].first == PreparedTableColumnSample(text: "Name", isSemibold: true))
        #expect(analysis.samples[1].first?.text == "a longer line")
        #expect(analysis.samples[2].isEmpty)
    }

    @Test("width scanning stops early without changing the result")
    func naturalWidthPruning() {
        var measured = 0
        let cells = (0..<500).map { index in
            TableColumnAnalysis.Cell(column: 0, colspan: 1, isHeader: false, lines: [index == 0 ? "widest cell" : "x\(index)"])
        }
        let analysis = TableColumnAnalysis.analyze(
            cells: cells, columnCount: 1, padding: 20, maxAdvancePerCharacter: 10,
            measure: { measured += 1; return Double($0.text.count) * 10 }
        )
        #expect(analysis.naturalWidths == [130])
        #expect(measured < 10)
    }

    @Test("columns clamp to 72–240 pt, scaled with the body text size")
    func widthClampsAndDynamicType() {
        let base = TableColumnSizing.columnWidths(
            natural: [10, 120, 900], numeric: [], authored: nil, columnCount: 3, availableWidth: 0, scale: 1
        )
        #expect(base == [72, 120, 240])

        // At 2× body size the clamps double; a natural width measured at the
        // larger size sits between them untouched.
        let large = TableColumnSizing.columnWidths(
            natural: [10, 200, 900], numeric: [], authored: nil, columnCount: 3, availableWidth: 0, scale: 2
        )
        #expect(large == [144, 200, 480])

        // Missing measurements (a layout built without them) sit at the floor.
        let unmeasured = TableColumnSizing.columnWidths(
            natural: [], numeric: [], authored: nil, columnCount: 2, availableWidth: 0, scale: 1
        )
        #expect(unmeasured == [72, 72])
    }

    @Test("spare width goes to non-numeric columns in proportion; numeric columns stay natural")
    func spareWidthDistribution() {
        let widths = TableColumnSizing.columnWidths(
            natural: [100, 100, 80], numeric: [false, false, true], authored: nil,
            columnCount: 3, availableWidth: 480, scale: 1
        )
        #expect(widths == [200, 200, 80])

        let proportional = TableColumnSizing.columnWidths(
            natural: [100, 200], numeric: [], authored: nil, columnCount: 2, availableWidth: 600, scale: 1
        )
        #expect(proportional == [200, 400])

        // Only numeric columns: the table still fills the width.
        let allNumeric = TableColumnSizing.columnWidths(
            natural: [100, 100], numeric: [true, true], authored: nil, columnCount: 2, availableWidth: 400, scale: 1
        )
        #expect(allNumeric == [200, 200])

        // Wider than the container: no shrinking, the table scrolls.
        let wide = TableColumnSizing.columnWidths(
            natural: [240, 240], numeric: [], authored: nil, columnCount: 2, availableWidth: 300, scale: 1
        )
        #expect(wide == [240, 240])
    }

    @Test("authored colwidths for every column win, unscaled and undistributed")
    func colwidthPrecedence() {
        let authored = TableColumnSizing.columnWidths(
            natural: [500, 10], numeric: [true, false], authored: [160, 90],
            columnCount: 2, availableWidth: 1000, scale: 2
        )
        #expect(authored == [160, 90])

        // A partial set (wrong count) is not authored: content-aware widths.
        let partial = TableColumnSizing.columnWidths(
            natural: [100, 100], numeric: [], authored: [160], columnCount: 2, availableWidth: 0, scale: 1
        )
        #expect(partial == [100, 100])
    }

    @Test("the preparer measures real text: a longer column is naturally wider")
    func preparerMeasuresNaturalWidths() async throws {
        let doc = try await tableDoc([
            row([cell("A", header: true), cell("A much longer header label", header: true)]),
            row([cell("x"), cell("y")]),
        ])
        let layout = try #require(slices(doc).first).layout
        #expect(layout.columnWidths == nil)
        #expect(layout.naturalColumnWidths.count == 2)
        let narrow = layout.naturalColumnWidths[0]
        let wide = layout.naturalColumnWidths[1]
        #expect(narrow >= 20)
        #expect(wide > narrow + 100)
        #expect(layout.columnSamples[1].first?.isSemibold == true)
    }

    /// Natural widths of a one-row table whose cells hold the given ADF
    /// block content JSON.
    private func naturalWidths(ofCellContents contents: [String]) async throws -> [Double] {
        let cells = contents.map { "{\"type\":\"tableCell\",\"content\":[\($0)]}" }
        let doc = try await tableDoc([row(cells)])
        return try #require(slices(doc).first).layout.naturalColumnWidths
    }

    private func paragraph(_ inline: String) -> String {
        "{\"type\":\"paragraph\",\"content\":[\(inline)]}"
    }

    private func text(_ value: String, marks: String? = nil) -> String {
        let marksJSON = marks.map { ",\"marks\":[\($0)]" } ?? ""
        return "{\"type\":\"text\",\"text\":\"\(value)\"\(marksJSON)}"
    }

    @Test("a list row's natural width includes its marker columns")
    func listRowsIncludeMarkerColumns() async throws {
        let item = "{\"type\":\"listItem\",\"content\":[\(paragraph(text("Ship by Friday")))]}"
        let nestedItem = "{\"type\":\"listItem\",\"content\":[\(paragraph(text("x"))),"
            + "{\"type\":\"bulletList\",\"content\":[\(item)]}]}"
        let widths = try await naturalWidths(ofCellContents: [
            paragraph(text("Ship by Friday")),
            "{\"type\":\"bulletList\",\"content\":[\(item)]}",
            "{\"type\":\"bulletList\",\"content\":[\(nestedItem)]}",
        ])
        let marker = TableColumnSizing.listMarkerWidth + Double(ADFTheme.default.spacing)
        #expect(widths[1] >= widths[0] + marker)
        #expect(widths[2] >= widths[0] + 2 * marker)
    }

    @Test("bold, code and chip runs measure as wide as they render")
    func styledRunsMeasureWider() async throws {
        let label = "Quarterly revenue total"
        let widths = try await naturalWidths(ofCellContents: [
            paragraph(text(label)),
            paragraph(text(label, marks: "{\"type\":\"strong\"}")),
            paragraph(text(label, marks: "{\"type\":\"code\"}")),
            paragraph("{\"type\":\"status\",\"attrs\":{\"text\":\"\(label)\",\"color\":\"green\"}}"),
        ])
        #expect(widths[1] > widths[0])
        #expect(widths[2] > widths[0])
        #expect(widths[3] >= widths[0] + TableColumnSizing.atomPadding)
    }

    @Test("re-measuring at a larger type size scales list insets with it")
    func measurerScalesInsets() {
        let line = PreparedTableColumnSample(text: "Ship", isSemibold: false, scaledInset: 28, fixedInset: 8)
        let plain = PreparedTableColumnSample(text: "Ship", isSemibold: false)
        let base = TableTextMeasurer(pointSize: 17)
        let large = TableTextMeasurer(pointSize: 34, insetScale: 2)
        #expect(abs(base.width(of: line) - (base.width(of: plain) + 28 + 8)) < 0.001)
        #expect(abs(large.width(of: line) - (large.width(of: plain) + 56 + 8)) < 0.001)
    }

    // MARK: - Header column pinning

    @Test("pin only when the table scrolls, has a header column and the first column is ≤ 40%")
    func pinDecision() {
        // Scrolls (500 > 375), header column, 100 ≤ 150.
        #expect(TableColumnSizing.pinsHeaderColumn(
            columnWidths: [100, 200, 200], gutterWidth: 0, containerWidth: 375, hasHeaderColumn: true
        ))
        // Fits: no pin.
        #expect(!TableColumnSizing.pinsHeaderColumn(
            columnWidths: [100, 150, 125], gutterWidth: 0, containerWidth: 375, hasHeaderColumn: true
        ))
        // No header column: no pin.
        #expect(!TableColumnSizing.pinsHeaderColumn(
            columnWidths: [100, 200, 200], gutterWidth: 0, containerWidth: 375, hasHeaderColumn: false
        ))
        // First column wider than 40 % of the width: no pin.
        #expect(!TableColumnSizing.pinsHeaderColumn(
            columnWidths: [200, 300], gutterWidth: 0, containerWidth: 375, hasHeaderColumn: true
        ))
        // The number gutter counts toward scrolling and comes off the
        // available width: 44 + 340 > 375; 100 ≤ 0.4 × 331.
        #expect(TableColumnSizing.pinsHeaderColumn(
            columnWidths: [100, 240], gutterWidth: 44, containerWidth: 375, hasHeaderColumn: true
        ))
        // Before the first width observation nothing pins.
        #expect(!TableColumnSizing.pinsHeaderColumn(
            columnWidths: [100, 200], gutterWidth: 0, containerWidth: 0, hasHeaderColumn: true
        ))
    }

    @Test("a header column needs every body row's first cell to be a header cell")
    func headerColumnDetection() async throws {
        let withColumn = try await tableDoc([
            row([cell("", header: true), cell("Mon", header: true), cell("Tue", header: true)]),
            row([cell("Alice", header: true), cell("1"), cell("2")]),
            row([cell("Bob", header: true), cell("3"), cell("4")]),
        ])
        let layout = try #require(slices(withColumn).first).layout
        #expect(layout.hasHeaderRow)
        #expect(layout.hasHeaderColumn)

        let broken = try await tableDoc([
            row([cell("", header: true), cell("Mon", header: true)]),
            row([cell("Alice", header: true), cell("1")]),
            row([cell("Bob"), cell("3")]),
        ])
        #expect(try #require(slices(broken).first).layout.hasHeaderColumn == false)

        // A rowspanning header cell covers column 0 for the rows below it.
        let spanned = try await tableDoc([
            row([cell("Team", header: true, attrs: "\"rowspan\":2"), cell("1")]),
            row([cell("2")]),
        ])
        #expect(try #require(slices(spanned).first).layout.hasHeaderColumn)

        // A column-0 cell spanning two columns can't pin as column 0.
        let wideFirst = try await tableDoc([
            row([cell("Wide", header: true, attrs: "\"colspan\":2"), cell("x")]),
            row([cell("Alice", header: true), cell("1"), cell("2")]),
        ])
        #expect(try #require(slices(wideFirst).first).layout.hasHeaderColumn == false)
    }

    // MARK: - Demo fixture

    /// Rows of each table in `Fixtures/table-design.json`, in document
    /// order, rebuilt from its slices (a table ends once its slices hold
    /// `layout.rowCount` rows).
    private func fixtureTables() async throws -> [(layout: PreparedTableLayout, rows: [PreparedTableRow])] {
        let doc = try await ADFParser().parse(try fixtureData("table-design.json"))
        var tables: [(layout: PreparedTableLayout, rows: [PreparedTableRow])] = []
        var current: [PreparedTableRow] = []
        for slice in slices(doc) {
            current += slice.rows
            if current.count == slice.layout.rowCount {
                tables.append((slice.layout, current))
                current = []
            }
        }
        #expect(current.isEmpty, "a table's slices did not add up to its row count")
        return tables
    }

    @Test("table-design fixture: release table merges its rowspan and keeps later cells under their headers")
    func fixtureReleaseTable() async throws {
        let tables = try await fixtureTables()
        try #require(tables.count == 2)
        let (layout, rows) = tables[0]
        #expect(layout.columnCount == 5)
        #expect(layout.rowCount == 6)
        #expect(layout.hasHeaderRow)
        #expect(layout.hasHeaderColumn)
        #expect(layout.columnWidths == nil)
        // Only "Open bugs" is numeric (the API row's colspan cell is ignored).
        #expect(layout.numericColumns == [false, false, false, true, false])
        // Web: Sam Okafor spans two rows from column 1.
        #expect(rows[3].cellColumns == [0, 1, 2, 3, 4])
        #expect(rows[3].cells[1].rowspan == 2)
        // API: column 1 is the continuation; the colspan cell starts at
        // Status (2) and the empty Notes cell lands in column 4.
        #expect(rows[4].cellColumns == [0, 2, 4])
        #expect(rows[4].continuations.map(\.column) == [1])
        #expect(rows[4].continuations.first?.originRow == 3)
        #expect(rows[4].cells[1].colspan == 2)
        // Docs row is back to five cells in order.
        #expect(rows[5].cellColumns == [0, 1, 2, 3, 4])
    }

    @Test("table-design fixture: metrics table is numeric past the city column and pins it only when it scrolls")
    func fixtureMetricsTable() async throws {
        let tables = try await fixtureTables()
        try #require(tables.count == 2)
        let layout = tables[1].layout
        #expect(layout.columnCount == 9)
        #expect(layout.rowCount == 18)
        #expect(layout.hasHeaderRow)
        #expect(layout.hasHeaderColumn)
        #expect(layout.numericColumns == [false] + Array(repeating: true, count: 8))

        func resolved(_ width: Double) -> [Double] {
            TableColumnSizing.columnWidths(
                natural: layout.naturalColumnWidths,
                numeric: layout.numericColumns,
                authored: layout.columnWidths,
                columnCount: layout.columnCount,
                availableWidth: width,
                scale: 1
            )
        }
        // Phone width: wider than the slice, city column ≤ 40 % → pinned.
        let phone = resolved(370)
        #expect(phone.reduce(0, +) > 370)
        #expect(TableColumnSizing.pinsHeaderColumn(
            columnWidths: phone, gutterWidth: 0, containerWidth: 370, hasHeaderColumn: layout.hasHeaderColumn
        ))
        // Wide iPad width: it fits, so nothing pins.
        let wide = resolved(1_200)
        #expect(!TableColumnSizing.pinsHeaderColumn(
            columnWidths: wide, gutterWidth: 0, containerWidth: 1_200, hasHeaderColumn: layout.hasHeaderColumn
        ))
    }
}
