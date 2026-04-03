@preconcurrency import AXorcist
import ApplicationServices
import Foundation
import XCTest

/// Base class for UI tests designed to be debugged by AI agents.
///
/// Every snap captures:
/// - A screenshot (PNG) per window
/// - A compact accessibility tree (TXT) — concise, AI-readable
///
/// Example tree output:
/// ```
/// AXApplication "Safari"
///   AXWindow "Example Domain"
///     AXToolbar
///       AXButton "Back"
///       AXTextField value="https://example.com"
///     AXWebArea
///       AXHeading "Example Domain"
///       AXStaticText "This domain is for use in illustrative examples"
/// ```
open class JourneyTestCase: XCTestCase {

    // MARK: - Override points

    open var journeyName: String { fatalError("Subclass must override journeyName") }
    open var appBundleID: String? { nil }

    /// Max depth for AX tree traversal. Default 8 balances detail vs noise.
    open var axTreeDepth: Int { 8 }

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
        return "\(NSHomeDirectory())/.journeytester"
    }

    // MARK: - Setup / Teardown

    override open func setUpWithError() throws {
        continueAfterFailure = false

        let trusted = MainActor.assumeIsolated {
            AXTrustUtil.checkAccessibilityPermissions(promptIfNeeded: true)
        }
        if !trusted {
            MainActor.assumeIsolated { AXTrustUtil.openAccessibilitySettings() }
            XCTFail("""
                ⚠️  Accessibility permission required.

                JourneyTester uses the macOS Accessibility API (AXorcist) to capture
                the UI element tree for AI-debuggable test output.

                Please grant Accessibility access to the test runner:
                  System Settings → Privacy & Security → Accessibility
                  → Enable your test runner app (e.g. SafariUITests-Runner)

                Then re-run the tests. This is a one-time setup.
                """)
            return
        }

        try? FileManager.default.removeItem(atPath: artifactDir)
        try? FileManager.default.createDirectory(
            atPath: artifactDir, withIntermediateDirectories: true)

        app.launch()

        if app.windows.count == 0 {
            app.typeKey("n", modifierFlags: .command)
        }

        lastSnapDate = Date()
        startWatchdog()

        let resolvedPath = (artifactDir as NSString).resolvingSymlinksInPath
        print("📂 JourneyTester artifacts: \(resolvedPath)")
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

    public func snap(_ label: String) {
        screenshotIndex += 1
        lastSnapDate = Date()

        let prefix = String(format: "%03d", screenshotIndex)
        let tag = "\(prefix)-\(label)"

        captureScreenshots(tag: tag)

        app.activate()

        let tree = dumpAXTree()
        writeArtifact("\(tag)-axtree.txt", content: tree)
    }

    // MARK: - Wait + Assert helpers

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

    public func axQuery(
        role: String? = nil,
        title: String? = nil,
        identifier: String? = nil
    ) -> AXResponse {
        app.activate()

        return MainActor.assumeIsolated {
            var filter: [String: String] = [:]
            if let role { filter["AXRole"] = role }
            if let title { filter["AXTitle"] = title }
            if let identifier { filter["AXIdentifier"] = identifier }

            let cmd = CollectAllCommand(
                appIdentifier: nil,
                maxDepth: axTreeDepth,
                filterCriteria: filter.isEmpty ? nil : filter
            )
            let envelope = AXCommandEnvelope(
                commandID: "journey-query-\(screenshotIndex)",
                command: .collectAll(cmd)
            )
            let response = AXorcist.shared.runCommand(envelope)

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

    // MARK: - AXorcist compact tree dump

    /// Builds a compact, indented text tree of the focused app's AX hierarchy.
    ///
    /// Output looks like:
    /// ```
    /// AXWindow "Example Domain"
    ///   AXToolbar
    ///     AXButton "Back"
    ///     AXTextField value="https://example.com"
    ///   AXWebArea
    ///     AXHeading "Example Domain"
    /// ```
    ///
    /// Only shows role + the first meaningful label (title > value > identifier).
    /// Skips noise roles (AXGroup, AXGeneric) that have no label and only one child.
    public func dumpAXTree() -> String {
        MainActor.assumeIsolated {
            guard let root = Element.focusedApplication() else {
                return "// AX tree unavailable — no focused application"
            }

            var lines: [String] = []
            var visited = Set<UInt>()
            buildCompactTree(element: root, depth: 0, maxDepth: axTreeDepth,
                             lines: &lines, visited: &visited)
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Artifact writing

    public func writeArtifact(_ filename: String, content: String) {
        let path = "\(artifactDir)/\(filename)"
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Private: compact tree builder

    /// Roles that are pure layout noise — skip if unlabeled (promote children).
    private static let noiseRoles: Set<String> = [
        "AXGroup", "AXGeneric", "AXSection", "AXArticle",
        "AXLayoutArea", "AXLayoutItem", "AXSplitGroup",
    ]

    /// Max children shown per parent before truncating with "... and N more".
    private static let maxChildrenShown = 5

    @MainActor
    private func buildCompactTree(
        element: Element,
        depth: Int,
        maxDepth: Int,
        lines: inout [String],
        visited: inout Set<UInt>
    ) {
        guard depth <= maxDepth else { return }

        let hash = CFHash(element.underlyingElement)
        guard visited.insert(hash).inserted else { return }

        let role = element.role() ?? "AXUnknown"
        let title = element.title()
        let value: String? = {
            if let v: String = element.attribute(Attribute<String>("AXValue")),
               !v.isEmpty, v.count < 200 { return v }
            return nil
        }()
        let identifier = element.identifier()

        let children = element.children(strict: true) ?? []

        let hasLabel = (title != nil && title?.isEmpty == false)
            || value != nil
            || (identifier != nil && identifier?.isEmpty == false)

        // Skip noise containers that add no information — promote children
        if Self.noiseRoles.contains(role), !hasLabel {
            for (i, child) in children.enumerated() {
                if i >= Self.maxChildrenShown {
                    let indent = String(repeating: "  ", count: depth)
                    lines.append("\(indent)... and \(children.count - Self.maxChildrenShown) more")
                    break
                }
                buildCompactTree(element: child, depth: depth, maxDepth: maxDepth,
                                 lines: &lines, visited: &visited)
            }
            return
        }

        // Build line: "  AXButton "Save" id=save-btn"
        let indent = String(repeating: "  ", count: depth)
        var line = "\(indent)\(role)"

        if let t = title, !t.isEmpty {
            line += " \"\(t.prefix(80))\""
        }
        if let v = value, !v.isEmpty, v != title {
            line += " value=\"\(v.prefix(80))\""
        }
        if let id = identifier, !id.isEmpty {
            line += " id=\(id.prefix(60))"
        }

        lines.append(line)

        // Truncate long child lists (bookmarks, table rows, etc.)
        for (i, child) in children.enumerated() {
            if i >= Self.maxChildrenShown {
                let remaining = children.count - Self.maxChildrenShown
                lines.append("\(indent)  ... and \(remaining) more children")
                break
            }
            buildCompactTree(element: child, depth: depth + 1, maxDepth: maxDepth,
                             lines: &lines, visited: &visited)
        }
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
