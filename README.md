# JourneyTester

macOS UI test framework that produces AI-readable artifacts. Each test step captures screenshots and a compact accessibility tree per window, so an AI agent can see exactly what's on screen without re-running the test.

## What it produces

Every `snap()` call writes to `.journeytester/journeys/<name>/artifacts/`:

```
006-page-loaded-w0.png           # screenshot of window 0
006-page-loaded-w0-axtree.txt    # accessibility tree of window 0
006-page-loaded-w1.png           # screenshot of window 1
006-page-loaded-w1-axtree.txt    # accessibility tree of window 1
```

The accessibility tree uses a compact format:

```
Window "Example Domain" #SafariWindow?IsSecure=true&UUID=...
  Group #BrowserView?IsPageLoaded=true&WebViewProcessID=96204
    Heading "Example Domain"
      StaticText ="Example Domain"
    StaticText ="This domain is for use in documentation examples..."
    Link "Learn more"
  Button #SidebarButton
  Group #BackForwardSegmentedControl
    Button #BackButton
    Button #ForwardButton
  Button "Page Menu" #AssistantButton
  TextField #WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD ="https://example.com"
  Button "Reload this page" #ReloadButton
  OpaqueProviderGroup #TabBar?isSeparate=false
    RadioButton "Example Domain" #TabBarTab?isActive=true
```

Format rules:
- `Role "title"` — element role (AX prefix stripped) + title in quotes
- `#identifier` — accessibility identifier
- `="value"` — current value
- Nodes with no title, id, or value are skipped (children promoted)
- 5+ consecutive same-role siblings collapsed: first 3, `... (N more Type)`, last 1
- Each window is a separate file

## Setup

### 1. Add the dependency

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/sunfmin/JourneyTester.git", branch: "main"),
]
```

### 2. Create a UI test target (xcodegen)

```yaml
# project.yml
packages:
  JourneyTester:
    path: ..  # or url

targets:
  HostApp:
    type: application
    platform: macOS
    sources: [HostApp]
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
        CODE_SIGN_IDENTITY: "YourApp Dev"
        CODE_SIGNING_ALLOWED: "YES"
        CODE_SIGN_STYLE: "Manual"
        ENABLE_HARDENED_RUNTIME: "NO"

  MyUITests:
    type: bundle.ui-testing
    platform: macOS
    sources: [MyUITests]
    dependencies:
      - target: HostApp
      - package: JourneyTester
    settings:
      base:
        TEST_TARGET_NAME: HostApp
        BUNDLE_LOADER: ""
        TEST_HOST: ""
        CODE_SIGN_IDENTITY: "YourApp Dev"
        CODE_SIGNING_ALLOWED: "YES"
        CODE_SIGN_STYLE: "Manual"
        ENABLE_HARDENED_RUNTIME: "NO"
```

### 3. Create a self-signed certificate (one-time)

Required so macOS Accessibility permissions persist across rebuilds.

```bash
CERT_NAME="YourApp Dev"
cat > /tmp/cert.cfg <<EOF
[req]
distinguished_name = req_dn
[req_dn]
CN = $CERT_NAME
[extensions]
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -keyout /tmp/dev.key -out /tmp/dev.crt \
  -days 3650 -nodes -config /tmp/cert.cfg -extensions extensions \
  -subj "/CN=$CERT_NAME" 2>/dev/null

security import /tmp/dev.crt -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
security import /tmp/dev.key -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/dev.crt
rm -f /tmp/cert.cfg /tmp/dev.key /tmp/dev.crt
```

### 4. Grant Accessibility permission (one-time)

On first run, the test will fail with a message asking you to grant Accessibility access. It opens System Settings automatically. Add the test runner app, then re-run. With the fixed certificate, this survives rebuilds.

### 5. Access artifacts

The xctrunner sandbox redirects file writes. Use the helper script:

```bash
bash link-artifacts.sh  # creates .journeytester symlink in project root
```

## Writing tests

```swift
import JourneyTester
import XCTest

final class SafariTests: JourneyTestCase {
    override var journeyName: String { "safari-basics" }
    override var appBundleID: String? { "com.apple.Safari" }

    func testNavigateToURL() {
        step("focus address bar") {
            app.typeKey("l", modifierFlags: .command)
            sleep(1)
        }

        // Steps > 5s need slowOkReason, otherwise the test fails.
        // With slowOkReason, snapshots are taken every 5s while waiting.
        step("navigate to page", timeout: 15, slowOkReason: "loading page") {
            app.typeText("https://example.com\n")
            let webView = app.webViews.firstMatch
            waitAndSnap(webView, timeout: 10, "Web view should exist")
        }

        step("verify content") {
            snap("page-loaded")
        }
    }
}
```

## API

### Override points

| Property | Default | Description |
|----------|---------|-------------|
| `journeyName` | required | Folder name for artifacts |
| `appBundleID` | `nil` | Bundle ID of app under test. `nil` = test host app |
| `axTreeDepth` | `8` | Max depth for AX tree traversal |

### Methods

| Method | Description |
|--------|-------------|
| `snap("label")` | Screenshot + AX tree per window |
| `step("name") { ... }` | Named phase, must complete in < 3s |
| `step("name", timeout: 30, slowOkReason: "...") { ... }` | Slow step, snapshots every 5s while waiting |
| `waitAndSnap(element, "msg")` | Wait for element (polls 0.5s), snap on failure |
| `assertExists(element, "msg")` | Assert element exists, snap on failure |
| `axQuery(role:title:identifier:)` | Query AXorcist for elements |
| `writeArtifact("file", content)` | Write custom artifact to journey dir |

## Timing rules

| Situation | Behavior |
|-----------|----------|
| Step completes in < 3s (default timeout) | OK |
| Step exceeds timeout, no `slowOkReason` | Test fails |
| Step exceeds timeout, `slowOkReason` given | OK, snapshots every 5s while waiting |
| Step exceeds `timeout` | Test fails |
| No `snap()` for 10s (global watchdog) | Test fails |

## Running tests

```bash
cd Examples
xcodegen generate
xcodebuild -project JourneyTesterExamples.xcodeproj \
  -scheme SafariUITests \
  -destination 'platform=macOS' \
  test
```
