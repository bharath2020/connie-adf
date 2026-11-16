import XCTest

/// Smart links end to end on `-fixture smart-links` (design §4–§7), under
/// both renderers.
///
/// `testResolvesOnlyWhatIsOnScreen…` (no host agent needed). Counters are
/// read from `SmartLinkProbe` (`-smartLinkProbe`): one element, one
/// consistent snapshot in well under a second.
/// 1. **Plain first, then the title.** With `-smartLinkDelay 8` and failure
///    rate 0 each of the five intro links (blocks 0.2–0.6) is first exposed
///    as its prepared text — the URL; for the inline card (0.6), the URL's
///    host (design call #30) — and keeps showing it while its lookup runs
///    (four at once; the fifth waits for a slot, the cap of 4), then shows
///    its title. Separately, the design §6 spoken text is checked on both
///    renderers (a TextKit 2 row's label; on SwiftUI the leaf's `Text`,
///    which call #35 labels as a whole): "<prepared text>, loading title"
///    while loading, then "<kind>, <title>", e.g. "Roadmap: Page, Q3
///    Roadmap" (a failed check is reported and the rest of the test still
///    runs). Under TextKit 2 each link stays a `tk2-row:` element.
/// 2. **Nothing else re-renders.** Probe A with four lookups in flight, B
///    once all five resolved. Text-leaf body evaluations since launch (the
///    library's `ADFTextRenderer.textLeafStats`) grow by the smart-link leaf
///    refreshes plus exactly the leaves the lazy stack newly builds as the
///    shrinking rows pull content up (each counted on its own: SwiftUI's
///    engine-leaf body, TextKit 2's new live row and its first conversion);
///    under TextKit 2 no existing row converts its text again. A read 3 s
///    later (C), and one after opening and closing About This Build (whose
///    rows must show the same numbers), move nothing.
///    `testFailedLookupsRedrawOnlyTheirLeaves…` is the exact form: with
///    every lookup failing, links go plain → loading → plain (colour only,
///    no row changes size), and leaf bodies (and TextKit 2 conversions)
///    grow by exactly the refreshes.
/// 3. **Lazy.** Each text leaf with smart links reports its own visibility
///    (design call #28). At rest at the top the resolver was called exactly
///    5 times of the fixture's 86 unique URLs: the five intro leaves, the
///    only smart-link leaves on the first screen (blocks 0.7–0.17 below
///    them have no links), each resolved and titled, so no other URL was
///    asked — not even the last row's (built by the lazy stack, never
///    shown). Scrolling down a few screens adds calls; a fling past leaves
///    with lookups in flight cancels them (a cancelled call is counted when
///    its task returns, call #33), and the counters stay consistent
///    (`resolverCalls == resolved + failed + cancellations + inFlight`,
///    and the mock resolver saw the same calls and cancellations).
///
/// `testNoResolverKeepsLinksAndCardChips…`: with `-smartLinks off` (no
/// resolver) nothing is looked up, bare links keep their URLs and the
/// inline card is the host-only chip it is on main (call #30).
///
/// `testFlingThrashSoak…` (host agent: `Scripts/lifecycle-gate.sh --only
/// SmartLinkUITests/<method>`): a fling with the `top` CPU settle check,
/// five scene-snapshot thrash cycles (Home, lock, app switcher) started
/// with lookups in flight, the CPU settle check again, then a 150 s idle
/// soak after every lookup has finished.
///
/// `testVideoTour…`: a paced tour for the proof videos (plain → dimmed →
/// icon and title while scrolling); asserts only that the tour ran.
@MainActor
final class SmartLinkUITests: XCTestCase {
    /// One of the five smart links on the first screen: its paragraph's lead
    /// text, the text it shows as prepared (a bare link's URL; an inline
    /// card's host, design call #30), and its title and kind once resolved.
    struct IntroLink {
        let lead: String
        let prepared: String
        let kind: String
        let title: String
        /// Design §6 spoken text per stage.
        var plain: String { lead + prepared }
        var resolving: String { plain + ", loading title" }
        var resolved: String { lead + "\(kind), \(title)" }

        /// What the label's characters show (icon character dropped,
        /// no-break spaces as spaces): the prepared text first (plain or
        /// loading)…
        func showsPrepared(_ label: String) -> Bool { SmartLinkUITests.shown(label).hasPrefix(plain) }
        /// …then the title, as drawn (SwiftUI's `Text` characters) or as
        /// spoken (§6).
        func showsTitle(_ label: String) -> Bool {
            let shown = SmartLinkUITests.shown(label)
            return shown == lead + title || shown == resolved
        }
    }

    /// Blocks 0.2–0.6 of `Fixtures/smart-links.json`; the titles are the mock
    /// resolver's (`MockSmartLinkResolver.metadata(for:)`). The last is an
    /// `inlineCard` (…/pages/2972601/Design+System+Tokens): with a resolver
    /// installed it is a smart-link text run showing the URL's host until it
    /// resolves; without one it is the host-only chip, as on main.
    static let intro = [
        IntroLink(lead: "Roadmap: ", prepared: "https://acme.atlassian.net/wiki/spaces/ENG/pages/7118762/Q3+Roadmap",
                  kind: "Page", title: "Q3 Roadmap"),
        IntroLink(lead: "Onboarding: ",
                  prepared: "https://acme.atlassian.net/wiki/spaces/MOBILE/pages/1945560/Engineering+Onboarding",
                  kind: "Page", title: "Engineering Onboarding"),
        IntroLink(lead: "Release blog: ",
                  prepared: "https://acme.atlassian.net/wiki/spaces/SEC/blog/2026/09/17/2941752/Release+Notes+2.4",
                  kind: "Blog post", title: "Release Notes 2.4"),
        IntroLink(lead: "Tracking issue: ", prepared: "https://acme.atlassian.net/browse/OPS-205",
                  kind: "Issue", title: "OPS-205 Release 2.5 sign-off"),
        IntroLink(lead: cardLead, prepared: cardHost, kind: "Page", title: "Design System Tokens"),
    ]
    /// The intro inline card's host: its text until resolved (and its chip's
    /// text without a resolver).
    static let cardHost = "acme.atlassian.net"
    /// The intro inline card's paragraph lead.
    static let cardLead = "As an inline card: "

    /// A label as text: the icon's object-replacement character dropped,
    /// no-break spaces as spaces, runs of spaces collapsed.
    nonisolated static func shown(_ label: String) -> String {
        let plain = label.replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        return plain.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
    /// The fixture's unique canonical smart-link URLs (impl-demo.md).
    static let uniqueURLs = 86
    /// The intro paragraph, first block after the title.
    static let introLandmark = "SL-INTRO"
    /// Each mock lookup's duration in the functional test: long enough for
    /// probe A with the lookups in flight, and to see each stage.
    static let functionalDelay = 8.0
    /// `SmartLinkProbe`'s element (`-smartLinkProbe`).
    static let probeID = "smartlink-probe"

    /// About This Build fields, top to bottom (each value its own element).
    static let liveRows = "tk2-live-rows"
    static let smartLinkFields = [
        "smartlink-stat-resolverCalls", "smartlink-stat-cancellations", "smartlink-stat-inFlight",
        "smartlink-stat-resolved", "smartlink-stat-failed", "smartlink-stat-leafRefreshes",
        "smartlink-stat-refreshedOwners",
    ]
    static let mockFields = ["smartlink-calls", "smartlink-cancelled", "smartlink-in-flight", "smartlink-resolved",
                             "smartlink-failed"]
    static let leafFields = ["leaf-stat-total", "leaf-stat-segmented", "leaf-stat-engine", "tk2-stat-conversions",
                             "tk2-stat-layouts"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Functional: plain → title, only these leaves redraw, lazy

    func testResolvesOnlyWhatIsOnScreenSwiftUI() throws {
        try resolvesOnlyWhatIsOnScreen(textKit2: false)
    }

    func testResolvesOnlyWhatIsOnScreenTextKit2() throws {
        try resolvesOnlyWhatIsOnScreen(textKit2: true)
    }

    private func resolvesOnlyWhatIsOnScreen(textKit2: Bool) throws {
        // Every check below is independent evidence (the §6 spoken-text
        // checks especially): a failed one is reported and the rest still
        // run, so one run gives the whole picture.
        continueAfterFailure = true
        let arm = textKit2 ? "textkit2" : "swiftui"
        let reader = launch(textKit2: textKit2, delay: Self.functionalDelay, failureRate: 0)
        let app = reader.app
        let launched = Date()

        // 1. First exposed as the URL (plain, or loading).
        let first = link(Self.intro[0], reader, textKit2: textKit2)
        guard first.waitForExistence(timeout: 20) else {
            XCTFail("the Roadmap intro link never appeared")
            return
        }
        let firstLabel = first.label
        note("\(arm) first label of the Roadmap link (\(elapsed(since: launched))): \(firstLabel)")
        XCTAssertTrue(Self.intro[0].showsPrepared(firstLabel),
                      "the Roadmap link was not first shown as its URL: \(firstLabel)")

        // 2a. Probe A: four lookups in flight, the fifth queued (cap of 4).
        let a = waitForProbe(reader, "A (4 lookups in flight)", timeout: 6) { $0["calls"] == 4 && $0["inFlight"] == 4 }
        XCTAssertTrue(a.met, "A: expected 4 calls in flight: \(a.stats)")
        XCTAssertEqual(a.stats["resolved"], 0, "A: \(a.stats)")
        XCTAssertEqual(a.stats["refreshes"], 4, "A: four leaves went plain → loading: \(a.stats)")
        // Still the URL (the card: its host) while loading; design §6 speaks
        // "<URL>, loading title".
        let loading = currentLabels(reader, textKit2: textKit2)
        note("\(arm) loading stage (\(elapsed(since: launched))): \(loading)")
        XCTAssertTrue(zip(loading, Self.intro).allSatisfy { $0.1.showsPrepared($0.0) },
                      "a link stopped showing its URL (or the card its host) before its lookup ended: \(loading)")
        XCTAssertTrue(Self.count(loading, \.resolving) == 4 && Self.count(loading, \.plain) == 1,
                      "§6 spoken text while loading: expected 4 links \"<URL>, loading title\" and 1 plain (queued): "
                      + "\(loading)")
        attach(app, "\(arm)-01-loading")
        if !textKit2 {
            XCTAssertFalse(reader.anyTextKit2Row.exists, "a TextKit 2 row exists on the SwiftUI renderer")
        }

        // 1b. Then each changes to its title.
        let titled = waitForLabels(reader, textKit2: textKit2, timeout: Self.functionalDelay + 15) { labels in
            labels.first.map(Self.intro[0].showsTitle) ?? false
        }
        note("\(arm) Roadmap titled (\(elapsed(since: launched))): \(titled.labels)")
        XCTAssertTrue(titled.met, "the Roadmap link never showed its title: \(titled.labels)")
        attach(app, "\(arm)-02-first-titles")
        let allTitled = waitForLabels(reader, textKit2: textKit2, timeout: 2 * Self.functionalDelay + 15) { labels in
            zip(labels, Self.intro).allSatisfy { $0.1.showsTitle($0.0) }
        }
        note("\(arm) all titled (\(elapsed(since: launched))): \(allTitled.labels)")
        XCTAssertTrue(allTitled.met, "not every intro link showed its title: \(allTitled.labels)")
        attach(app, "\(arm)-03-all-titles")
        // Design §6: a resolved link speaks "<kind>, <title>".
        XCTAssertEqual(allTitled.labels, Self.intro.map(\.resolved), "§6 spoken text once resolved")
        if textKit2 {
            for link in Self.intro {
                XCTAssertTrue(reader.textKit2Row(labelPrefix: link.lead).exists,
                              "\(link.lead)is not a TextKit 2 row once resolved")
            }
        } else {
            XCTAssertFalse(reader.anyTextKit2Row.exists, "a TextKit 2 row exists on the SwiftUI renderer")
        }

        // 2b. Probe B at rest, then C after 3 s with nothing happening (the
        // probe's own polling must move nothing).
        let b = waitForProbe(reader, "B (all resolved, settled)", timeout: 10, settle: 1.5) {
            $0["resolved"] == Self.intro.count && $0["inFlight"] == 0
        }
        reader.pause(3)
        let c = probe(reader, "C (3 s later, control)")

        // 3. Lazy: exactly the on-screen URLs were looked up.
        XCTAssertEqual(b.stats["calls"], Self.intro.count, "B: \(b.stats)")
        XCTAssertEqual(b.stats["resolved"], Self.intro.count, "B: \(b.stats)")
        XCTAssertEqual(b.stats["cancelled"], 0, "B: \(b.stats)")
        XCTAssertEqual(b.stats["failed"], 0, "B: \(b.stats)")
        XCTAssertEqual(b.stats["owners"], Self.intro.count, "B: \(b.stats)")
        XCTAssertEqual(b.stats["refreshes"], 2 * Self.intro.count, "B: each leaf plain → loading → title: \(b.stats)")
        XCTAssertEqual(b.stats["mockCalls"], Self.intro.count, "B: the mock saw other calls: \(b.stats)")
        XCTAssertLessThan(b.stats["calls"], Self.uniqueURLs)

        // 2c. The A→B window. A title is shorter than its URL, so the five
        // rows shrink and the lazy stack builds the row(s) that move into
        // its render region: those are first builds, not redraws, and each
        // is counted on its own (SwiftUI: an engine-leaf body, which a
        // smart-link redraw never re-evaluates on that arm; TextKit 2: a
        // live row and its first conversion). Everything else must be a
        // smart-link refresh — exact equality, no tolerance.
        let window = Window(a.stats, b.stats)
        note("\(arm) A→B \(window)")
        XCTAssertEqual(window.refreshes, 6, "4 loading → title, then the fifth plain → loading → title: \(window)")
        if textKit2 {
            XCTAssertEqual(window.segmented, 0, "a SwiftUI text leaf re-evaluated under TextKit 2: \(window)")
            XCTAssertGreaterThanOrEqual(window.live, 0, "TextKit 2 rows were released: \(window)")
            XCTAssertEqual(window.conversions, window.refreshes + window.live,
                           "an existing TextKit 2 row converted text it did not change: \(window)")
            XCTAssertEqual(window.engine, window.conversions,
                           "an engine leaf re-evaluated without a new input: \(window)")
        } else {
            XCTAssertEqual(window.conversions, 0, window.description)
            XCTAssertEqual(b.stats["live"], 0, "TextKit 2 rows alive on SwiftUI: \(window)")
            XCTAssertEqual(window.segmented, window.refreshes + window.engine,
                           "a SwiftUI text leaf re-evaluated without a smart-link change: \(window)")
        }
        XCTAssertLessThanOrEqual(window.builtLeaves, 3, "more new leaves than the shrink can expose: \(window)")
        XCTAssertEqual(c.values, b.stats.values, "a counter moved with nothing happening (B \(b.stats), C \(c))")

        // 2d. About This Build shows the same numbers, and opening and
        // closing it re-evaluates no leaf.
        let about = readStats(reader, ["smartlink-stat-resolverCalls", "smartlink-stat-leafRefreshes", "leaf-stat-total",
                                       "leaf-stat-segmented", "leaf-stat-engine", "tk2-stat-conversions"], "About")
        let afterAbout = probe(reader, "C2 (after About This Build)")
        for (field, key) in [("smartlink-stat-resolverCalls", "calls"), ("smartlink-stat-leafRefreshes", "refreshes"),
                             ("leaf-stat-total", "leaves"), ("leaf-stat-segmented", "segmented"),
                             ("leaf-stat-engine", "engine"), ("tk2-stat-conversions", "conversions")] {
            XCTAssertEqual(about[field], c[key], "About's \(field) differs from the probe's \(key)")
        }
        XCTAssertEqual(about[Self.liveRows], c["live"], "About's live rows differ from the probe's")
        XCTAssertEqual(afterAbout.values, c.values, "opening About This Build moved a counter (C \(c), after \(afterAbout))")

        // 3b. Scrolling down a few screens asks for more; a fling past rows
        // with lookups in flight cancels them.
        for _ in 0 ..< 6 {
            reader.drag(by: 600)
            reader.pause(1.0)
        }
        attach(app, "\(arm)-04-scrolled")
        let e = probe(reader, "E (scrolled down)")
        XCTAssertGreaterThan(e["calls"], b.stats["calls"], "scrolling down asked for nothing: \(e)")
        XCTAssertGreaterThan(e["inFlight"], 0, "no lookup in flight before the fling: \(e)")
        let scroll = app.scrollViews.firstMatch
        for _ in 0 ..< 3 {
            scroll.swipeUp(velocity: .fast)
        }
        // A cancelled call is counted when its task returns (design call
        // #33), not when it is cancelled: give the mock's `Task.sleep` a
        // moment to throw.
        let flung = waitForProbe(reader, "F (after the fling)", timeout: 5) {
            $0["cancelled"] > e["cancelled"]
        }.stats
        scrollToTop(reader)
        attach(app, "\(arm)-05-back-at-top")
        let returned = currentLabels(reader, textKit2: textKit2)
        XCTAssertTrue(zip(returned, Self.intro).allSatisfy { $0.1.showsTitle($0.0) },
                      "a returning row did not draw its title: \(returned)")
        let d = waitForProbe(reader, "D (back at the top, settled)", timeout: 10, settle: 1.5) {
            $0["inFlight"] == 0 && $0["mockInFlight"] == 0
        }.stats
        note("\(arm) laziness: calls at rest \(b.stats["calls"]) of \(Self.uniqueURLs) URLs; after scrolling "
            + "\(e["calls"]) (cancelled \(e["cancelled"])); after the fling \(flung["calls"]) (cancelled "
            + "\(flung["cancelled"])); back at the top \(d["calls"]) (cancelled \(d["cancelled"]))")
        XCTAssertGreaterThan(flung["cancelled"], e["cancelled"], "the fling cancelled nothing: \(e) → \(flung)")
        XCTAssertEqual(d["inFlight"], 0, "D: \(d)")
        XCTAssertEqual(d["calls"], d["resolved"] + d["failed"] + d["cancelled"] + d["inFlight"],
                       "D: the counters do not add up: \(d)")
        XCTAssertEqual(d["mockCalls"], d["calls"], "D: the mock saw other calls: \(d)")
        XCTAssertEqual(d["mockCancelled"], d["cancelled"], "D: the mock saw other cancellations: \(d)")
        XCTAssertLessThan(d["calls"], Self.uniqueURLs, "D: \(d)")
    }

    func testFailedLookupsRedrawOnlyTheirLeavesSwiftUI() throws {
        try failedLookupsRedrawOnlyTheirLeaves(textKit2: false)
    }

    func testFailedLookupsRedrawOnlyTheirLeavesTextKit2() throws {
        try failedLookupsRedrawOnlyTheirLeaves(textKit2: true)
    }

    /// The exact form of 2c: every lookup fails (`-smartLinkFailureRate 1`),
    /// so each link goes plain → loading → plain again — a colour change
    /// only, no row changes size and the lazy stack builds nothing. Across
    /// the window every text-leaf body evaluation (and under TextKit 2
    /// every conversion) is a smart-link refresh, with equality. Lookups take
    /// `functionalDelay` (8 s), as in the title test: with 4 s, a slow
    /// launch on a busy host let all five fail before probe A's first read.
    private func failedLookupsRedrawOnlyTheirLeaves(textKit2: Bool) throws {
        continueAfterFailure = true
        let arm = textKit2 ? "textkit2" : "swiftui"
        let reader = launch(textKit2: textKit2, delay: Self.functionalDelay, failureRate: 1)
        XCTAssertTrue(link(Self.intro[0], reader, textKit2: textKit2).waitForExistence(timeout: 20),
                      "the Roadmap intro link never appeared")
        let a = waitForProbe(reader, "A (4 lookups in flight)", timeout: 6) { $0["calls"] == 4 && $0["inFlight"] == 4 }
        XCTAssertTrue(a.met, "A: expected 4 calls in flight: \(a.stats)")
        let b = waitForProbe(reader, "B (all failed, settled)", timeout: 2 * Self.functionalDelay + 10, settle: 1.5) {
            $0["failed"] == Self.intro.count && $0["inFlight"] == 0
        }
        XCTAssertTrue(b.met, "B: expected 5 failed lookups: \(b.stats)")
        let labels = currentLabels(reader, textKit2: textKit2)
        XCTAssertTrue(zip(labels, Self.intro).allSatisfy { $0.1.showsPrepared($0.0) },
                      "a failed link left its URL (or the card its host): \(labels)")
        XCTAssertEqual(labels, Self.intro.map(\.plain), "§6: a failed link speaks as plain")
        attach(reader.app, "\(arm)-failed-plain")

        let window = Window(a.stats, b.stats)
        note("\(arm) failure-path A→B \(window)")
        XCTAssertEqual(window.refreshes, 6, "4 loading → plain, then the fifth plain → loading → plain: \(window)")
        XCTAssertEqual(window.leaves, window.refreshes, "a text leaf re-evaluated without a smart-link change: \(window)")
        XCTAssertEqual(window.live, 0, "TextKit 2 rows were created or released: \(window)")
        if textKit2 {
            XCTAssertEqual(window.engine, window.refreshes, window.description)
            XCTAssertEqual(window.segmented, 0, window.description)
            XCTAssertEqual(window.conversions, window.refreshes,
                           "a TextKit 2 row converted text it did not change: \(window)")
        } else {
            XCTAssertEqual(window.segmented, window.refreshes, window.description)
            XCTAssertEqual(window.engine, 0, window.description)
            XCTAssertEqual(window.conversions, 0, window.description)
        }
        XCTAssertEqual(b.stats["calls"], Self.intro.count, "B: \(b.stats)")
        XCTAssertEqual(b.stats["mockCalls"], Self.intro.count, "B: \(b.stats)")
    }

    // MARK: - No resolver: links as authored, cards as chips

    func testNoResolverKeepsLinksAndCardChipsSwiftUI() throws {
        try noResolverKeepsLinksAndCardChips(textKit2: false)
    }

    func testNoResolverKeepsLinksAndCardChipsTextKit2() throws {
        try noResolverKeepsLinksAndCardChips(textKit2: true)
    }

    /// `-smartLinks off` passes no resolver (design §3, call #30): the
    /// library does no lookup work, the four bare intro links keep their
    /// URLs, and the inline card is the host-only chip it is on main — an
    /// atom, so its paragraph is word-chunked around it (no element reads
    /// "As an inline card: …") and, under TextKit 2, drawn by SwiftUI (no
    /// `tk2-row:` for it, while the bare links' paragraphs are TextKit 2
    /// rows). With a resolver, `testResolvesOnlyWhatIsOnScreen…` shows the
    /// same paragraph as one text run (a TextKit 2 row under TextKit 2).
    private func noResolverKeepsLinksAndCardChips(textKit2: Bool) throws {
        continueAfterFailure = true
        let arm = textKit2 ? "textkit2" : "swiftui"
        var arguments = ["-fixture", "smart-links", "-rendererReset", "-rendererStats", "-smartLinkProbe",
                         "-smartLinks", "off"]
        if textKit2 { arguments.append("-textkit2") }
        let reader = ReaderDriver(launching: arguments)
        reader.waitForRenderer(textKit2 ? "TextKit 2" : "SwiftUI")
        XCTAssertTrue(link(Self.intro[0], reader, textKit2: textKit2).waitForExistence(timeout: 20),
                      "the Roadmap intro link never appeared")
        // Longer than a dwell (150 ms) plus a default lookup (0.8 s): any
        // lookup would have started and ended by now.
        reader.pause(3)
        let stats = probe(reader, "no resolver (3 s after the intro appeared)")
        XCTAssertEqual(stats["calls"], 0, "the library looked a link up with no resolver: \(stats)")
        XCTAssertEqual(stats["inFlight"], 0, stats.description)
        XCTAssertEqual(stats["refreshes"], 0, "a smart-link leaf redrew with no resolver: \(stats)")
        XCTAssertEqual(stats["mockCalls"], -1, "a mock resolver exists under -smartLinks off: \(stats)")

        let bare = Array(Self.intro.dropLast())
        let labels = bare.map { item in
            let element = link(item, reader, textKit2: textKit2)
            return element.exists ? element.label : "missing"
        }
        XCTAssertEqual(labels, bare.map(\.plain), "a bare link changed with no resolver")

        // The chip: SwiftUI's `Link` around the chip's icon and text, which
        // XCUITest exposes as a button labelled exactly the host, holding
        // the chip's own text. (With a resolver the card's host is a link
        // run inside the paragraph's text: a `link` element, no children.)
        let chip = reader.app.buttons.matching(NSPredicate(format: "label == %@", Self.cardHost)).firstMatch
        let chipText = chip.staticTexts[Self.cardHost]
        let hostLinks = reader.app.links.matching(NSPredicate(format: "label == %@", Self.cardHost))
        note("\(arm) no resolver: chip button \(chip.exists), chip text \(chipText.exists), "
            + "link runs showing the host \(hostLinks.count); bare links \(labels)")
        XCTAssertTrue(chip.exists && chipText.exists, "no chip (a button holding the text \(Self.cardHost))")
        XCTAssertEqual(hostLinks.count, 0, "the card's host is a link run in text, not a chip")
        XCTAssertFalse(reader.element(labelPrefix: Self.cardLead).exists,
                       "the card's paragraph is one text run: the card was prepared as a smart link, not a chip")
        if textKit2 {
            XCTAssertFalse(reader.textKit2Row(labelPrefix: Self.cardLead).exists,
                           "the card's paragraph is a TextKit 2 row: its chip should keep it on SwiftUI")
        } else {
            XCTAssertFalse(reader.anyTextKit2Row.exists, "a TextKit 2 row exists on the SwiftUI renderer")
        }
        attach(reader.app, "\(arm)-no-resolver-chip")
    }

    /// Launches smart-links with the probe on.
    private func launch(textKit2: Bool, delay: Double, failureRate: Double) -> ReaderDriver {
        var arguments = ["-fixture", "smart-links", "-rendererReset", "-rendererStats", "-smartLinkProbe",
                         "-smartLinkDelay", String(delay), "-smartLinkFailureRate", String(failureRate)]
        if textKit2 { arguments.append("-textkit2") }
        let reader = ReaderDriver(launching: arguments)
        reader.waitForRenderer(textKit2 ? "TextKit 2" : "SwiftUI")
        return reader
    }

    /// Counter deltas between two probe reads.
    struct Window: CustomStringConvertible {
        let refreshes, leaves, segmented, engine, conversions, layouts, live: Int

        init(_ a: Stats, _ b: Stats) {
            refreshes = b["refreshes"] - a["refreshes"]
            leaves = b["leaves"] - a["leaves"]
            segmented = b["segmented"] - a["segmented"]
            engine = b["engine"] - a["engine"]
            conversions = b["conversions"] - a["conversions"]
            layouts = b["layouts"] - a["layouts"]
            live = b["live"] - a["live"]
        }

        /// Leaves built (not redrawn) in the window: SwiftUI's engine-leaf
        /// bodies, or TextKit 2's new live rows.
        var builtLeaves: Int { max(live, 0) + (conversions == 0 ? engine : 0) }

        var description: String {
            "refreshes Δ\(refreshes) leaf bodies Δ\(leaves) (SwiftUI Text Δ\(segmented), engine leaf Δ\(engine)) "
                + "TK2 conversions Δ\(conversions) layouts Δ\(layouts) live rows Δ\(live)"
        }
    }

    // MARK: - Perf: fling, scene thrash mid-resolution, idle soak

    func testFlingThrashSoakSwiftUI() throws {
        try flingThrashSoak(textKit2: false)
    }

    func testFlingThrashSoakTextKit2() throws {
        try flingThrashSoak(textKit2: true)
    }

    /// Lifecycle §3.5's shape on smart-links (`LifecycleUITests
    /// .flingThrashSoak`), with lookups in flight when the thrash starts
    /// (`-smartLinkDelay 8`, the default failure rate) and a 150 s soak once
    /// every lookup has finished.
    private func flingThrashSoak(textKit2: Bool) throws {
        let agent = try HostAgent.fromEnvironment()
        let arm = textKit2 ? "textkit2" : "swiftui"
        var arguments = ["-fixture", "smart-links", "-rendererReset", "-rendererStats", "-scenePhaseProbe",
                         "-smartLinkDelay", "8"]
        if textKit2 { arguments.append("-textkit2") }
        let reader = ReaderDriver(launching: arguments)
        let app = reader.app
        reader.waitForRenderer(textKit2 ? "TextKit 2" : "SwiftUI")
        XCTAssertTrue(reader.element(labelPrefix: Self.introLandmark).waitForExistence(timeout: 30), "smart-links missing")
        XCTAssertNotNil(scenePhases(app), "scene-phase-probe missing (-scenePhaseProbe)")

        let scroll = app.scrollViews.firstMatch
        for _ in 0 ..< 3 {
            scroll.swipeUp(velocity: .fast)
        }
        let fling = try agent.cpuSettleSeconds()

        // A short drag so the rows now on screen start their lookups, then
        // the thrash at once, while they run (8 s each, 4 at a time).
        let before = readStats(reader, Self.smartLinkFields, "\(arm) before the drag")
        reader.drag(by: 400)
        reader.pause(0.3)
        let thrashStart = Date()
        var unconfirmed: [String] = []
        for cycle in 0 ..< 5 {
            let confirmed = thrash(app)
            unconfirmed += Self.stops.filter { confirmed[$0] != true }.map { "\(cycle):\($0)" }
        }
        let thrashSeconds = Date().timeIntervalSince(thrashStart)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "app not in the foreground after thrash")
        let thrashSettle = try agent.cpuSettleSeconds()
        let rendererKept = reader.anyTextKit2Row.exists == textKit2

        // Every lookup finished (the thrash takes about a minute) before the soak.
        let after = readStats(reader, Self.smartLinkFields, "\(arm) after the thrash")
        let lookedUpDuringThrash = after["smartlink-stat-resolverCalls"] - before["smartlink-stat-resolverCalls"]
        let soak = try agent.request("soak", ["seconds": 150, "threshold_pct": 2.0], timeout: 300)
        let growth = soak["growth_kb"] as? Int ?? Int.max
        let cpuMean = soak["cpu_mean"] as? Double ?? .infinity
        let end = readStats(reader, Self.smartLinkFields, "\(arm) after the soak")

        let flingOK = (fling.seconds ?? .infinity) <= Self.maxSettleSeconds
        let thrashOK = (thrashSettle.seconds ?? .infinity) <= Self.maxSettleSeconds
        let quiet = after["smartlink-stat-inFlight"] == 0 && end["smartlink-stat-inFlight"] == 0
        let consistent = end["smartlink-stat-resolverCalls"] == end["smartlink-stat-resolved"]
            + end["smartlink-stat-failed"] + end["smartlink-stat-cancellations"] + end["smartlink-stat-inFlight"]
        let pass = flingOK && thrashOK && unconfirmed.isEmpty && growth <= Self.maxGrowthKB && cpuMean <= 2.0
            && rendererKept && quiet && consistent && lookedUpDuringThrash > 0
        try agent.record("SL fling + thrash mid-resolution + 150 s soak (smart-links, \(arm))", pass: pass, [
            "fling_settle_s": fling.seconds ?? -1, "thrash_settle_s": thrashSettle.seconds ?? -1,
            "fling_samples": fling.samples, "thrash_samples": thrashSettle.samples,
            "soak_growth_kb": growth, "soak_cpu_mean_pct": cpuMean, "soak_cpu_max_pct": soak["cpu_max"] ?? -1,
            "soak_cpu_samples": soak["cpu_samples"] ?? "none", "soak_start_kb": soak["start_kb"] ?? -1,
            "soak_end_kb": soak["end_kb"] ?? -1, "thrash_cycles": 5, "thrash_seconds": thrashSeconds,
            "unconfirmed_stops": unconfirmed, "renderer_rows_as_expected_after_thrash": rendererKept,
            "lookups_started_after_the_drag": lookedUpDuringThrash,
            "stats_before_drag": before.description, "stats_after_thrash": after.description,
            "stats_after_soak": end.description,
        ])
        XCTAssertGreaterThan(lookedUpDuringThrash, 0, "no lookup ran during the thrash: \(before) / \(after)")
        XCTAssertTrue(flingOK, "CPU did not settle within 5 s after the fling: \(fling.samples)")
        XCTAssertTrue(thrashOK, "CPU did not settle within 5 s after the thrash: \(thrashSettle.samples)")
        XCTAssertTrue(unconfirmed.isEmpty, "thrash stops the app's scene phases did not confirm: \(unconfirmed)")
        XCTAssertTrue(rendererKept, "renderer rows changed across the thrash")
        XCTAssertTrue(quiet, "lookups still in flight after the thrash or the soak: \(after) / \(end)")
        XCTAssertTrue(consistent, "the counters do not add up: \(end)")
        XCTAssertLessThanOrEqual(growth, Self.maxGrowthKB, "settled memory grew \(growth) KB over the soak")
        XCTAssertLessThanOrEqual(cpuMean, 2.0, "idle CPU averaged \(cpuMean) % over the soak")
    }

    private static let maxGrowthKB = 5 * 1_024
    private static let maxSettleSeconds = 5.0
    private static let stops = ["home", "locked", "switcher", "back"]

    /// One thrash cycle as `LifecycleUITests.thrash` runs it: Home and back,
    /// lock and unlock, app switcher and back, each confirmed by the app's
    /// own scene phases (`-scenePhaseProbe`).
    private func thrash(_ app: XCUIApplication) -> [String: Bool] {
        var confirmed: [String: Bool] = [:]
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func settled() -> ScenePhases? { waitForScenePhases(app) { $0.last == "active" } }
        func confirm(_ stop: String, _ left: (ScenePhases) -> Bool) {
            confirmed[stop] = waitForScenePhases(app, until: left).map(left) ?? false
        }

        var before = settled()
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 10)
        confirm("home") { [before] now in before.map { now.background > $0.background } ?? false }

        before = settled()
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        Thread.sleep(forTimeInterval: 1.5)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        let bottom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99))
        bottom.press(forDuration: 0.05, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 10)
        confirm("locked") { [before] now in before.map { now.background > $0.background } ?? false }

        before = settled()
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.995))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)),
                    withVelocity: .slow, thenHoldForDuration: 1.0)
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 10)
        confirm("switcher") { [before] now in
            before.map { now.background > $0.background || now.inactive > $0.inactive } ?? false
        }
        Thread.sleep(forTimeInterval: 0.5)
        confirm("back") { $0.last == "active" }
        return confirmed
    }

    /// The `-scenePhaseProbe` overlay's counts.
    private struct ScenePhases {
        var background = 0
        var inactive = 0
        var last = ""

        init?(_ label: String) {
            var fields: [String: String] = [:]
            for pair in label.split(separator: " ") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
            }
            guard let background = fields["background"].flatMap({ Int($0) }),
                  let inactive = fields["inactive"].flatMap({ Int($0) }),
                  let last = fields["last"] else { return nil }
            self.background = background
            self.inactive = inactive
            self.last = last
        }
    }

    private func scenePhases(_ app: XCUIApplication) -> ScenePhases? {
        let probe = app.staticTexts["scene-phase-probe"]
        guard probe.exists else { return nil }
        return ScenePhases(probe.label)
    }

    private func waitForScenePhases(_ app: XCUIApplication, timeout: TimeInterval = 5,
                                    until condition: (ScenePhases) -> Bool) -> ScenePhases?
    {
        let deadline = Date().addingTimeInterval(timeout)
        var phases: ScenePhases?
        repeat {
            phases = scenePhases(app)
            if let phases, condition(phases) { break }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return phases
    }

    // MARK: - Proof-video tour

    func testVideoTourSwiftUI() throws {
        try videoTour(textKit2: false)
    }

    func testVideoTourTextKit2() throws {
        try videoTour(textKit2: true)
    }

    /// Paced for `simctl io recordVideo`: the intro links resolve at the top,
    /// then six slow 400 pt drags (no fling momentum, down to about S04),
    /// each held 2 s, so every link that scrolls in is seen plain (an inline
    /// card as its host), dimmed while its 0.8 s lookup runs (4 at a time),
    /// then as an icon and its title. A slow drag takes 2–3 s to synthesise
    /// on a busy host, so the tour runs about 40 s.
    private func videoTour(textKit2: Bool) throws {
        var arguments = ["-fixture", "smart-links", "-rendererReset", "-smartLinkDelay", "0.8",
                         "-smartLinkFailureRate", "0"]
        if textKit2 { arguments.append("-textkit2") }
        let reader = ReaderDriver(launching: arguments)
        reader.waitForRenderer(textKit2 ? "TextKit 2" : "SwiftUI")
        let resolved = waitForLabels(reader, textKit2: textKit2, timeout: 20) { labels in
            zip(labels, Self.intro).allSatisfy { $0.1.showsTitle($0.0) }
        }
        XCTAssertTrue(resolved.met, "the intro links did not resolve: \(resolved.labels)")
        reader.pause(1.5)
        for step in 0 ..< 6 {
            reader.drag(by: 400)
            reader.pause(2.0)
            if step % 3 == 0 { attach(reader.app, "tour-\(textKit2 ? "textkit2" : "swiftui")-\(step)") }
        }
        print("SMARTLINK_UI tour done")
    }

    // MARK: - Reading the screen

    /// The element showing an intro link: under TextKit 2 its row
    /// (`tk2-row:<owner>`), under SwiftUI the paragraph's text.
    private func link(_ link: IntroLink, _ reader: ReaderDriver, textKit2: Bool) -> XCUIElement {
        textKit2 ? reader.textKit2Row(labelPrefix: link.lead) : reader.element(labelPrefix: link.lead)
    }

    /// The five intro links' labels, in order ("missing" when not found).
    private func currentLabels(_ reader: ReaderDriver, textKit2: Bool) -> [String] {
        Self.intro.map { item in
            let element = link(item, reader, textKit2: textKit2)
            return element.exists ? element.label : "missing"
        }
    }

    private func waitForLabels(_ reader: ReaderDriver, textKit2: Bool, timeout: TimeInterval,
                               until condition: ([String]) -> Bool) -> (met: Bool, labels: [String])
    {
        let deadline = Date().addingTimeInterval(timeout)
        var labels: [String] = []
        repeat {
            labels = currentLabels(reader, textKit2: textKit2)
            if condition(labels) { return (true, labels) }
            reader.pause(0.25)
        } while Date() < deadline
        return (false, labels)
    }

    /// How many of `labels` equal the intro links' text at `stage`.
    private static func count(_ labels: [String], _ stage: KeyPath<IntroLink, String>) -> Int {
        zip(labels, intro).filter { $0.0 == $0.1[keyPath: stage] }.count
    }

    /// About This Build counters, read top to bottom (`fields` in sheet
    /// order), each once two reads 250 ms apart agree; -1 when unreadable.
    struct Stats: CustomStringConvertible {
        var values: [String: Int] = [:]
        subscript(_ field: String) -> Int { values[field] ?? -1 }

        init() {}

        /// The probe's `key=value` line.
        init(probe line: String) {
            for pair in line.split(separator: " ") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2, let value = Int(parts[1]) { values[String(parts[0])] = value }
            }
        }

        var description: String {
            values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        }
    }

    /// Reads `fields` off About This Build (plus the live TextKit 2 row
    /// count at its top). Slow — one query per row, and rows below the
    /// sheet's fold are dragged into view — so only for reads at rest; the
    /// functional tests read `SmartLinkProbe` instead.
    private func readStats(_ reader: ReaderDriver, _ fields: [String], _ name: String) -> Stats {
        reader.openAbout()
        var stats = Stats()
        stats.values[Self.liveRows] = reader.readCount(Self.liveRows, until: { _ in true }, settled: true)
        let window = reader.app.windows.firstMatch.frame
        let start = reader.app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window.midX, dy: window.minY + window.height * 0.75))
        for field in fields {
            let element = reader.app.staticTexts[field]
            var drags = 0
            // Never back up: rows are read top to bottom, and each drag is
            // shorter than the sheet, so no row is skipped.
            while !element.exists, drags < 12 {
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -280)),
                            withVelocity: .slow, thenHoldForDuration: 0.2)
                drags += 1
            }
            stats.values[field] = reader.readCount(field, until: { _ in true }, settled: true)
        }
        reader.closeAbout()
        note("STATS \(name): \(stats)")
        return stats
    }

    /// One consistent read of every counter (`SmartLinkProbe`), taken once
    /// two reads 300 ms apart agree.
    private func probe(_ reader: ReaderDriver, _ name: String) -> Stats {
        let element = reader.app.staticTexts[Self.probeID]
        XCTAssertTrue(element.waitForExistence(timeout: 5), "smartlink-probe missing (-smartLinkProbe)")
        var previous = Stats(probe: element.label)
        var stats = previous
        for _ in 0 ..< 10 {
            reader.pause(0.3)
            stats = Stats(probe: element.label)
            if stats.values == previous.values { break }
            previous = stats
        }
        note("PROBE \(name): \(stats)")
        return stats
    }

    /// Polls the probe until `condition` holds (then, with `settle`, waits
    /// that long and reads it once more); returns the last read.
    private func waitForProbe(_ reader: ReaderDriver, _ name: String, timeout: TimeInterval, settle: TimeInterval = 0,
                              until condition: (Stats) -> Bool) -> (met: Bool, stats: Stats)
    {
        let element = reader.app.staticTexts[Self.probeID]
        XCTAssertTrue(element.waitForExistence(timeout: 5), "smartlink-probe missing (-smartLinkProbe)")
        let deadline = Date().addingTimeInterval(timeout)
        var stats = Stats(probe: element.label)
        var met = condition(stats)
        while !met, Date() < deadline {
            reader.pause(0.2)
            stats = Stats(probe: element.label)
            met = condition(stats)
        }
        if met, settle > 0 {
            reader.pause(settle)
            stats = probe(reader, name)
            met = condition(stats)
        } else {
            note("PROBE \(name): \(stats)\(met ? "" : " (condition not met)")")
        }
        return (met, stats)
    }

    // MARK: - Scrolling, notes, attachments

    private func scrollToTop(_ reader: ReaderDriver) {
        let scroll = reader.app.scrollViews.firstMatch
        let landmark = reader.element(labelPrefix: Self.introLandmark)
        var swipes = 0
        while !reader.isVisible(landmark), swipes < 25 {
            scroll.swipeDown(velocity: .fast)
            swipes += 1
            reader.pause(0.3)
        }
        XCTAssertTrue(reader.isVisible(landmark), "could not scroll back to the top")
    }

    private func elapsed(since start: Date) -> String {
        String(format: "%.1f s after launch", Date().timeIntervalSince(start))
    }

    /// Logged for the result bundle and printed for the xcodebuild log
    /// (`SMARTLINK_UI …`).
    private func note(_ text: String) {
        print("SMARTLINK_UI \(text)")
        XCTContext.runActivity(named: text) { _ in }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
