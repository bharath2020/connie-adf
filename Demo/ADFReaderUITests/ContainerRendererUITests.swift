import XCTest

/// PR 4 plan §7.5's behaviour assertions on container text, under both
/// renderers: each test launches its fixture afresh (`ContainerDriver`:
/// `-rendererReset`, `-fontSizeStep 0`, `-interactionProbe`), the SwiftUI
/// arm first and the TextKit 2 arm (`-textkit2`) second, so both start from
/// the same state. Fixture facts are in `ContainerUISupport.swift`.
///
/// The tests are grouped by family, each family's method names sharing a
/// prefix, so one family runs on its own with its `-only-testing:` flags
/// (`ADFReaderUITests/ContainerRendererUITests/<method>`). Until the step
/// that enables a family (plan §5), its text stays SwiftUI in both switch
/// positions: the SwiftUI arm of every test and the assertions marked
/// "now" below pass before it, the TextKit 2 engine assertions only after.
///
/// | Family (step) | Methods | Before the step |
/// |---|---|---|
/// | panel, quote, extension (3) | `testPanelQuoteExtensionTextDrawsOnTextKit2`, `testPanelExtensionPlaceholderStaysOneLabelledGroup`, `testPanelLinksRouteExactURLAndRejectBlankHref`, `testPanelSearchFallsBackPerOwnerAndReturns`, `testPanelSelectionSwiftUIOnly` | the placeholder test passes now; the others' SwiftUI arms |
/// | columns (4) | `testColumnsDrawOnTextKit2InColumnMajorOrder`, `testColumnsLinkRoutesExactURL`, `testVoiceOverColumnOrder` (iOS 27.0 only) | column-major order and the SwiftUI arms now; side by side (a regular width) the column text stays SwiftUI in both arms after step 4 too |
/// | expands (5) | `testExpandValuesAndOpenedBodies`, `testExpandSearchOpensChainAndFallsBack` | values, screenshots and the opened chain now |
/// | nested lists (6) | `testNestedListTaskInQuoteDispatchesOnce`, `testNestedListLeadersDrawOnTextKit2` | the SwiftUI dispatch and the P5 negative now |
/// | nested code (7) | `testNestedCodePansAndCopiesExactBytes` (exact bytes need `Scripts/lifecycle-gate.sh --only ContainerRendererUITests/testNestedCodePansAndCopiesExactBytes`; skips without the host agent) | the over-budget negative and the SwiftUI arm now |
/// | captions (8) | `testCaptionsDrawOnTextKit2AndAtomCaptionStaysSwiftUI`, `testCaptionImageAndLinkTapsHitSeparateRegions`, `testCaptionSearchFallsBackAndReturns` | the atom negative, the lightbox and link routing on SwiftUI now |
///
/// SwiftUI selection: prose keeps `.textSelection(.enabled)` on SwiftUI;
/// a TextKit 2 container row has none until PR 8 (§6.1), pinned by a
/// strict expected failure. Captions have no selection in the baseline.
@MainActor
final class ContainerRendererUITests: XCTestCase {
    private typealias KP = ContainersParity
    /// Per-switch position tolerance (stack plan §3), device pixels, with
    /// the comparison slack every check uses.
    private static let shiftLimit: CGFloat = 2.01
    private static let selectionResidual = "TextKit 2 container prose has no long-press selection or edit menu yet "
        + "(PR 4 scope, §6.1; PR 8 adds selection): the SwiftUI text shows Copy, the TextKit 2 row shows nothing"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ fixture: String = ContainersParity.fixture, textKit2: Bool = false,
                        fraction: String? = nil) -> ContainerDriver
    {
        let driver = ContainerDriver(fixture: fixture, textKit2: textKit2, fraction: fraction)
        driver.reader.waitForRenderer(textKit2 ? "TextKit 2" : "SwiftUI")
        return driver
    }

    private static func arm(_ textKit2: Bool) -> String { textKit2 ? "TextKit 2" : "SwiftUI" }

    /// From a section's heading, drags until `last` is fully in view.
    private func show(_ driver: ContainerDriver, section: String, through last: ContainerLeaf) -> Bool {
        driver.jump(toHeading: section, settleDrag: 0)
        return driver.scroll(by: 250, until: driver.element(last), maxDrags: 12)
    }

    // MARK: - Panels, quotes, extension bodies (step 3)

    /// Panel, quote (three levels), nested container and extension-body
    /// leaves: under TextKit 2 each is drawn by its own `tk2-row:<owner>`
    /// with its own text, under SwiftUI none is; the bodied sync block's
    /// paragraph (a root block, 0.43.0) is a TextKit 2 row under TextKit 2
    /// (PR 1's root scope, now too).
    func testPanelQuoteExtensionTextDrawsOnTextKit2() throws {
        let groups: [(section: String, leaves: [ContainerLeaf])] = [
            (KP.s1, [ContainerLeaf("KP-PANEL-INFO", "0.1.0"), KP.panelH2, KP.panelP1, KP.panelP2, KP.panelP3]),
            (KP.s3, [KP.quoteOuter, KP.quoteInner, KP.quoteInnermost, KP.quoteOuterAfter]),
            (KP.s4, [ContainerLeaf("KP-NEST-QP-INNER", "0.32.1.0"), ContainerLeaf("KP-NEST-PQ-INNER", "0.33.1.0"),
                     ContainerLeaf("KP-NEST-EP-INNER", "0.34.1.0"), ContainerLeaf("KP-NEST-DEEP", "0.36.0.0.0")]),
            (KP.s5, [KP.extensionP1, KP.extensionH4, KP.extensionP2]),
        ]
        for textKit2 in [false, true] {
            let driver = launch(textKit2: textKit2)
            for group in groups {
                try containerUIStep("\(Self.arm(textKit2)): \(group.section)") {
                    XCTAssertTrue(show(driver, section: group.section, through: group.leaves.last ?? KP.end),
                                  "\(group.section): the leaves never came into view")
                    for leaf in group.leaves {
                        driver.expectEngine(leaf, textKit2: textKit2, Self.arm(textKit2))
                    }
                    containerUIAttach(driver.app, "engine-\(textKit2 ? "tk2" : "swiftui")-\(group.leaves[0].owner)")
                }
            }
            XCTAssertTrue(driver.scroll(by: 250, until: driver.element(KP.syncBody), maxDrags: 8), "KP-SYNC-BODY not in view")
            driver.expectEngine(KP.syncBody, textKit2: textKit2, "\(Self.arm(textKit2)): the sync body (root)")
            driver.app.terminate()
        }
    }

    /// The extension placeholder stays one accessibility group labelled
    /// "Extension: <title>" holding its body, in both arms; the bodyless
    /// extension keeps its label. Passes now.
    func testPanelExtensionPlaceholderStaysOneLabelledGroup() throws {
        for textKit2 in [false, true] {
            let driver = launch(textKit2: textKit2)
            XCTAssertTrue(show(driver, section: KP.s5, through: KP.extensionP2), "the extension body never came into view")
            let groups = driver.app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", KP.extensionLabel))
            XCTAssertEqual(groups.count, 1, "\(Self.arm(textKit2)): \(groups.count) elements labelled \(KP.extensionLabel)")
            let group = groups.firstMatch
            for leaf in [KP.extensionP1, KP.extensionH4, KP.extensionP2] {
                let inside = group.descendants(matching: .any)
                    .matching(NSPredicate(format: "label BEGINSWITH %@", leaf.prefix)).firstMatch
                XCTAssertTrue(inside.exists, "\(Self.arm(textKit2)): \(leaf) is not inside the extension group")
                XCTAssertTrue(group.frame.contains(driver.element(leaf).frame),
                              "\(Self.arm(textKit2)): \(leaf) lies outside the group's frame")
            }
            XCTAssertTrue(driver.scroll(by: 200, until: driver.reader.element(labelled: KP.bodylessExtensionLabel),
                                        maxDrags: 6), "the bodyless extension is missing")
            containerUIAttach(driver.app, "extension-group-\(textKit2 ? "tk2" : "swiftui")")
            driver.app.terminate()
        }
    }

    /// Links in panel and extension text open their exact URL; a link tap
    /// never dispatches a task. A whitespace-only href should open nothing
    /// but opens "%20%20%20" on both renderers (main's preparation; an
    /// expected failure in `tapLink`, a PR 4 description follow-up).
    /// SwiftUI arm now; TextKit 2 arm after step 3.
    func testPanelLinksRouteExactURLAndRejectBlankHref() throws {
        try checkLinks(KP.links.filter { $0.section == KP.s2 })
    }

    /// A search matching inside a panel (KP-PANEL-MULTI-P2, 0.11.2): while
    /// it is active that owner draws on SwiftUI and its neighbours stay
    /// TextKit 2 rows; clearing returns it. After step 3.
    func testPanelSearchFallsBackPerOwnerAndReturns() throws {
        let driver = launch(textKit2: true)
        XCTAssertTrue(show(driver, section: KP.s1, through: KP.panelP3), "the multi-block panel never came into view")
        XCTAssertTrue(driver.isTextKit2(KP.panelP2), "\(KP.panelP2) is not a TextKit 2 row before the search")
        let counter = driver.search(KP.panelP2.sentinel)
        XCTAssertTrue(counter.hasPrefix("1 /"), "counter \(counter)")
        XCTAssertTrue(driver.isSwiftUI(KP.panelP2), "the highlighted owner is still a TextKit 2 row")
        for neighbour in [KP.panelP1, KP.panelP3] where driver.isPartlyShown(driver.element(neighbour)) {
            XCTAssertTrue(driver.isTextKit2(neighbour), "\(neighbour) left TextKit 2 (the fallback is per owner)")
        }
        containerUIAttach(driver.app, "panel-search-active")
        driver.clearSearch()
        XCTAssertTrue(driver.isTextKit2(KP.panelP2), "\(KP.panelP2) did not return to TextKit 2 after clearing")
    }

    /// SwiftUI keeps prose selection inside a panel (a long press shows an
    /// edit menu with Copy); the TextKit 2 row has none yet, pinned by a
    /// strict expected failure (an unexpected pass flips it). After step 3.
    func testPanelSelectionSwiftUIOnly() throws {
        var menus: [Bool: Bool] = [:]
        for textKit2 in [false, true] {
            let driver = launch(textKit2: textKit2)
            XCTAssertTrue(show(driver, section: KP.s1, through: KP.panelP2), "the panel never came into view")
            driver.expectEngine(KP.panelP1, textKit2: textKit2, "before the long press")
            let copies = driver.app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Copy"))
            let baseline = copies.count
            let frame = driver.element(KP.panelP1).frame
            driver.app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.minX + 40, dy: frame.minY + 10)).press(forDuration: 1.2)
            let deadline = Date().addingTimeInterval(3)
            var shown = false
            while !shown, Date() < deadline {
                shown = copies.count > baseline
                driver.pause(0.25)
            }
            menus[textKit2] = shown
            containerUIAttach(driver.app, "long-press-\(textKit2 ? "tk2" : "swiftui")")
            driver.app.terminate()
        }
        XCTAssertEqual(menus[false], true, "SwiftUI: a long press on panel prose showed no edit menu")
        let residual = XCTExpectedFailure.Options()
        residual.isStrict = true
        XCTExpectFailure(Self.selectionResidual, options: residual) {
            XCTAssertEqual(menus[true], true, "TextKit 2: a long press on panel prose shows no edit menu")
        }
    }

    // MARK: - Columns (step 4)

    /// The 25/75 and three-column sections: under TextKit 2 every column
    /// leaf is its own TextKit 2 row while the columns stack (a compact
    /// width, after step 4) and none while they sit side by side (a regular
    /// width: no family keeps the renderer there, the off-grid column
    /// probe); under SwiftUI none. In both arms and both layouts the
    /// accessibility order is column-major (25 % column top to bottom,
    /// then the 75 % column; A, B, C) — now. The layout is noted.
    func testColumnsDrawOnTextKit2InColumnMajorOrder() throws {
        let order = [KP.col25A, KP.col25B, KP.col75A, KP.col75H4, KP.col75B] + KP.col3
        var layouts: [String] = []
        for textKit2 in [false, true] {
            let driver = launch(textKit2: textKit2, fraction: KP.fraction(KP.columnsIndex))
            XCTAssertTrue(driver.element(KP.col25A).waitForExistence(timeout: 30), "did not land on the columns")
            let sideBySide = try XCTUnwrap(driver.columnsSideBySide(KP.col25A, KP.col75A), "the 25/75 columns are not in the tree")
            XCTAssertTrue(driver.scroll(by: 250, until: driver.element(KP.col3[2]), maxDrags: 8),
                          "the three columns never came into view")
            for leaf in order {
                driver.expectEngine(leaf, textKit2: ContainerDriver.columnTextKit2(textKit2, sideBySide: sideBySide),
                                    "\(Self.arm(textKit2)), \(sideBySide ? "side by side" : "stacked")")
            }
            let snapshot = try driver.reader.documentSnapshot()
            let positions = order.map { leaf in snapshot.all.firstIndex { $0.label.hasPrefix(leaf.prefix) } ?? -1 }
            XCTAssertFalse(positions.contains(-1), "\(Self.arm(textKit2)): a column leaf is not in the tree: \(positions)")
            XCTAssertEqual(positions, positions.sorted(), "\(Self.arm(textKit2)): the accessibility order is not "
                + "column-major: \(zip(order.map(\.sentinel), positions).map { "\($0.0)@\($0.1)" })")
            layouts.append(sideBySide ? "side by side" : "stacked")
            containerUINote("\(Self.arm(textKit2)): columns \(sideBySide ? "side by side" : "stacked")")
            containerUIAttach(driver.app, "columns-\(textKit2 ? "tk2" : "swiftui")")
            driver.app.terminate()
        }
        XCTAssertEqual(Set(layouts).count, 1, "the two arms laid the columns out differently: \(layouts)")
    }

    /// The link in the 67 % column opens its exact URL. SwiftUI arm now;
    /// TextKit 2 arm after step 4 (its own TextKit 2 row while the columns
    /// stack, SwiftUI side by side).
    func testColumnsLinkRoutesExactURL() throws {
        let left = ContainerLeaf("KP-COL33-A", "0.47.0.0"), right = ContainerLeaf("KP-COL67-A", "0.47.1.0")
        try checkLinks(KP.links.filter { $0.section == KP.s6 }) { driver, textKit2 in
            ContainerDriver.columnTextKit2(textKit2, sideBySide: driver.columnsSideBySide(left, right) ?? false)
        }
    }

    /// VoiceOver over the 25/75 columns, in each arm: the leaves are spoken
    /// column-major (KP-COL25-A, KP-COL25-B, KP-COL75-A, KP-COL75-H4,
    /// KP-COL75-B), the column heading is announced as a heading, and both
    /// arms speak the same words (TextKit 2's missing heading level is PR
    /// 1's residual, normalised). Needs `XCUIDevice.voiceOverService`
    /// (iOS 27.0: run on the lane's VoiceOver simulator); skips elsewhere.
    func testVoiceOverColumnOrder() throws {
        guard #available(iOS 27.0, *) else {
            throw XCTSkip("VoiceOver automation (XCUIDevice.voiceOverService) needs an iOS 27 runtime; "
                + "this is iOS \(UIDevice.current.systemVersion). Column order under VoiceOver stays a manual check here.")
        }
        let order = [KP.col25A, KP.col25B, KP.col75A, KP.col75H4, KP.col75B]
        let voiceOver = XCUIDevice.shared.voiceOverService
        addTeardownBlock { @MainActor in
            if XCUIDevice.shared.voiceOverService.isEnabled { try? XCUIDevice.shared.voiceOverService.disable() }
        }
        func withoutHeadingLevel(_ text: String) -> String {
            let text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard let range = text.range(of: " Heading level [1-6]", options: .regularExpression) else { return text }
            return text.replacingCharacters(in: range, with: " Heading")
        }
        var spoken: [Bool: [String]] = [:]
        for textKit2 in [false, true] {
            let driver = launch(textKit2: textKit2, fraction: KP.fraction(KP.columnsIndex))
            XCTAssertTrue(driver.element(KP.col25A).waitForExistence(timeout: 30), "did not land on the columns")
            let sideBySide = try XCTUnwrap(driver.columnsSideBySide(KP.col25A, KP.col75A), "the 25/75 columns are not in the tree")
            containerUINote("\(Self.arm(textKit2)): columns \(sideBySide ? "side by side" : "stacked")")
            for leaf in order {
                driver.expectEngine(leaf, textKit2: ContainerDriver.columnTextKit2(textKit2, sideBySide: sideBySide), "before VoiceOver")
            }
            try voiceOver.enable()
            var utterances: [String] = []
            var started = false
            for _ in 0 ..< 80 {
                let utterance = try voiceOver.moveForward().utterance
                if !started, utterance.contains(KP.col25A.sentinel) { started = true }
                if started { utterances.append(utterance) }
                if started, utterance.contains(KP.col75B.sentinel) { break }
            }
            try voiceOver.disable()
            spoken[textKit2] = utterances
            containerUIAttach(text: utterances.joined(separator: "\n"), "voiceover-columns-\(textKit2 ? "tk2" : "swiftui")")
            driver.app.terminate()
        }
        for (textKit2, utterances) in spoken {
            let indices = order.map { leaf in utterances.firstIndex { $0.contains(leaf.sentinel) } ?? -1 }
            XCTAssertFalse(indices.contains(-1), "\(Self.arm(textKit2)): a column leaf was not spoken: \(indices)")
            XCTAssertEqual(indices, indices.sorted(), "\(Self.arm(textKit2)): VoiceOver order is not column-major")
            let heading = utterances.first { $0.contains(KP.col75H4.sentinel) } ?? ""
            XCTAssertTrue(heading.contains("Heading"), "\(Self.arm(textKit2)): the column heading is not announced as one: "
                + heading)
        }
        XCTAssertEqual((spoken[true] ?? []).map(withoutHeadingLevel), (spoken[false] ?? []).map(withoutHeadingLevel),
                       "VoiceOver speaks the columns differently under TextKit 2")
    }

    // MARK: - Expands (step 5)

    /// The outer and nested expand (0.58, 0.58.3): "Collapsed" → tap →
    /// "Expanded" (a screenshot of each opened body, the arm-B/C proof of
    /// §7.4), the body leaves drawn by the arm's engine (TextKit 2 rows
    /// after step 5), and closing returns "Collapsed" and removes the
    /// body. Values and screenshots now.
    func testExpandValuesAndOpenedBodies() throws {
        let expand = KP.expandOuter
        let nested = try XCTUnwrap(expand.nestedTitle)
        for textKit2 in [false, true] {
            let arm = textKit2 ? "tk2" : "swiftui"
            let driver = launch(textKit2: textKit2, fraction: KP.fraction(KP.expandIndex))
            let button = driver.expandButton(expand.title)
            XCTAssertTrue(button.waitForExistence(timeout: 30), "did not land on \(expand.id)")
            XCTAssertEqual(driver.expandValue(expand.title), "Collapsed", "\(arm): the outer expand starts open")
            XCTAssertTrue(driver.setExpand(expand.title, open: true, step: 200), "\(arm): the outer expand did not open")
            XCTAssertTrue(driver.element(expand.first).waitForExistence(timeout: 10), "\(arm): no body after opening")
            containerUIAttach(driver.app, "expand-outer-open-\(arm)")
            XCTAssertEqual(driver.expandValue(nested), "Collapsed", "\(arm): the nested expand starts open")
            XCTAssertTrue(driver.setExpand(nested, open: true, step: 200), "\(arm): the nested expand did not open")
            let nestedFirst = try XCTUnwrap(expand.nestedFirst), nestedLast = try XCTUnwrap(expand.nestedLast)
            XCTAssertTrue(driver.element(nestedFirst).waitForExistence(timeout: 10), "\(arm): no nested body")
            containerUIAttach(driver.app, "expand-nested-open-\(arm)")
            for leaf in [expand.first, KP.expandH3, nestedFirst, nestedLast, expand.last] {
                if driver.isPartlyShown(driver.element(leaf)) || driver.element(leaf).exists {
                    driver.expectEngine(leaf, textKit2: textKit2, arm)
                }
            }
            XCTAssertTrue(driver.setExpand(nested, open: false, step: -200), "\(arm): the nested expand did not close")
            XCTAssertTrue(driver.reader.waitForDisappearance(of: driver.element(nestedFirst), timeout: 10),
                          "\(arm): the nested body stayed")
            XCTAssertTrue(driver.setExpand(expand.title, open: false, step: -200), "\(arm): the outer expand did not close")
            XCTAssertTrue(driver.reader.waitForDisappearance(of: driver.element(expand.first), timeout: 10),
                          "\(arm): the outer body stayed")
            driver.app.terminate()
        }
    }

    /// containers-expand: a search for `CXOPENSENTINEL` opens block 0's
    /// whole chain (outer, nested, deepest: all "Expanded") and shows the
    /// sentinel; under TextKit 2 the sentinel's owner (0.0.2.2.1) draws on
    /// SwiftUI while the search is active, its neighbours (0.0.2.2.0,
    /// 0.0.2.2.2) on TextKit 2, and clearing returns it. The opened chain
    /// now; the engines after step 5.
    func testExpandSearchOpensChainAndFallsBack() throws {
        typealias CE = ContainersExpand
        for textKit2 in [false, true] {
            let arm = Self.arm(textKit2)
            let driver = launch(CE.fixture, textKit2: textKit2)
            XCTAssertTrue(driver.expandButton(CE.chainTitles[0]).waitForExistence(timeout: 30), "containers-expand missing")
            XCTAssertEqual(driver.expandValue(CE.chainTitles[0]), "Collapsed", "\(arm): the chain starts open")
            let counter = driver.search(CE.sentinel.sentinel)
            XCTAssertTrue(counter.hasPrefix("1 /"), "\(arm): counter \(counter)")
            for title in CE.chainTitles {
                XCTAssertEqual(driver.expandValue(title), "Expanded", "\(arm): the search left \(title) closed")
            }
            XCTAssertTrue(driver.waitUntilShown(driver.element(CE.sentinel)), "\(arm): the sentinel is not in view")
            if textKit2 {
                XCTAssertTrue(driver.isSwiftUI(CE.sentinel), "the highlighted sentinel is still a TextKit 2 row")
                for neighbour in CE.sentinelNeighbours {
                    XCTAssertTrue(driver.isTextKit2(neighbour), "\(neighbour) is not a TextKit 2 row during the search")
                }
            } else {
                XCTAssertFalse(driver.reader.anyTextKit2Row.exists && driver.textKit2Row(owner: CE.sentinel.owner).exists,
                               "SwiftUI: the sentinel is a TextKit 2 row")
            }
            containerUIAttach(driver.app, "chain-search-\(textKit2 ? "tk2" : "swiftui")")
            driver.clearSearch()
            for title in CE.chainTitles {
                XCTAssertEqual(driver.expandValue(title), "Expanded", "\(arm): clearing closed \(title)")
            }
            driver.expectEngine(CE.sentinel, textKit2: textKit2, "\(arm) after clearing")
            driver.app.terminate()
        }
    }

    // MARK: - Lists nested in containers (step 6)

    /// The task inside a quote (0.64.2.0): its checkbox dispatches exactly
    /// one toggle with the new state and opens no URL; tapping its text
    /// dispatches nothing; the leader is a TextKit 2 row under TextKit 2
    /// (after step 6). The state is restored. SwiftUI arm now.
    func testNestedListTaskInQuoteDispatchesOnce() throws {
        let task = KP.taskOpen
        for textKit2 in [false, true] {
            let arm = Self.arm(textKit2)
            let driver = launch(textKit2: textKit2)
            XCTAssertTrue(show(driver, section: KP.s9, through: KP.taskDone), "the quote's tasks never came into view")
            driver.expectEngine(task, textKit2: textKit2, arm)
            let leader = driver.element(task)
            let start = try XCTUnwrap(driver.readProbe())
            let box = try XCTUnwrap(driver.reader.taskMarker(leader: leader.label), "\(arm): no checkbox on \(task)")
            let wasDone = box.label == "Completed task"
            box.tap()
            driver.pause(1.5)
            let toggled = try XCTUnwrap(driver.readProbe())
            XCTAssertEqual(toggled.taskDispatches, start.taskDispatches + 1, "\(arm): \(start) → \(toggled)")
            XCTAssertTrue(["\(task.owner) \(!wasDone)", "kp-quote-task-a \(!wasDone)"].contains(toggled.taskLast),
                          "\(arm): dispatched \(toggled.taskLast)")
            XCTAssertEqual(toggled.urlOpens, start.urlOpens, "\(arm): a task tap opened a URL")
            let frame = leader.frame
            driver.tap(at: CGPoint(x: frame.minX + min(frame.width / 2, 60), y: frame.minY + min(frame.height, 20) / 2))
            driver.pause(1)
            let afterText = try XCTUnwrap(driver.readProbe())
            XCTAssertEqual(afterText.taskDispatches, toggled.taskDispatches, "\(arm): tapping the text toggled the task")
            try XCTUnwrap(driver.reader.taskMarker(leader: leader.label), "\(arm): the checkbox vanished").tap()
            driver.pause(1.5)
            let restored = try XCTUnwrap(driver.readProbe())
            XCTAssertEqual(restored.taskDispatches, afterText.taskDispatches + 1, "\(arm): the restore did not dispatch")
            containerUIAttach(driver.app, "quote-task-\(textKit2 ? "tk2" : "swiftui")")
            driver.app.terminate()
        }
    }

    /// Nested-list leaders under TextKit 2 (after step 6): the minimum
    /// positions — a quote (0.64.0.0), an extension body (0.67.0.0) and a
    /// stacked column (0.68.0.0.0, a phone) — are TextKit 2 rows; the panel
    /// position (0.63.1.0) is recorded (enabled only if its probe passed,
    /// plan §4.7); a panel inside a root list item (0.84.0.1.0) stays
    /// SwiftUI (P5). Under SwiftUI none is a TextKit 2 row.
    func testNestedListLeadersDrawOnTextKit2() throws {
        let required = [KP.listQuote3, KP.listExt1, KP.listCol25L1]
        for textKit2 in [false, true] {
            let arm = Self.arm(textKit2)
            let driver = launch(textKit2: textKit2)
            XCTAssertTrue(show(driver, section: KP.s9, through: KP.listQuote3), "the lists never came into view")
            if driver.element(KP.listPanelA).exists {
                containerUINote("\(arm): \(KP.listPanelA) is "
                    + (driver.textKit2Row(owner: KP.listPanelA.owner).exists ? "a TextKit 2 row" : "SwiftUI"))
            }
            for leaf in required {
                XCTAssertTrue(driver.scroll(by: 250, until: driver.element(leaf), maxDrags: 8), "\(leaf) not in view")
                driver.expectEngine(leaf, textKit2: textKit2, arm)
            }
            driver.jump(toHeading: KP.s11, settleDrag: 0)
            XCTAssertTrue(driver.scroll(by: 250, until: driver.element(KP.listItemPanel), maxDrags: 8),
                          "\(KP.listItemPanel) not in view")
            XCTAssertTrue(driver.isSwiftUI(KP.listItemPanel, timeout: 5), "\(arm): a panel in a list item is a TextKit 2 row")
            containerUIAttach(driver.app, "nested-lists-\(textKit2 ? "tk2" : "swiftui")")
            driver.app.terminate()
        }
    }

    // MARK: - Code nested in containers (step 7)

    /// Code inside a panel (0.71.1): under TextKit 2 a TextKit 2 code row
    /// (after step 7); a 230 pt horizontal pan moves it at least 200 pt
    /// sideways and not vertically; Copy writes the exact code (read
    /// through the host agent's pasteboard: run through `--only
    /// ContainerRendererUITests/testNestedCodePansAndCopiesExactBytes`;
    /// without the agent the test skips after the taps, "not run"). The
    /// over-budget block in a panel (0.78.1) is never a TextKit 2 row.
    func testNestedCodePansAndCopiesExactBytes() throws {
        let agent = try? HostAgent.fromEnvironment()
        let code = KP.codePanel
        var mismatches: [String] = []
        for textKit2 in [false, true] {
            let arm = Self.arm(textKit2)
            let driver = launch(textKit2: textKit2)
            let reader = driver.reader
            XCTAssertTrue(show(driver, section: KP.s10, through: code), "\(code) never came into view")
            driver.expectEngine(code, textKit2: textKit2, arm)
            let text = driver.element(code)
            let rest = text.frame
            let start = try XCTUnwrap(reader.panStart(onCodeText: rest), "\(arm): no pan start on \(code)")
            reader.pan(from: start, by: 230)
            driver.pause()
            let moved = rest.minX - text.frame.minX
            XCTAssertGreaterThanOrEqual(moved, 200, "\(arm): the pan moved the code \(moved) pt")
            XCTAssertLessThanOrEqual(abs(text.frame.minY - rest.minY) * reader.pixelScale(), Self.shiftLimit,
                                     "\(arm): the pan moved the code vertically")
            if agent != nil { UIPasteboard.general.string = "ADF-CONTAINER-COPY-SENTINEL" }
            let copy = driver.app.buttons.matching(NSPredicate(format: "label == %@", ReaderDriver.Identifier.copyCodeLabel))
                .allElementsBoundByIndex.filter { $0.frame.maxY <= text.frame.minY + 4 }
                .min { text.frame.minY - $0.frame.maxY < text.frame.minY - $1.frame.maxY }
            try XCTUnwrap(copy, "\(arm): no Copy button above \(code)").tap()
            driver.pause()
            print("CONTAINER_CODE_COPY owner=\(code.owner) arm=\(arm) utf8_base64="
                + Data(KP.codePanelText.utf8).base64EncodedString())
            if let agent {
                let pasted = try agent.pasteboard()
                if pasted != KP.codePanelText {
                    mismatches.append("\(arm): the pasteboard holds \(pasted.debugDescription.prefix(160))")
                }
            }
            XCTAssertTrue(driver.scroll(by: 250, until: driver.element(KP.codeOver), maxDrags: 12), "KP-CODE-OVER not in view")
            XCTAssertTrue(driver.isSwiftUI(KP.codeOver, timeout: 5), "\(arm): the over-budget block is a TextKit 2 row")
            containerUIAttach(driver.app, "nested-code-\(textKit2 ? "tk2" : "swiftui")")
            driver.app.terminate()
        }
        guard let agent else {
            throw XCTSkip("Copy was tapped but the pasteboard was not read: ADF_LIFECYCLE_DIR is not set. Run through "
                + "Scripts/lifecycle-gate.sh --only ContainerRendererUITests/testNestedCodePansAndCopiesExactBytes.")
        }
        try agent.record("Container nested code Copy puts the exact code on the pasteboard (containers-parity 0.71.1)",
                         pass: mismatches.isEmpty, ["owner": code.owner, "mismatches": mismatches])
        XCTAssertTrue(mismatches.isEmpty, mismatches.joined(separator: "; "))
    }

    // MARK: - Captions (step 8)

    /// captions-parity: plain and marked captions (0.3.0, 0.4.0) and the
    /// captions in a panel (0.13.1.0), a column (0.14.0.0.0) and an opened
    /// expand (0.15.1.0) are TextKit 2 rows under TextKit 2 (after step
    /// 8); the caption holding a mention, a date and a status (0.9.0) stays
    /// SwiftUI in both arms (now).
    func testCaptionsDrawOnTextKit2AndAtomCaptionStaysSwiftUI() throws {
        typealias CAP = CaptionsParity
        for textKit2 in [false, true] {
            let arm = Self.arm(textKit2)
            let driver = launch(CAP.fixture, textKit2: textKit2)
            XCTAssertTrue(driver.element(CAP.plain).waitForExistence(timeout: 30), "captions-parity missing")
            for leaf in [CAP.plain, CAP.marks] {
                XCTAssertTrue(driver.scroll(by: 250, until: driver.element(leaf), maxDrags: 6), "\(leaf) not in view")
                driver.expectEngine(leaf, textKit2: textKit2, arm)
            }
            XCTAssertTrue(driver.scroll(by: 250, until: driver.element(CAP.atoms), maxDrags: 12), "\(CAP.atoms) not in view")
            XCTAssertTrue(driver.isSwiftUI(CAP.atoms, timeout: 5), "\(arm): the atom caption is a TextKit 2 row")
            for leaf in [CAP.inPanel, CAP.inColumn] {
                XCTAssertTrue(driver.scroll(by: 250, until: driver.element(leaf), maxDrags: 12), "\(leaf) not in view")
                driver.expectEngine(leaf, textKit2: textKit2, arm)
            }
            XCTAssertTrue(driver.setExpand(CAP.expandTitle, open: true, step: 250), "\(arm): CAP-EXPAND did not open")
            XCTAssertTrue(driver.scroll(by: 250, until: driver.element(CAP.inExpand), maxDrags: 6), "CAP-14 not in view")
            driver.expectEngine(CAP.inExpand, textKit2: textKit2, arm)
            containerUIAttach(driver.app, "captions-\(textKit2 ? "tk2" : "swiftui")")
            driver.app.terminate()
        }
    }

    /// The image and the caption are separate tap regions, in both arms: a
    /// tap on CAP-03's image opens the lightbox (its Close button) and no
    /// URL; on CAP-05 the image opens the lightbox and the caption's link
    /// opens exactly https://example.com/captions-parity/cap-05; CAP-06's
    /// whitespace-only link opens nothing. Media still loads after a
    /// scroll away and back (the lightbox needs a loaded image). SwiftUI
    /// arm now; TextKit 2 arm after step 8.
    func testCaptionImageAndLinkTapsHitSeparateRegions() throws {
        typealias CAP = CaptionsParity
        for textKit2 in [false, true] {
            let arm = Self.arm(textKit2)
            let driver = launch(CAP.fixture, textKit2: textKit2)
            let app = driver.app
            XCTAssertTrue(driver.element(CAP.plain).waitForExistence(timeout: 30), "captions-parity missing")
            func lightbox(_ image: String, _ context: String) throws {
                let element = driver.reader.element(labelled: image)
                XCTAssertTrue(driver.scroll(by: 250, until: element, maxDrags: 8), "\(context): \(image) not in view")
                let before = try XCTUnwrap(driver.readProbe())
                element.tap()
                let close = app.buttons["Close"]
                XCTAssertTrue(close.waitForExistence(timeout: 10), "\(context): tapping \(image) opened no lightbox")
                containerUIAttach(app, "lightbox-\(image)-\(textKit2 ? "tk2" : "swiftui")")
                close.tap()
                XCTAssertTrue(driver.reader.waitForDisappearance(of: close, timeout: 10), "\(context): the lightbox stayed")
                let after = try XCTUnwrap(driver.readProbe())
                XCTAssertEqual(after.urlOpens, before.urlOpens, "\(context): the image tap opened a URL")
            }
            try lightbox(CAP.plainImage, arm)
            driver.expectEngine(CAP.plain, textKit2: textKit2, arm)
            try lightbox(CAP.linkedImage, arm)
            let caption = driver.element(CAP.linked)
            driver.expectEngine(CAP.linked, textKit2: textKit2, arm)
            let link = ContainerLink(leaf: CAP.linked, linkText: CAP.linkedText, url: CAP.linkedURL, section: CAP.s1)
            try tapLink(link, driver, in: caption, arm: arm)
            let blank = ContainerLink(leaf: CAP.blankLink, linkText: CAP.blankLinkText, url: nil, section: CAP.s1)
            XCTAssertTrue(driver.scroll(by: 250, until: driver.element(CAP.blankLink), maxDrags: 6), "CAP-06 not in view")
            try tapLink(blank, driver, in: driver.element(CAP.blankLink), arm: arm)
            // Away and back: the media reloads, and the lightbox still opens.
            for _ in 0 ..< 3 { app.scrollViews.firstMatch.swipeUp(velocity: .fast) }
            driver.pause()
            for _ in 0 ..< 6 { app.scrollViews.firstMatch.swipeDown(velocity: .fast) }
            driver.pause()
            try lightbox(CAP.plainImage, "\(arm) after a scroll away and back")
            driver.app.terminate()
        }
    }

    /// A search matching CAP-03's caption only: under TextKit 2 its owner
    /// (0.3.0) draws on SwiftUI while the search is active, CAP-04 (0.4.0)
    /// stays a TextKit 2 row, and clearing returns it. After step 8.
    func testCaptionSearchFallsBackAndReturns() throws {
        typealias CAP = CaptionsParity
        let driver = launch(CAP.fixture, textKit2: true)
        XCTAssertTrue(driver.element(CAP.plain).waitForExistence(timeout: 30), "captions-parity missing")
        XCTAssertTrue(driver.isTextKit2(CAP.plain), "\(CAP.plain) is not a TextKit 2 row before the search")
        let counter = driver.search("plain caption under")
        XCTAssertTrue(counter.hasPrefix("1 /"), "counter \(counter)")
        XCTAssertTrue(driver.isSwiftUI(CAP.plain), "the highlighted caption is still a TextKit 2 row")
        if driver.isPartlyShown(driver.element(CAP.marks)) {
            XCTAssertTrue(driver.isTextKit2(CAP.marks), "\(CAP.marks) left TextKit 2 (the fallback is per owner)")
        }
        containerUIAttach(driver.app, "caption-search-active")
        driver.clearSearch()
        XCTAssertTrue(driver.isTextKit2(CAP.plain), "\(CAP.plain) did not return to TextKit 2 after clearing")
    }

    // MARK: - Links

    /// Each link of `links`, SwiftUI arm then TextKit 2 arm (own launches).
    /// `engine`: whether the link's leaf is a TextKit 2 row in an arm, once
    /// it is in view (the switch, unless a family's layout says otherwise).
    private func checkLinks(
        _ links: [ContainerLink], engine: @MainActor (ContainerDriver, Bool) -> Bool = { _, textKit2 in textKit2 }
    ) throws {
        for textKit2 in [false, true] {
            let arm = Self.arm(textKit2)
            let driver = launch(textKit2: textKit2)
            for link in links {
                try containerUIStep("\(arm): \(link.leaf) → \(link.url ?? "nothing")") {
                    XCTAssertTrue(show(driver, section: link.section, through: link.leaf), "\(link.leaf) never came into view")
                    driver.expectEngine(link.leaf, textKit2: engine(driver, textKit2), arm)
                    try tapLink(link, driver, in: driver.element(link.leaf), arm: arm)
                }
            }
            driver.app.terminate()
        }
    }

    /// Taps `link`'s glyphs in `text`: an exact URL opens once (no task
    /// dispatch, the app stays in front); a whitespace-only href opens
    /// nothing.
    private func tapLink(_ link: ContainerLink, _ driver: ContainerDriver, in text: XCUIElement, arm: String) throws {
        let start = try XCTUnwrap(driver.readProbe())
        var probe = start
        var opened = false
        for point in driver.linkPoints(link, in: text) {
            driver.tap(at: point)
            driver.pause(1.5)
            XCTAssertEqual(driver.app.state, .runningForeground, "\(arm): the link left the app")
            probe = try XCTUnwrap(driver.readProbe())
            if probe.urlOpens != start.urlOpens {
                opened = true
                break
            }
        }
        XCTAssertEqual(probe.taskDispatches, start.taskDispatches, "\(arm): a link tap dispatched a task")
        if let url = link.url {
            XCTAssertTrue(opened, "\(arm): \(link.leaf)'s link opened nothing")
            XCTAssertEqual(probe.urlOpens, start.urlOpens + 1, "\(arm): expected one URL open (\(start) → \(probe))")
            XCTAssertEqual(probe.urlLast, url, "\(arm): \(link.leaf)'s link routed the wrong URL")
        } else {
            // Main's own behaviour, not this PR's: preparation builds the
            // href with `URL(string:)` (`InlineComposer`), which
            // percent-encodes "   " to "%20%20%20", and both arms open that
            // URL (SwiftUI's Text and the TextKit 2 row read the same
            // prepared link; captured on both at b1b829c + cols). Expected
            // here until preparation is fixed (strict: the fix turns this
            // red, so the wrapper goes with it).
            let continues = continueAfterFailure
            continueAfterFailure = true
            XCTExpectFailure("PR 4 description follow-up: a whitespace-only href opens \"%20%20%20\" on both renderers "
                + "(main's InlineComposer: URL(string:) percent-encodes the blank href)") {
                XCTAssertFalse(opened, "\(arm): a whitespace-only href opened \(probe.urlLast)")
            }
            continueAfterFailure = continues
        }
        containerUIAttach(driver.app, "link-\(link.leaf.owner)-\(arm == "TextKit 2" ? "tk2" : "swiftui")")
    }
}
