// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "apple-fm-categorizer",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "apple-fm-categorizer",
            path: "Sources"
        ),
    ]
)
