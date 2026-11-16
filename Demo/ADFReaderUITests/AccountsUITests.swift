import XCTest

/// Settings → Atlassian Accounts, offline: both ways to add an account, and
/// the manual form rejecting a site that is not `<name>.atlassian.net` with
/// the site normalizer's message — before any network call, so no token is
/// involved and nothing is saved.
///
/// Launch arguments: `-openAccounts` opens the Settings sheet already on
/// Atlassian Accounts.
@MainActor
final class AccountsUITests: XCTestCase {
    private enum Identifier {
        static let addManual = "accounts-add-manual"
        static let scanFromMac = "accounts-scan-mac"
        static let site = "add-site"
        static let connect = "add-connect"
        static let error = "add-error"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testManualFormRejectsUnsupportedSite() throws {
        let app = ReaderDriver(launching: ["-openAccounts"]).app

        XCTAssertTrue(app.buttons[Identifier.addManual].waitForExistence(timeout: 30), "Atlassian Accounts did not open with Add Manually")
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
