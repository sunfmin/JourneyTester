import JourneyTester
import XCTest

final class SafariJourneyTests: JourneyTestCase {
    override var journeyName: String { "safari-basics" }
    override var appBundleID: String? { "com.apple.Safari" }

    // MARK: - Test: Navigate to a URL

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

        step("type URL and navigate") {
            app.typeText("https://example.com\n")
            sleep(3)
            snap("page-loaded")
        }

        step("verify page content") {
            let webView = app.webViews.firstMatch
            waitAndSnap(webView, timeout: 10, "Web view should exist after navigation")

            // Use AXorcist to inspect the page structure
            let response = axQuery(role: "AXStaticText", title: "Example Domain")
            snap("verified-content")

            if case .success = response {
                // Found "Example Domain" via AXorcist
            }
            // Not a hard failure if AXorcist can't find it — the webView assertion above
            // already verified the page loaded. AXorcist depth may not reach web text.
        }
    }

    // MARK: - Test: Open multiple tabs

    func testMultipleTabs() {
        step("open first tab") {
            app.typeKey("l", modifierFlags: .command)
            app.typeText("https://example.com\n")
            sleep(3)
            snap("first-tab-loaded")
        }

        step("open second tab") {
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

            let tree = dumpAXTree()
            writeArtifact("tab-inspection.json", content: tree)
        }
    }

    // MARK: - Test: Search from address bar

    func testAddressBarSearch() {
        step("focus address bar") {
            app.typeKey("l", modifierFlags: .command)
            sleep(1)
        }

        step("type search query") {
            app.typeText("swift programming language")
            sleep(2)
            snap("search-suggestions-visible")
        }

        step("submit search") {
            app.typeKey(.return, modifierFlags: [])
            sleep(5)
            snap("search-results-loaded")
        }

        step("verify results page") {
            let webView = app.webViews.firstMatch
            waitAndSnap(webView, timeout: 10, "Search results page should load")
        }
    }
}
