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
    ),
    .executable(
      name: "composer-glass-engine-probe",
      targets: ["ComposerGlassEngineProbe"]
    ),
  ],
  targets: [
    .target(
      name: "ComposerGlassEngine",
      resources: [.copy("Resources/Composer")]
    ),
    .executableTarget(
      name: "ComposerGlassEngineProbe",
      dependencies: ["ComposerGlassEngine"]
    ),
    .testTarget(
      name: "ComposerGlassEngineTests",
      dependencies: ["ComposerGlassEngine"],
      resources: [.copy("Fixtures")]
    ),
  ]
)
