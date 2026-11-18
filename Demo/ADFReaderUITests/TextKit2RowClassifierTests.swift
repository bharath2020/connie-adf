import XCTest

/// Offline checks of the lifecycle census's row classifier (PR 4 plan
/// §6.5, `TextKit2RowCensus` in LifecycleSupport.swift): no app launch and
/// no host agent, like `LifecycleSupportTests`. The classifier replaces
/// PR 3's subtraction (list rows = all − root − code), which would count a
/// container or caption row as a list row.
final class TextKit2RowClassifierTests: XCTestCase {
    private func census(_ rows: [(String, Bool)], table: RowOwnerTable? = nil,
                        fixture: String = "fixture") -> TextKit2RowCensus
    {
        TextKit2RowCensus(rows: rows.map { (owner: $0.0, inNestedScroll: $0.1) }, fixture: fixture, table: table)
    }

    /// Without an owner table the census means what PR 3's did: code is a
    /// row in a nested scroll view, root a root-form owner, list the rest.
    func testWithoutATableTheClassesAreThePR3Split() {
        let rows = [("0.12", true), ("0.3", false), ("0.5.0", false), ("0.5.0#cont1", false), ("0.5.1", false)]
        let result = census(rows)
        XCTAssertEqual(result.owners(.code), ["0.12"])
        XCTAssertEqual(result.owners(.root), ["0.3"])
        XCTAssertEqual(result.owners(.list), ["0.5.0", "0.5.0#cont1", "0.5.1"])
        XCTAssertEqual(result.count(.container) + result.count(.caption), 0)
        XCTAssertEqual(result.unclassified, [])
        XCTAssertNil(result.tableFixture)
        // PR 3's subtraction on the same rows.
        let rootForm = rows.filter { TextKit2RowCensus.isRootOwner($0.0) }
        let code = rows.filter { $0.1 && TextKit2RowCensus.isRootOwner($0.0) }.count
        XCTAssertEqual(result.count(.root), rootForm.count - code)
        XCTAssertEqual(result.count(.list), rows.count - (rootForm.count - code) - code)
    }

    /// PR 3 required a root-form owner for a code row; a nested code block
    /// (PR 4 step 7) has a node path and is still code.
    func testNestedCodeIsCodeWhateverItsOwner() {
        let result = census([("0.31.1", true), ("0.30.0.1", true), ("0.31.0", false)])
        XCTAssertEqual(result.owners(.code), ["0.30.0.1", "0.31.1"])
        XCTAssertEqual(result.owners(.list), ["0.31.0"])
    }

    /// With a table every row gets its class, and a row the table does not
    /// place is reported, never folded into the list class.
    func testOwnerTableClassifiesEveryRow() {
        let table = RowOwnerTable(container: ["0.4", "0.7"], containerList: ["0.7.2"], caption: ["0.9.0"],
                                  list: ["0.5"])
        let result = census([
            ("0.3", false), ("0.4.0", false), ("0.4.1", false), ("0.7.2.0", false), ("0.7.2.0#cont1", false),
            ("0.9.0", false), ("0.5.0", false), ("0.5.1#cont1", false), ("0.6.0", false), ("0.31.1", true),
        ], table: table, fixture: "containers-parity")
        XCTAssertEqual(result.owners(.root), ["0.3"])
        XCTAssertEqual(result.owners(.container), ["0.4.0", "0.4.1", "0.7.2.0", "0.7.2.0#cont1"])
        XCTAssertEqual(result.containerListOwners, ["0.7.2.0", "0.7.2.0#cont1"])
        XCTAssertEqual(result.owners(.caption), ["0.9.0"])
        XCTAssertEqual(result.owners(.list), ["0.5.0", "0.5.1#cont1"])
        XCTAssertEqual(result.owners(.code), ["0.31.1"])
        XCTAssertEqual(result.unclassified, ["0.6.0"])
        XCTAssertEqual(result.tableFixture, "containers-parity")
        // Exactly one class per owner.
        XCTAssertEqual(TextKit2RowClass.allCases.map(result.count).reduce(0, +) + result.unclassified.count, 10)
    }

    /// A table that leaves `list` nil sends every row it does not place to
    /// the list class.
    func testTableWithoutListsLeavesTheRestToLists() {
        let result = census([("0.4.0", false), ("0.6.0", false)], table: RowOwnerTable(container: ["0.4"]))
        XCTAssertEqual(result.owners(.container), ["0.4.0"])
        XCTAssertEqual(result.owners(.list), ["0.6.0"])
        XCTAssertEqual(result.unclassified, [])
    }

    /// Prefixes match whole node-path components: 0.4 is not 0.40.
    func testPrefixesMatchWholeComponents() {
        XCTAssertTrue(RowOwnerTable.covers(["0.4"], "0.4"))
        XCTAssertTrue(RowOwnerTable.covers(["0.4"], "0.4.0.1"))
        XCTAssertTrue(RowOwnerTable.covers(["0.4.0"], "0.4.0#cont2"))
        XCTAssertFalse(RowOwnerTable.covers(["0.4"], "0.40.0"))
        XCTAssertFalse(RowOwnerTable.covers(["0.4.1"], "0.4.10"))
        let result = census([("0.40.0", false)], table: RowOwnerTable(container: ["0.4"], list: []))
        XCTAssertEqual(result.unclassified, ["0.40.0"])
    }

    /// A root-form owner is root, even if a table names its block.
    func testRootFormOwnersAreRoot() {
        XCTAssertTrue(TextKit2RowCensus.isRootOwner("0.12"))
        XCTAssertFalse(TextKit2RowCensus.isRootOwner("0.12.0"))
        XCTAssertFalse(TextKit2RowCensus.isRootOwner("1.2"))
        XCTAssertFalse(TextKit2RowCensus.isRootOwner("0.x"))
        let result = census([("0.4", false)], table: RowOwnerTable(container: ["0.4"], list: []))
        XCTAssertEqual(result.owners(.root), ["0.4"])
    }

    /// The cross-check against the live counters (§6.5), census-only (call
    /// C22): each class at most its counter, never required equal, even
    /// with no row off-window; nested-list rows of the container class
    /// count toward the list counter; the census rows plus the off-window
    /// rows fit in tk2Live.
    func testCrossCheckAgainstTheLiveCounters() {
        let table = RowOwnerTable(container: ["0.4", "0.7"], containerList: ["0.7.2"], caption: ["0.9.0"], list: ["0.5"])
        let result = census([("0.4.0", false), ("0.7.2.0", false), ("0.9.0", false), ("0.5.0", false),
                             ("0.12", true)], table: table)
        XCTAssertEqual(result.rows, 5)
        let equal = LiveRowCounters(list: 2, code: 1, container: 2, caption: 1, offWindow: 0, total: 5)
        XCTAssertEqual(result.crossCheck(equal), [])
        // C22: a live container row with a window outside the census (the
        // lazy stack keeps it beyond the viewport) passes with 0 off-window.
        var more = equal
        more.container = 3
        more.total = 6
        XCTAssertEqual(result.crossCheck(more), [])
        more.offWindow = 1
        XCTAssertEqual(result.crossCheck(more), [])
        var fewer = equal
        fewer.list = 1   // the list row and the nested-list container row need 2
        XCTAssertEqual(result.crossCheck(fewer), ["list (with nested-list container rows): census 2 > live 1"])
        // An off-window count above the live rows outside the census.
        var over = more
        over.offWindow = 2
        XCTAssertEqual(result.crossCheck(over), ["census 5 + off-window 2 > live 6"])
        var missing = equal
        missing.caption = nil
        missing.offWindow = nil
        missing.total = nil
        XCTAssertEqual(result.crossCheck(missing), ["tk2-live-rows unavailable", "tk2-offwindow-rows unavailable",
                                                    "caption: live counter unavailable (census 1)"])
        let stray = census([("0.6.0", false)], table: RowOwnerTable(list: []), fixture: "containers-dense")
        XCTAssertEqual(stray.crossCheck(LiveRowCounters(list: 0, code: 0, container: 0, caption: 0, offWindow: 0,
                                                        total: 1)),
                       ["unclassified TextKit 2 rows (owner table: containers-dense): 0.6.0"])
        XCTAssertEqual(stray.crossCheck(LiveRowCounters(list: 0, code: 0, container: 0, caption: 0, offWindow: 1,
                                                        total: 1)),
                       ["unclassified TextKit 2 rows (owner table: containers-dense): 0.6.0",
                        "census 1 + off-window 1 > live 1"])
    }

    /// A table's `root` owners (a sync block's children, emitted as
    /// top-level blocks) are root rows, exactly and with their `#`
    /// continuations; anything below them is not.
    func testRootExtrasAreRoot() {
        let table = RowOwnerTable(container: ["0.4"], list: ["0.84"], root: ["0.43.0"])
        let result = census([("0.43.0", false), ("0.43.0#cont1", false), ("0.43.0.1", false), ("0.4.0", false)],
                            table: table)
        XCTAssertEqual(result.owners(.root), ["0.43.0", "0.43.0#cont1"])
        XCTAssertEqual(result.owners(.container), ["0.4.0"])
        XCTAssertEqual(result.unclassified, ["0.43.0.1"])
    }

    /// A caption inside a container (a captioned image in a panel, column or
    /// expand: captions-parity CAP-12..14, every stress caption) is a
    /// caption row: the census checks caption before container.
    func testCaptionInsideAContainerIsCaption() {
        let table = RowOwnerTable(container: ["0.13"], caption: ["0.13.1.0"], list: [])
        let result = census([("0.13.1.0", false), ("0.13.0", false)], table: table)
        XCTAssertEqual(result.owners(.caption), ["0.13.1.0"])
        XCTAssertEqual(result.owners(.container), ["0.13.0"])
    }

    /// PR 4's fixtures and the inherited fixtures holding containers or
    /// captions all have a table (without one a container row would count
    /// as a list row), with an explicit list class.
    func testInheritedAndPR4FixturesHaveTables() {
        for fixture in ["containers-parity", "containers-dense", "containers-expand", "captions-parity",
                        "kitchen-sink", "lists-parity", "code-parity", "media-gallery", "stress-1k", "stress-5k"]
        {
            let table = RowOwnerTable.byFixture[fixture]
            XCTAssertNotNil(table, "\(fixture) has no owner table")
            XCTAssertNotNil(table?.list, "\(fixture)'s table leaves list nil")
        }
        // Spot checks against the fixtures (landmarks.md).
        let parity = RowOwnerTable.byFixture["containers-parity"]
        XCTAssertEqual(TextKit2RowCensus.classify(owner: "0.11.2", inNestedScroll: false, table: parity), .container)
        XCTAssertEqual(TextKit2RowCensus.classify(owner: "0.58.3.0", inNestedScroll: false, table: parity), .container)
        XCTAssertEqual(TextKit2RowCensus.classify(owner: "0.64.2.0", inNestedScroll: false, table: parity), .container)
        XCTAssertEqual(TextKit2RowCensus.classify(owner: "0.43.0", inNestedScroll: false, table: parity), .root)
        XCTAssertEqual(TextKit2RowCensus.classify(owner: "0.84.0.0", inNestedScroll: false, table: parity), .list)
        let stress = RowOwnerTable.byFixture["stress-5k"]
        XCTAssertEqual(stress?.container.count, 1_300)
        XCTAssertEqual(stress?.caption.count, 50)
        XCTAssertEqual(stress?.caption.first, "0.95.0.0")
        XCTAssertEqual(RowOwnerTable.byFixture["containers-dense"]?.container.count, 840)
    }

    /// Every registered owner table is self-consistent: no owner prefix is
    /// in two classes (a caption may sit inside a container: the census
    /// checks caption first), nested lists sit inside a container entry,
    /// and root owners are in no other class.
    func testRegisteredOwnerTablesAreConsistent() {
        for (fixture, table) in RowOwnerTable.byFixture {
            let lists = table.list ?? []
            for entry in table.container {
                XCTAssertFalse(RowOwnerTable.covers(lists, entry), "\(fixture): container \(entry) is inside a list entry")
                XCTAssertFalse(RowOwnerTable.covers(table.caption, entry), "\(fixture): container \(entry) is a caption")
            }
            for entry in lists {
                XCTAssertFalse(RowOwnerTable.covers(table.container, entry), "\(fixture): list \(entry) is in a container")
            }
            for entry in table.caption {
                XCTAssertFalse(RowOwnerTable.covers(lists, entry), "\(fixture): caption \(entry) is inside a list")
            }
            for entry in table.root {
                XCTAssertFalse(RowOwnerTable.covers(table.container + table.caption + lists, entry),
                               "\(fixture): root owner \(entry) is also in another class")
            }
            for entry in table.containerList {
                XCTAssertTrue(RowOwnerTable.covers(table.container, entry),
                              "\(fixture): nested list \(entry) is outside every container entry")
            }
        }
    }
}
