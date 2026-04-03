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
        let isFailure = label.hasPrefix("FAIL") || label.hasPrefix("TEARDOWN")

        if isFirstSnap || isFailure {
            // Full tree
            let tree = renderFullTree(nodes: currentNodes)
            writeArtifact("\(tag)-axtree.txt", content: tree)
            isFirstSnap = false
        } else {
            // Diff against previous
            let diff = renderDiff(previous: previousTreeNodes, current: currentNodes, tag: tag)
            writeArtifact("\(tag)-axtree.txt", content: diff)
        }

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

    private static let noiseRoles: Set<String> = [
        "AXGroup", "AXGeneric", "AXSection", "AXArticle",
        "AXLayoutArea", "AXLayoutItem", "AXSplitGroup",
    ]

    private static let maxChildrenShown = 5

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

        let hasLabel = (title != nil && title?.isEmpty == false)
            || value != nil
            || (identifier != nil && identifier?.isEmpty == false)

        // Noise containers: skip but recurse into children with same path
        if Self.noiseRoles.contains(role), !hasLabel {
            for (i, child) in children.enumerated() {
                if i >= Self.maxChildrenShown { break }
                collectNodes(element: child, depth: depth, pathParts: pathParts,
                             nodes: &nodes, visited: &visited)
            }
            return
        }

        // Build a human-readable key for this node
        var pathLabel = role
        if let t = title, !t.isEmpty { pathLabel += " \"\(t.prefix(40))\"" }
        else if let id = identifier, !id.isEmpty { pathLabel += " id=\(id.prefix(40))" }

        let currentPath = (pathParts + [pathLabel]).joined(separator: " > ")

        // Build display line
        let indent = String(repeating: "  ", count: depth)
        var displayLine = "\(indent)\(role)"
        if let t = title, !t.isEmpty { displayLine += " \"\(t.prefix(80))\"" }
        if let v = value, !v.isEmpty, v != title { displayLine += " value=\"\(v.prefix(80))\"" }
        if let id = identifier, !id.isEmpty { displayLine += " id=\(id.prefix(60))" }

        let node = AXNode(
            role: role, title: title, value: value, identifier: identifier,
            path: currentPath, displayLine: displayLine, depth: depth
        )
        nodes[currentPath] = node

        for (i, child) in children.enumerated() {
            if i >= Self.maxChildrenShown {
                let truncPath = currentPath + " > ... (\(children.count - Self.maxChildrenShown) more)"
                let truncLine = "\(indent)  ... and \(children.count - Self.maxChildrenShown) more children"
                nodes[truncPath] = AXNode(
                    role: "...", title: nil, value: nil, identifier: nil,
                    path: truncPath, displayLine: truncLine, depth: depth + 1
                )
                break
            }
            collectNodes(element: child, depth: depth + 1,
                         pathParts: pathParts + [pathLabel],
                         nodes: &nodes, visited: &visited)
        }
    }

    // MARK: - Render full tree

    private func renderFullTree(nodes: [String: AXNode]) -> String {
        let sorted = nodes.values.sorted { a, b in
            a.displayLine.compare(b.displayLine, options: .literal) == .orderedAscending
        }
        // Re-render by collecting from scratch to preserve tree order
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

        let hasLabel = (title != nil && title?.isEmpty == false)
            || value != nil
            || (identifier != nil && identifier?.isEmpty == false)

        if Self.noiseRoles.contains(role), !hasLabel {
            for (i, child) in children.enumerated() {
                if i >= Self.maxChildrenShown {
                    let indent = String(repeating: "  ", count: depth)
                    lines.append("\(indent)... and \(children.count - Self.maxChildrenShown) more")
                    break
                }
                renderTree(element: child, depth: depth, lines: &lines, visited: &visited)
            }
            return
        }

        let indent = String(repeating: "  ", count: depth)
        var line = "\(indent)\(role)"
        if let t = title, !t.isEmpty { line += " \"\(t.prefix(80))\"" }
        if let v = value, !v.isEmpty, v != title { line += " value=\"\(v.prefix(80))\"" }
        if let id = identifier, !id.isEmpty { line += " id=\(id.prefix(60))" }
        lines.append(line)

        for (i, child) in children.enumerated() {
            if i >= Self.maxChildrenShown {
                lines.append("\(indent)  ... and \(children.count - Self.maxChildrenShown) more children")
                break
            }
            renderTree(element: child, depth: depth + 1, lines: &lines, visited: &visited)
        }
    }

    // MARK: - Render diff

    private func renderDiff(previous: [String: AXNode], current: [String: AXNode], tag: String) -> String {
        var lines: [String] = []

        // Changed: same path, different value/title
        for (path, cur) in current {
            if let prev = previous[path] {
                var changes: [String] = []
                if prev.title != cur.title {
                    changes.append("title: \"\(prev.title ?? "")\" → \"\(cur.title ?? "")\"")
                }
                if prev.value != cur.value {
                    changes.append("value: \"\(prev.value ?? "")\" → \"\(cur.value ?? "")\"")
                }
                if !changes.isEmpty {
                    lines.append("[CHANGED] \(path)")
                    for c in changes {
                        lines.append("  \(c)")
                    }
                }
            }
        }

        // Added: in current but not in previous
        let added = current.keys.filter { previous[$0] == nil }.sorted()
        for path in added {
            if let node = current[path] {
                lines.append("[ADDED]   \(node.displayLine.trimmingCharacters(in: .whitespaces))")
                lines.append("          at: \(path)")
            }
        }

        // Removed: in previous but not in current
        let removed = previous.keys.filter { current[$0] == nil }.sorted()
        for path in removed {
            if let node = previous[path] {
                lines.append("[REMOVED] \(node.displayLine.trimmingCharacters(in: .whitespaces))")
                lines.append("          was: \(path)")
            }
        }

        if lines.isEmpty {
            return "// No changes from previous snap"
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
