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
            exclude: ["Info.plist"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Feeder/Info.plist"
                ])
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
