// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "JourneyTester",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "JourneyTester", targets: ["JourneyTester"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sunfmin/AXorcist.git", branch: "fix/safari-traversal-crash"),
    ],
    targets: [
        .target(
            name: "JourneyTester",
            dependencies: ["AXorcist"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "JourneyTesterTests",
            dependencies: ["JourneyTester"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
