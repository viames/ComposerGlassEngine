// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "ComposerGlassEngine",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "ComposerGlassEngine",
      targets: ["ComposerGlassEngine"]
    )
  ],
  targets: [
    .target(
      name: "ComposerGlassEngine"
    ),
    .testTarget(
      name: "ComposerGlassEngineTests",
      dependencies: ["ComposerGlassEngine"]
    ),
  ]
)
