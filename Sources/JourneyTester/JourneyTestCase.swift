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
/// Steps that take > 5s require a `slowOkReason` or the test fails.
/// When `slowOkReason` is provided, snapshots are taken every 5s while waiting.
/// A global watchdog fails the test if no `snap()` is called for 10s.
open class JourneyTestCase: XCTestCase {

    // MARK: - Override points

    open var journeyName: String { fatalError("Subclass must override journeyName") }
    open var appBundleID: String? { nil }
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
    private var stepIndex = 0

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
                Accessibility permission required.

                JourneyTester uses the macOS Accessibility API (AXorcist) to capture
                the UI element tree for AI-debuggable test output.

                Please grant Accessibility access to the test runner:
                  System Settings > Privacy & Security > Accessibility
                  > Enable your test runner app (e.g. SafariUITests-Runner)

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
        print("JourneyTester artifacts: \(resolvedPath)")
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

    /// Runs a named test phase with timing enforcement.
    ///
    /// - If the step body takes > 5 seconds and `slowOkReason` is nil, the test fails.
    /// - If `slowOkReason` is provided, snapshots are taken every 5 seconds while waiting,
    ///   up to `timeout`.
    ///
    /// ```swift
    /// step("click button") {           // must complete in < 5s
    ///     app.buttons["Go"].tap()
    /// }
    ///
    /// step("wait for page", timeout: 30, slowOkReason: "page loading over network") {
    ///     let heading = app.staticTexts["Welcome"]
    ///     XCTAssertTrue(heading.waitForExistence(timeout: 30))
    /// }
    /// ```
    public func step(
        _ name: String,
        timeout: TimeInterval = 3,
        slowOkReason: String? = nil,
        file: StaticString = #file,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        stepIndex += 1
        let safeName = sanitize(name)
        snap("step-\(safeName)-begin")

        let stepStart = Date()

        var periodicTimer: Timer?
        if slowOkReason != nil {
            var periodicCount = 0
            periodicTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                periodicCount += 1
                self.snap("step-\(safeName)-waiting-\(periodicCount)")
            }
        }

        var status = "passed"
        var errorMessage: String?

        do {
            try body()
        } catch {
            periodicTimer?.invalidate()
            status = "failed"
            errorMessage = "\(error)"
            snap("FAIL-step-\(safeName)")
            logStep(index: stepIndex, name: name, elapsed: Date().timeIntervalSince(stepStart),
                    timeout: timeout, slowOkReason: slowOkReason, status: status, error: errorMessage)
            XCTFail("Step '\(name)' failed: \(error)", file: file, line: line)
            return
        }

        periodicTimer?.invalidate()

        let elapsed = Date().timeIntervalSince(stepStart)

        if elapsed > timeout && slowOkReason == nil {
            status = "slow"
            snap("SLOW-step-\(safeName)")
            logStep(index: stepIndex, name: name, elapsed: elapsed,
                    timeout: timeout, slowOkReason: slowOkReason, status: status, error: nil)
            XCTFail("""
                Step '\(name)' took \(String(format: "%.1f", elapsed))s (limit: \(Int(timeout))s).
                If this is expected, add: step("\(name)", timeout: N, slowOkReason: "reason") { ... }
                Artifacts: \(artifactDir)/
                """, file: file, line: line)
            return
        }

        logStep(index: stepIndex, name: name, elapsed: elapsed,
                timeout: timeout, slowOkReason: slowOkReason, status: status, error: nil)
    }

    // MARK: - Step log (JSONL)

    private func logStep(index: Int, name: String, elapsed: TimeInterval,
                         timeout: TimeInterval, slowOkReason: String?,
                         status: String, error: String?) {
        var entry: [String: Any] = [
            "step": index,
            "name": name,
            "elapsed_s": round(elapsed * 100) / 100,
            "timeout_s": timeout,
            "status": status,
        ]
        if let reason = slowOkReason { entry["slow_ok_reason"] = reason }
        if let err = error { entry["error"] = err }

        if let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8)
        {
            let path = "\(artifactDir)/steps.jsonl"
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(Data((line + "\n").utf8))
                handle.closeFile()
            } else {
                try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - Snap

    /// Captures screenshots. AX tree is only dumped on error/failure snaps.
    public func snap(_ label: String) {
        screenshotIndex += 1
        lastSnapDate = Date()

        let prefix = String(format: "%03d", screenshotIndex)
        let tag = "\(prefix)-\(label)"

        app.activate()
        captureScreenshots(tag: tag)

        let isError = label.hasPrefix("FAIL")
            || label.hasPrefix("SLOW")
            || label.hasPrefix("WATCHDOG")
            || label.hasPrefix("TEARDOWN")
        if isError {
            dumpPerWindow(tag: tag)
        }
    }

    // MARK: - Wait + Assert helpers

    /// Waits for an element, polling every 0.5s. Returns immediately when found.
    /// Snaps before waiting and on failure.
    public func waitAndSnap(
        _ element: XCUIElement,
        timeout: TimeInterval = 5,
        _ message: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        snap("wait-\(sanitize(element.identifier))")

        // Poll with short intervals instead of blocking for the full timeout.
        let deadline = Date().addingTimeInterval(timeout)
        var found = element.exists
        while !found && Date() < deadline {
            found = element.waitForExistence(timeout: 0.5)
        }

        if !found {
            snap("FAIL-\(sanitize(element.identifier))")
            XCTFail("""
                \(message)

                Element '\(element.identifier)' not found after \(timeout)s.
                Artifacts: \(artifactDir)/
                """, file: file, line: line)
        }
    }

    /// Waits for an element to disappear.
    /// Snaps on failure (element still exists after timeout).
    public func waitGoneAndSnap(
        _ element: XCUIElement,
        timeout: TimeInterval = 5,
        _ message: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)

        if result != .completed {
            snap("FAIL-still-\(sanitize(element.identifier))")
            XCTFail("""
                \(message)

                Element '\(element.identifier)' still exists after \(timeout)s.
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

    private func dumpPerWindow(tag: String) {
        MainActor.assumeIsolated {
            guard let appElement = Element.focusedApplication() else {
                writeArtifact("\(tag)-axtree.txt", content: "// no focused application")
                return
            }

            let windows: [AXUIElement] = appElement.attribute(
                Attribute(AXAttributeNames.kAXWindowsAttribute)) ?? []

            if windows.isEmpty {
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

    // MARK: - Tree rendering

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
            renderChildren(children, depth: depth, lines: &lines, visited: &visited)
        }
    }

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

    // MARK: - Watchdog (fixed 10s)

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
                    self.snap("WATCHDOG-TIMEOUT")
                    XCTFail("""
                        Watchdog timeout: no snap() called for \(Int(gap))s.
                        The test may be stuck. See artifacts: \(self.artifactDir)/
                        """)
                }
            }
        }
    }
}
