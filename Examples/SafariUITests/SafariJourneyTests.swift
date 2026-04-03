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

        step("switch to iPhone tab") {
            app.typeKey("1", modifierFlags: [.command])
            sleep(1)
            snap("back-to-iphone")
        }

        step("switch to Mac tab") {
            app.typeKey("2", modifierFlags: [.command])
            sleep(1)
            snap("back-to-mac")
        }

        step("switch to iPad tab") {
            app.typeKey("3", modifierFlags: [.command])
            sleep(1)
            snap("back-to-ipad")
        }

        step("search apple store", timeout: 20, slowOkReason: "waiting for search results") {
            app.typeKey("l", modifierFlags: .command)
            sleep(1)
            app.typeText("https://www.apple.com/shop\n")
            let webView = app.webViews.firstMatch
            waitAndSnap(webView, timeout: 15, "Apple Store should load")
            snap("apple-store")
        }
    }
}
