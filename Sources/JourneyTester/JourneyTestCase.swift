@preconcurrency import AXorcist
import Foundation
import XCTest

/// Base class for UI tests designed to be debugged by AI agents.
///
/// Every snap captures:
/// - A screenshot (PNG) per window
/// - The AXorcist accessibility tree (JSON) — structured, machine-parseable
///
/// The AX tree depth is capped (default 3) so even huge apps like Safari
/// won't crash the test runner. Increase via `axTreeDepth` when testing
/// smaller apps.
///
/// ## Usage
/// ```swift
/// final class LoginTests: JourneyTestCase {
///     override var journeyName: String { "login" }
///     override var appBundleID: String? { "com.apple.Safari" }
///
///     func testLoginFlow() {
///         step("tap login button") {
///             let btn = app.buttons["Login"]
///             waitAndSnap(btn, "Login button should exist")
///             btn.tap()
///         }
///     }
/// }
/// ```
open class JourneyTestCase: XCTestCase {

    // MARK: - Override points

    /// Name of this journey. Used as the folder name for artifacts.
    open var journeyName: String { fatalError("Subclass must override journeyName") }

    /// Bundle identifier of the app under test.
    open var appBundleID: String? { nil }

    /// Max depth for AXorcist tree collection.
    /// Override to go deeper or shallower depending on the app.
    open var axTreeDepth: Int { 10 }

    // MARK: - Public state

    nonisolated(unsafe) public lazy var app: XCUIApplication = {
        MainActor.assumeIsolated {
            if let bundleID = appBundleID {
                return XCUIApplication(bundleIdentifier: bundleID)
            }
            return XCUIApplication()
        }
    }()

    public private(set) var screenshotIndex = 0

    // MARK: - Directories

    public var journeyDir: String {
        "\(outputRoot)/journeys/\(journeyName)"
    }

    public var artifactDir: String {
        "\(journeyDir)/artifacts"
    }

    // MARK: - Private state

    private var lastSnapDate = Date()
    private var watchdogTimer: Timer?

    private var outputRoot: String {
        if let env = ProcessInfo.processInfo.environment["JOURNEY_TESTER_OUTPUT"] {
            return env
        }
        return "\(projectRoot)/.journeytester"
    }

    private var projectRoot: String {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent().path
    }

    // MARK: - Setup / Teardown

    override open func setUpWithError() throws {
        continueAfterFailure = false

        try? FileManager.default.removeItem(atPath: artifactDir)
        try? FileManager.default.createDirectory(
            atPath: artifactDir, withIntermediateDirectories: true)

        app.launch()

        if app.windows.count == 0 {
            app.typeKey("n", modifierFlags: .command)
        }

        lastSnapDate = Date()
        startWatchdog()
    }

    override open func tearDownWithError() throws {
        watchdogTimer?.invalidate()
        watchdogTimer = nil

        if let failure = testRun?.failureCount, failure > 0 {
            snap("TEARDOWN-AFTER-FAILURE")
        }

        app.terminate()
    }

    // MARK: - Steps

    /// Wraps a test phase with a name. Captures artifacts on entry; on failure
    /// the step name appears in artifact filenames for easy diagnosis.
    public func step(_ name: String, file: StaticString = #file, line: UInt = #line, _ body: () throws -> Void) {
        let safeName = sanitize(name)
        snap("step-\(safeName)-begin")

        do {
            try body()
        } catch {
            snap("FAIL-step-\(safeName)")
            XCTFail("Step '\(name)' failed: \(error)", file: file, line: line)
        }
    }

    // MARK: - Snap

    /// Captures screenshots + AXorcist tree, written to the artifact directory.
    public func snap(_ label: String) {
        screenshotIndex += 1
        lastSnapDate = Date()

        let prefix = String(format: "%03d", screenshotIndex)
        let tag = "\(prefix)-\(label)"

        captureScreenshots(tag: tag)

        let tree = dumpAXTree()
        writeArtifact("\(tag)-axtree.json", content: tree)
    }

    // MARK: - Wait + Assert helpers

    /// Waits for an element to exist. On failure: screenshots + AX tree + inline tree in XCTFail.
    public func waitAndSnap(
        _ element: XCUIElement,
        timeout: TimeInterval = 5,
        _ message: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        snap("wait-\(sanitize(element.identifier))")

        let found = element.waitForExistence(timeout: timeout)

        if !found {
            snap("FAIL-\(sanitize(element.identifier))")

            XCTFail("""
                \(message)

                Element '\(element.identifier)' not found after \(timeout)s.
                Artifacts: \(artifactDir)/
                """, file: file, line: line)
        }
    }

    /// Asserts an element exists right now, snapping on failure.
    public func assertExists(
        _ element: XCUIElement,
        _ message: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        if !element.exists {
            snap("FAIL-assertExists-\(sanitize(element.identifier))")

            XCTFail("""
                \(message)

                Element '\(element.identifier)' does not exist.
                Artifacts: \(artifactDir)/
                """, file: file, line: line)
        }
    }

    /// Query AXorcist for an element by role/title/identifier.
    ///
    /// Uses `collectAll` internally (which is Safari-safe) then filters results,
    /// rather than the `query` command whose traversal path crashes on Safari.
    public func axQuery(
        role: String? = nil,
        title: String? = nil,
        identifier: String? = nil
    ) -> AXResponse {
        MainActor.assumeIsolated {
            // Build filter criteria as [String: String] for collectAll
            var filter: [String: String] = [:]
            if let role { filter["AXRole"] = role }
            if let title { filter["AXTitle"] = title }
            if let identifier { filter["AXIdentifier"] = identifier }

            let cmd = CollectAllCommand(
                appIdentifier: appBundleID,
                maxDepth: axTreeDepth,
                filterCriteria: filter.isEmpty ? nil : filter
            )
            let envelope = AXCommandEnvelope(
                commandID: "journey-query-\(screenshotIndex)",
                command: .collectAll(cmd)
            )
            let response = AXorcist.shared.runCommand(envelope)

            // Convert collectAll response: if elements found → success, else error
            if case .success(let payload, _) = response,
               let payload,
               let dict = payload.value as? [String: Any],
               let count = dict["count"] as? Int, count > 0
            {
                return response
            } else if case .error = response {
                return response
            } else {
                let desc = filter.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                return .errorResponse(
                    message: "No elements found matching [\(desc)]",
                    code: .elementNotFound
                )
            }
        }
    }

    // MARK: - AXorcist tree dump

    /// Collects the AXorcist accessibility tree, depth-capped to `axTreeDepth`.
    /// Returns pretty-printed JSON.
    public func dumpAXTree() -> String {
        MainActor.assumeIsolated {
            let cmd = CollectAllCommand(appIdentifier: appBundleID, maxDepth: axTreeDepth)
            let envelope = AXCommandEnvelope(
                commandID: "journey-dump-\(screenshotIndex)",
                command: .collectAll(cmd)
            )
            let response = AXorcist.shared.runCommand(envelope)

            switch response {
            case .success(let payload, _):
                if let payload {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    if let data = try? encoder.encode(payload),
                       let json = String(data: data, encoding: .utf8)
                    {
                        return json
                    }
                }
                return "{\"status\": \"success\", \"note\": \"no payload\"}"
            case .error(let message, let code, _):
                return "{\"status\": \"error\", \"code\": \"\(code.rawValue)\", \"message\": \"\(message)\"}"
            }
        }
    }

    // MARK: - Artifact writing

    public func writeArtifact(_ filename: String, content: String) {
        let path = "\(artifactDir)/\(filename)"
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Private helpers

    private func captureScreenshots(tag: String) {
        let windowCount = app.windows.count
        for i in 0..<windowCount {
            let window = app.windows.element(boundBy: i)
            guard window.exists else { continue }

            let screenshot: XCUIScreenshot
            do {
                screenshot = try XCTContext.runActivity(named: "snap-w\(i)") { _ in
                    window.screenshot()
                }
            } catch {
                continue
            }

            let suffix = windowCount > 1 ? "-w\(i)" : ""
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "\(journeyName)-\(tag)\(suffix)"
            attachment.lifetime = .keepAlways
            add(attachment)

            let pngPath = "\(artifactDir)/\(tag)\(suffix).png"
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: pngPath))
        }
    }

    private func sanitize(_ text: String) -> String {
        String(text.prefix(30))
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdogTimer = Timer.scheduledTimer(
            withTimeInterval: 3.0, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.app.windows.count > 0,
                      self.app.windows.firstMatch.exists else { return }
                let gap = Date().timeIntervalSince(self.lastSnapDate)
                if gap > 10 {
                    self.snap("watchdog")
                }
            }
        }
    }
}
