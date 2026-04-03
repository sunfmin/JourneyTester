@preconcurrency import AXorcist
import ApplicationServices
import Foundation
import XCTest

/// Base class for UI tests designed to be debugged by AI agents.
///
/// Every `snap()` captures per window:
/// - A screenshot (PNG)
/// - A compact accessibility tree (TXT)
///
/// If no `snap()` is called for 10+ seconds, a watchdog auto-captures
/// both artifacts so AI always has context even if a test hangs.
open class JourneyTestCase: XCTestCase {

    // MARK: - Override points

    open var journeyName: String { fatalError("Subclass must override journeyName") }
    open var appBundleID: String? { nil }

    /// Max depth for AX tree traversal.
    open var axTreeDepth: Int { 8 }

    /// Seconds without a `snap()` before the watchdog fails the test. Default 10.
    open var watchdogTimeout: TimeInterval { 10 }

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

    /// Captures screenshots + AX tree per window.
    public func snap(_ label: String) {
        screenshotIndex += 1
        lastSnapDate = Date()

        let prefix = String(format: "%03d", screenshotIndex)
        let tag = "\(prefix)-\(label)"

        captureScreenshots(tag: tag)
        app.activate()

        // Dump each window as a separate file
        dumpPerWindow(tag: tag)
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

    // MARK: - Artifact writing

    public func writeArtifact(_ filename: String, content: String) {
        let path = "\(artifactDir)/\(filename)"
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Per-window AX tree dump

    /// Dumps each window's AX tree into a separate file:
    ///   006-page-loaded-w0-axtree.txt  (or just -axtree.txt if single window)
    private func dumpPerWindow(tag: String) {
        MainActor.assumeIsolated {
            guard let appElement = Element.focusedApplication() else {
                writeArtifact("\(tag)-axtree.txt", content: "// no focused application")
                return
            }

            // Get windows via kAXWindowsAttribute
            let windows: [AXUIElement] = appElement.attribute(
                Attribute(AXAttributeNames.kAXWindowsAttribute)) ?? []

            if windows.isEmpty {
                // Fallback: dump the app root
                var lines: [String] = []
                var visited = Set<UInt>()
                renderTree(element: appElement, depth: 0, lines: &lines, visited: &visited)
                writeArtifact("\(tag)-axtree.txt", content: lines.joined(separator: "\n"))
                return
            }

            for (i, winRef) in windows.enumerated() {
                let winElement = Element(winRef)
                let winTitle = winElement.title() ?? "Window \(i)"
                var lines: [String] = []
                var visited = Set<UInt>()
                renderTree(element: winElement, depth: 0, lines: &lines, visited: &visited)

                let suffix = windows.count > 1 ? "-w\(i)" : ""
                let filename = "\(tag)\(suffix)-axtree.txt"
                let header = "// Window \(i): \(winTitle)\n"
                writeArtifact(filename, content: header + lines.joined(separator: "\n"))
            }
        }
    }

    // MARK: - Tree rendering (compact Playwright-style)

    private func shortRole(_ role: String) -> String {
        if role.hasPrefix("AX"), role.count > 2 {
            return String(role.dropFirst(2))
        }
        return role
    }

    private func formatNodeLine(role: String, title: String?, value: String?,
                                identifier: String?, indent: String) -> String {
        let short = shortRole(role)
        var line = "\(indent)\(short)"

        if let t = title, !t.isEmpty {
            line += " \"\(t)\""
        }

        if let id = identifier, !id.isEmpty {
            line += " #\(id)"
        }

        if let v = value, !v.isEmpty, v != title {
            line += " =\"\(v)\""
        }

        return line
    }

    @MainActor
    private func renderTree(
        element: Element, depth: Int, lines: inout [String], visited: inout Set<UInt>
    ) {
        guard depth <= axTreeDepth else { return }
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

        let hasTitle = title != nil && title?.isEmpty == false
        let hasId = identifier != nil && identifier?.isEmpty == false
        let hasValue = value != nil

        if hasTitle || hasId || hasValue {
            let indent = String(repeating: "  ", count: depth)
            let line = formatNodeLine(role: role, title: title, value: value,
                                      identifier: identifier, indent: indent)
            lines.append(line)
            renderChildren(children, depth: depth + 1, lines: &lines, visited: &visited)
        } else {
            // Skip unlabeled nodes, promote children
            renderChildren(children, depth: depth, lines: &lines, visited: &visited)
        }
    }

    /// Collapses 5+ consecutive same-role siblings: first 3, "... (N more)", last 1.
    @MainActor
    private func renderChildren(
        _ children: [Element], depth: Int, lines: inout [String], visited: inout Set<UInt>
    ) {
        var i = 0
        while i < children.count {
            let child = children[i]
            let childRole = child.role() ?? "AXUnknown"

            var runEnd = i + 1
            while runEnd < children.count, (children[runEnd].role() ?? "") == childRole {
                runEnd += 1
            }
            let runLength = runEnd - i

            if runLength >= 5 {
                for j in i..<(i + 3) {
                    renderTree(element: children[j], depth: depth, lines: &lines, visited: &visited)
                }
                let indent = String(repeating: "  ", count: depth)
                lines.append("\(indent)... (\(runLength - 4) more \(shortRole(childRole)))")
                renderTree(element: children[runEnd - 1], depth: depth, lines: &lines, visited: &visited)
                i = runEnd
            } else {
                renderTree(element: child, depth: depth, lines: &lines, visited: &visited)
                i += 1
            }
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
                if gap > self.watchdogTimeout {
                    self.snap("WATCHDOG-TIMEOUT")
                    XCTFail("""
                        Watchdog timeout: no snap() called for \(Int(gap))s (limit: \(Int(self.watchdogTimeout))s).
                        The test may be stuck. See artifacts: \(self.artifactDir)/
                        """)
                }
            }
        }
    }
}
