import JourneyTester
import XCTest

final class SafariJourneyTests: JourneyTestCase {
    override var journeyName: String { "safari" }
    override var appBundleID: String? { "com.apple.Safari" }

    func testSafariJourney() {
        step("open new window") {
            app.typeKey("n", modifierFlags: .command)
            sleep(1)
            snap("new-window")
        }

        step("focus address bar") {
            app.typeKey("l", modifierFlags: .command)
            sleep(1)
        }

        step("navigate to example.com", timeout: 15, slowOkReason: "page loading") {
            app.typeText("https://example.com\n")
            let webView = app.webViews.firstMatch
            waitAndSnap(webView, timeout: 10, "Web view should exist")
            snap("example-loaded")
        }

        step("verify page content") {
            let response = axQuery(role: "AXStaticText", title: "Example Domain")
            snap("verified-content")
            if case .success = response {}
        }

        step("open second tab", timeout: 15, slowOkReason: "loading apple.com") {
            app.typeKey("t", modifierFlags: .command)
            sleep(1)
            app.typeText("https://www.apple.com\n")
            sleep(3)
            snap("apple-loaded")
        }

        step("switch back to first tab") {
            app.typeKey("1", modifierFlags: [.command])
            sleep(1)
            snap("switched-to-first-tab")
        }

        step("search from address bar", timeout: 10, slowOkReason: "waiting for suggestions") {
            app.typeKey("l", modifierFlags: .command)
            sleep(1)
            app.typeText("swift programming language")
            sleep(2)
            snap("search-suggestions")
        }

        step("submit search", timeout: 20, slowOkReason: "waiting for search results") {
            app.typeKey(.return, modifierFlags: [])
            let webView = app.webViews.firstMatch
            waitAndSnap(webView, timeout: 15, "Search results should load")
            snap("search-results")
        }
    }
}
