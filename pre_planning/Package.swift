// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "rss-spike",
    products: [
        .library(
            name: "RSSSpikeCore",
            targets: ["RSSSpikeCore"]
        ),
        .executable(
            name: "rss-spike",
            targets: ["rss-spike"]
        ),
    ],
    targets: [
        .target(
            name: "RSSSpikeCore"
        ),
        .executableTarget(
            name: "rss-spike",
            dependencies: ["RSSSpikeCore"]
        ),
        .testTarget(
            name: "RSSSpikeCoreTests",
            dependencies: ["RSSSpikeCore"]
        ),
    ]
)
