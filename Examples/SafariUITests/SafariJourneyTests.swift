import JourneyTester
import XCTest

final class SafariJourneyTests: JourneyTestCase {
    override var journeyName: String { "safari" }
    override var appBundleID: String? { "com.apple.Safari" }

    func testSafariJourney() {
        step("navigate to apple.com", timeout: 15, slowOkReason: "page loading") {
            app.typeKey("l", modifierFlags: .command)
            sleep(1)
            app.typeText("https://www.apple.com\n")
            let webView = app.webViews.firstMatch
            waitAndSnap(webView, timeout: 10, "Apple homepage should load")
            snap("apple-homepage")
        }

        step("go to iPhone page", timeout: 15, slowOkReason: "page loading") {
            app.typeKey("l", modifierFlags: .command)
            sleep(1)
            app.typeText("https://www.apple.com/iphone\n")
            sleep(3)
            snap("iphone-page")
        }

        step("go to Mac page in new tab", timeout: 15, slowOkReason: "page loading") {
            app.typeKey("t", modifierFlags: .command)
            sleep(1)
            app.typeText("https://www.apple.com/mac\n")
            sleep(3)
            snap("mac-page")
        }

        step("go to iPad page in new tab", timeout: 15, slowOkReason: "page loading") {
            app.typeKey("t", modifierFlags: .command)
            sleep(1)
            app.typeText("https://www.apple.com/ipad\n")
            sleep(3)
            snap("ipad-page")
        }

        step("switch between tabs", timeout: 10, slowOkReason: "switching tabs") {
            app.typeKey("1", modifierFlags: [.command])
            sleep(1)
            snap("back-to-iphone")

            app.typeKey("2", modifierFlags: [.command])
            sleep(1)
            snap("back-to-mac")

            app.typeKey("3", modifierFlags: [.command])
            sleep(1)
            snap("back-to-ipad")
        }

        step("navigate to apple store", timeout: 20, slowOkReason: "waiting for store page") {
            app.typeKey("l", modifierFlags: .command)
            sleep(1)
            app.typeText("https://www.apple.com/shop\n")
            let webView = app.webViews.firstMatch
            waitAndSnap(webView, timeout: 15, "Apple Store should load")
            snap("apple-store")
        }
    }

    func testWaitGoneAndSnap() {
        // Type in address bar to trigger autocomplete suggestions,
        // then press Escape and verify the suggestions disappear.

        step("navigate to a page first", timeout: 15, slowOkReason: "page loading") {
            app.typeKey("l", modifierFlags: .command)
            sleep(1)
            app.typeText("https://www.apple.com\n")
            let webView = app.webViews.firstMatch
            waitAndSnap(webView, timeout: 10, "Page should load")
        }

        step("type to trigger suggestions", timeout: 10, slowOkReason: "waiting for suggestions to appear") {
            app.typeKey("l", modifierFlags: .command)
            sleep(1)
            app.typeText("goo")
            sleep(2)
            snap("after-typing")

            // The suggestions popup is a separate list below the address bar.
            // Look for any element that appears when typing in the address bar.
            let addressField = app.textFields.firstMatch
            XCTAssertTrue(addressField.exists, "Address field should exist")
            snap("suggestions-should-be-visible")
        }

        step("press escape and verify suggestions disappear", timeout: 10, slowOkReason: "waiting for UI to settle") {
            // Before escape — address field should have our text
            let addressField = app.textFields.firstMatch
            XCTAssertTrue(addressField.exists)

            app.typeKey(.escape, modifierFlags: [])
            sleep(1)
            snap("after-first-escape")

            // After escape, the address field value should revert to the URL.
            // If we press escape again, the address bar loses focus entirely.
            app.typeKey(.escape, modifierFlags: [])

            // Wait for the text field to lose focus (it may still exist but value changes)
            // Use waitGoneAndSnap on a dynamic element: the "goo" typed text
            let typedText = app.staticTexts["goo"]
            waitGoneAndSnap(typedText, timeout: 5, "Typed text 'goo' should disappear after escape")
            snap("suggestions-dismissed")
        }
    }
}
