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

        // With the keyboard up, Connect sits below its top edge, so a tap at
        // Connect's frame would hit the keyboard. Scroll it clear first, as a
        // person would.
        let connect = app.buttons[Identifier.connect]
        let form = app.collectionViews.firstMatch
        for _ in 0..<4 where !isClearOfKeyboard(connect, in: app) {
            form.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(isClearOfKeyboard(connect, in: app), "Connect stayed under the keyboard")
        connect.tap()
        let error = app.descendants(matching: .any)[Identifier.error]
        XCTAssertTrue(error.waitForExistence(timeout: 10), "no inline error for an unsupported site")
        XCTAssertTrue(
            error.label.contains("Only <name>.atlassian.net sites are supported for now"),
            "unexpected error text: \(error.label)"
        )
    }

    private func isClearOfKeyboard(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return true }
        return element.frame.maxY <= keyboard.frame.minY
    }
}
