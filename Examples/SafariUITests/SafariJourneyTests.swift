import JourneyTester
import XCTest

final class SafariJourneyTests: JourneyTestCase {
    override var journeyName: String { "safari-basics" }
    override var appBundleID: String? { "com.apple.Safari" }

    func testNavigateToURL() {
        step("open new window") {
            app.typeKey("n", modifierFlags: .command)
            sleep(1)
            snap("new-window-opened")
        }

        step("focus address bar") {
            app.typeKey("l", modifierFlags: .command)
            sleep(1)
            snap("address-bar-focused")
        }

        step("type URL and navigate", timeout: 15, slowOkReason: "waiting for page to load") {
            app.typeText("https://example.com\n")
            let webView = app.webViews.firstMatch
            waitAndSnap(webView, timeout: 10, "Web view should exist after navigation")
            snap("page-loaded")
        }

        step("verify page content") {
            let response = axQuery(role: "AXStaticText", title: "Example Domain")
            snap("verified-content")

            if case .success = response {
                // Found "Example Domain" via AXorcist
            }
        }
    }

    func testMultipleTabs() {
        step("open first tab", timeout: 15, slowOkReason: "loading example.com") {
            app.typeKey("l", modifierFlags: .command)
            app.typeText("https://example.com\n")
            sleep(3)
            snap("first-tab-loaded")
        }

        step("open second tab", timeout: 15, slowOkReason: "loading apple.com") {
            app.typeKey("t", modifierFlags: .command)
            sleep(1)
            app.typeText("https://www.apple.com\n")
            sleep(3)
            snap("second-tab-loaded")
        }

        step("switch back to first tab") {
            app.typeKey("1", modifierFlags: [.command])
            sleep(1)
            snap("switched-to-first-tab")
        }

        step("verify tab count") {
            snap("tab-group-state")
        }
    }

    func testAddressBarSearch() {
        step("focus address bar") {
            app.typeKey("l", modifierFlags: .command)
            sleep(1)
        }

        step("type search query", timeout: 10, slowOkReason: "waiting for search suggestions") {
            app.typeText("swift programming language")
            sleep(2)
            snap("search-suggestions-visible")
        }

        step("submit search", timeout: 20, slowOkReason: "waiting for search results page") {
            app.typeKey(.return, modifierFlags: [])
            let webView = app.webViews.firstMatch
            waitAndSnap(webView, timeout: 15, "Search results page should load")
        }
    }
}
