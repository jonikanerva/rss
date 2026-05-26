// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "PerfParser",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .executable(name: "PerfParser", targets: ["PerfParser"])
  ],
  targets: [
    .executableTarget(
      name: "PerfParser",
      path: "Sources/PerfParser",
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
    .testTarget(
      name: "PerfParserTests",
      dependencies: ["PerfParser"],
      path: "Tests/PerfParserTests",
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
  ]
)
