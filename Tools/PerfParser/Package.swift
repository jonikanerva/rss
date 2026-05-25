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
    )
  ]
)
