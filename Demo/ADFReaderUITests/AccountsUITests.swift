import XCTest

/// Settings → Atlassian Accounts, offline: the empty state with both ways to
/// add an account, and the manual form rejecting a site that is not
/// `<name>.atlassian.net` with the site normalizer's message — before any
/// network call, so no token is involved.
///
/// Launch arguments: `-openAccounts` opens the Settings sheet already on
/// Atlassian Accounts; `-accountsInMemory` (Debug only) keeps accounts in
/// memory, so the list starts empty whatever a previous run left in the
/// simulator's keychain.
@MainActor
final class AccountsUITests: XCTestCase {
    private enum Identifier {
        static let empty = "accounts-empty"
        static let addManual = "accounts-add-manual"
        static let scanFromMac = "accounts-scan-mac"
        static let site = "add-site"
        static let connect = "add-connect"
        static let error = "add-error"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEmptyStateAndManualFormRejectsUnsupportedSite() throws {
        let app = ReaderDriver(launching: ["-openAccounts", "-accountsInMemory"]).app

        let empty = app.descendants(matching: .any)[Identifier.empty]
        XCTAssertTrue(empty.waitForExistence(timeout: 30), "Atlassian Accounts did not open on its empty state")
        XCTAssertTrue(app.buttons[Identifier.addManual].exists, "Add Manually button missing")
        XCTAssertTrue(app.buttons[Identifier.scanFromMac].exists, "Scan from Mac button missing")

        app.buttons[Identifier.addManual].tap()
        let site = app.textFields[Identifier.site]
        XCTAssertTrue(site.waitForExistence(timeout: 10), "Add Manually form did not open")
        site.tap()
        site.typeText("confluence.example.com")

        app.buttons[Identifier.connect].tap()
        let error = app.descendants(matching: .any)[Identifier.error]
        XCTAssertTrue(error.waitForExistence(timeout: 10), "no inline error for an unsupported site")
        XCTAssertTrue(
            error.label.contains("Only <name>.atlassian.net sites are supported for now"),
            "unexpected error text: \(error.label)"
        )
    }
}
