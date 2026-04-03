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
        .package(url: "https://github.com/steipete/AXorcist.git", revision: "c75d06f"),
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
