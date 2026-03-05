// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Feeder",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .executableTarget(
            name: "Feeder",
            path: "Feeder",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "FeederTests",
            dependencies: ["Feeder"],
            path: "FeederTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
