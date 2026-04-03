@preconcurrency import AXorcist
import ApplicationServices
import Foundation
import XCTest

/// Base class for UI tests designed to be debugged by AI agents.
///
/// Every snap captures:
/// - A screenshot (PNG) per window
/// - An accessibility tree — full on first snap, then diffs only
///
/// Example output for step 3:
/// ```
/// === Snap 003: step-type-URL ===
/// [CHANGED] AXWindow "..." > AXToolbar > AXTextField id=WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD
///   value: "" → "https://example.com"
/// [ADDED]   AXWindow "Example Domain" > AXWebArea > AXHeading "Example Domain"
/// [ADDED]   AXWindow "Example Domain" > AXWebArea > AXStaticText value="This domain is..."
/// [REMOVED] AXWindow "Start Page" > ... > AXList id=StartPageOnboardingSection
/// ```
open class JourneyTestCase: XCTestCase {

    // MARK: - Override points

    open var journeyName: String { fatalError("Subclass must override journeyName") }
    open var appBundleID: String? { nil }

    /// Max depth for AX tree traversal.
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

    /// Previous snap's tree nodes, keyed for diffing.
    private var previousTreeNodes: [String: AXNode] = [:]
    private var isFirstSnap = true

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
        isFirstSnap = true
        previousTreeNodes = [:]
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

    /// Captures screenshots + AX tree artifact.
    /// First snap writes the full tree. Subsequent snaps write only the diff.
    /// On failure snaps (label starts with "FAIL"), the full tree is always written.
    public func snap(_ label: String) {
        screenshotIndex += 1
        lastSnapDate = Date()

        let prefix = String(format: "%03d", screenshotIndex)
        let tag = "\(prefix)-\(label)"

        captureScreenshots(tag: tag)
        app.activate()

        let currentNodes = collectAXNodes()

        // Always write the full tree
        let tree = renderFullTree(nodes: currentNodes)
        writeArtifact("\(tag)-axtree.txt", content: tree)

        // After the first snap, also write a diff showing what changed
        if !isFirstSnap {
            let diff = renderDiff(previous: previousTreeNodes, current: currentNodes, tag: tag)
            writeArtifact("\(tag)-diff.txt", content: diff)
        }

        isFirstSnap = false
        previousTreeNodes = currentNodes
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

    // MARK: - AX tree model

    /// A lightweight node for diffing. Keyed by its path in the tree.
    private struct AXNode {
        let role: String
        let title: String?
        let value: String?
        let identifier: String?
        let path: String       // e.g. "AXWindow 'Main' > AXToolbar > AXTextField"
        let displayLine: String // e.g. "AXTextField value=\"https://...\" id=..."
        let depth: Int
    }

    // MARK: - Collect nodes

    private func collectAXNodes() -> [String: AXNode] {
        MainActor.assumeIsolated {
            guard let root = Element.focusedApplication() else {
                return [:]
            }
            var nodes: [String: AXNode] = [:]
            var visited = Set<UInt>()
            collectNodes(element: root, depth: 0, pathParts: [], nodes: &nodes, visited: &visited)
            return nodes
        }
    }

    @MainActor
    private func collectNodes(
        element: Element,
        depth: Int,
        pathParts: [String],
        nodes: inout [String: AXNode],
        visited: inout Set<UInt>
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

        var pathLabel = role
        if let t = title, !t.isEmpty { pathLabel += " \"\(t.prefix(40))\"" }
        else if let id = identifier, !id.isEmpty { pathLabel += " id=\(id.prefix(40))" }

        let currentPath = (pathParts + [pathLabel]).joined(separator: " > ")

        let indent = String(repeating: "  ", count: depth)
        var displayLine = "\(indent)\(role)"
        if let t = title, !t.isEmpty { displayLine += " \"\(t)\"" }
        if let v = value, !v.isEmpty, v != title { displayLine += " value=\"\(v)\"" }
        if let id = identifier, !id.isEmpty { displayLine += " id=\(id)" }

        let node = AXNode(
            role: role, title: title, value: value, identifier: identifier,
            path: currentPath, displayLine: displayLine, depth: depth
        )
        nodes[currentPath] = node

        for child in children {
            collectNodes(element: child, depth: depth + 1,
                         pathParts: pathParts + [pathLabel],
                         nodes: &nodes, visited: &visited)
        }
    }

    // MARK: - Render full tree (compact Playwright-style)

    private func renderFullTree(nodes: [String: AXNode]) -> String {
        return MainActor.assumeIsolated {
            guard let root = Element.focusedApplication() else {
                return "// AX tree unavailable — no focused application"
            }
            var lines: [String] = []
            var visited = Set<UInt>()
            renderTree(element: root, depth: 0, lines: &lines, visited: &visited)
            return lines.joined(separator: "\n")
        }
    }

    /// Strips the "AX" prefix from role names: "AXButton" → "Button"
    private func shortRole(_ role: String) -> String {
        if role.hasPrefix("AX"), role.count > 2 {
            return String(role.dropFirst(2))
        }
        return role
    }

    /// Formats one element as a compact line:
    ///   Button "Save" #save-btn [value="yes", focused]
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

        // Attributes in brackets
        var attrs: [String] = []
        if let v = value, !v.isEmpty, v != title {
            attrs.append("value=\"\(v)\"")
        }
        if !attrs.isEmpty {
            line += " [\(attrs.joined(separator: ", "))]"
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

        let indent = String(repeating: "  ", count: depth)
        let line = formatNodeLine(role: role, title: title, value: value,
                                  identifier: identifier, indent: indent)
        lines.append(line)

        // Group consecutive children by role for collapsing
        renderChildren(children, depth: depth + 1, lines: &lines, visited: &visited)
    }

    /// Renders children with sibling collapsing:
    /// If 5+ consecutive siblings share the same role, show first 3,
    /// a "... (N more Type)" line, and the last one.
    @MainActor
    private func renderChildren(
        _ children: [Element], depth: Int, lines: inout [String], visited: inout Set<UInt>
    ) {
        // Group consecutive children by role
        var i = 0
        while i < children.count {
            let child = children[i]
            let childRole = child.role() ?? "AXUnknown"

            // Count consecutive siblings with same role
            var runEnd = i + 1
            while runEnd < children.count, (children[runEnd].role() ?? "") == childRole {
                runEnd += 1
            }
            let runLength = runEnd - i

            if runLength >= 5 {
                // Show first 3
                for j in i..<(i + 3) {
                    renderTree(element: children[j], depth: depth, lines: &lines, visited: &visited)
                }
                let indent = String(repeating: "  ", count: depth)
                lines.append("\(indent)... (\(runLength - 4) more \(shortRole(childRole)))")
                // Show last 1
                renderTree(element: children[runEnd - 1], depth: depth, lines: &lines, visited: &visited)
                i = runEnd
            } else {
                renderTree(element: child, depth: depth, lines: &lines, visited: &visited)
                i += 1
            }
        }
    }

    // MARK: - Render diff (unified diff format)

    /// Produces a standard unified diff between the previous and current full tree text.
    private func renderDiff(previous: [String: AXNode], current: [String: AXNode], tag: String) -> String {
        let prevTree = renderNodesAsLines(previous)
        let curTree = renderNodesAsLines(current)

        if prevTree == curTree {
            return "// No changes from previous snap\n"
        }

        return unifiedDiff(oldLines: prevTree, newLines: curTree,
                           oldLabel: "previous", newLabel: tag)
    }

    /// Render nodes to ordered lines for diffing (uses stored displayLines sorted by path).
    private func renderNodesAsLines(_ nodes: [String: AXNode]) -> [String] {
        nodes.values
            .sorted { $0.path < $1.path }
            .map { $0.displayLine }
    }

    /// Produces a unified diff (like `diff -u`) between two arrays of lines.
    private func unifiedDiff(oldLines: [String], newLines: [String],
                             oldLabel: String, newLabel: String) -> String {
        // Simple LCS-based unified diff
        let old = oldLines
        let new = newLines

        // Build LCS table
        let m = old.count, n = new.count
        // For very large trees, use a hash-based approach to avoid O(m*n) memory
        if m * n > 5_000_000 {
            // Fallback: just show additions and removals without context
            return fallbackDiff(old: old, new: new, oldLabel: oldLabel, newLabel: newLabel)
        }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                if old[i-1] == new[j-1] {
                    dp[i][j] = dp[i-1][j-1] + 1
                } else {
                    dp[i][j] = max(dp[i-1][j], dp[i][j-1])
                }
            }
        }

        // Backtrack to produce diff lines
        var result: [String] = []
        result.append("--- \(oldLabel)")
        result.append("+++ \(newLabel)")

        var i = m, j = n
        var diffLines: [String] = []
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && old[i-1] == new[j-1] {
                diffLines.append(" \(old[i-1])")
                i -= 1; j -= 1
            } else if j > 0 && (i == 0 || dp[i][j-1] >= dp[i-1][j]) {
                diffLines.append("+\(new[j-1])")
                j -= 1
            } else {
                diffLines.append("-\(old[i-1])")
                i -= 1
            }
        }
        diffLines.reverse()

        // Output with context (3 lines around changes, like diff -U3)
        var outputLines: [String] = []
        let contextSize = 3
        var changeRanges: [Int] = []
        for (idx, line) in diffLines.enumerated() {
            if line.hasPrefix("+") || line.hasPrefix("-") {
                changeRanges.append(idx)
            }
        }

        if changeRanges.isEmpty {
            return "// No changes from previous snap\n"
        }

        var shown = Set<Int>()
        for idx in changeRanges {
            for c in max(0, idx - contextSize)...min(diffLines.count - 1, idx + contextSize) {
                shown.insert(c)
            }
        }

        var lastShown = -2
        for idx in 0..<diffLines.count {
            guard shown.contains(idx) else { continue }
            if idx > lastShown + 1 {
                outputLines.append("@@")
            }
            outputLines.append(diffLines[idx])
            lastShown = idx
        }

        result.append(contentsOf: outputLines)
        return result.joined(separator: "\n")
    }

    private func fallbackDiff(old: [String], new: [String],
                              oldLabel: String, newLabel: String) -> String {
        let oldSet = Set(old)
        let newSet = Set(new)
        var lines = ["--- \(oldLabel)", "+++ \(newLabel)", "@@"]
        for line in old where !newSet.contains(line) {
            lines.append("-\(line)")
        }
        for line in new where !oldSet.contains(line) {
            lines.append("+\(line)")
        }
        return lines.joined(separator: "\n")
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
