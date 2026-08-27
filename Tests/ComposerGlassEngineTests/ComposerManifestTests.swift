import Foundation
import Testing

@testable import ComposerGlassEngine

@Suite("Composer manifest")
struct ComposerManifestTests {
  @Test("Unknown fields survive a requirement edit")
  func preservesUnknownFields() throws {
    let source = Data(
      #"""
      {
        "name": "acme/example",
        "require": {"php": "^8.3"},
        "extra": {"custom": [true, 42, "value"]}
      }
      """#.utf8)

    var manifest = try ComposerManifest.decode(from: source)
    try manifest.setRequirement(package: "psr/log", constraint: "^3.0")
    let encoded = try manifest.encoded(sortedKeys: true)
    let decoded = try ComposerManifest.decode(from: encoded)

    #expect(try decoded.requirements()["php"] == "^8.3")
    #expect(try decoded.requirements()["psr/log"] == "^3.0")
    #expect(
      decoded["extra"]
        == .object([
          "custom": .array([.bool(true), .number(42), .string("value")])
        ]))
  }

  @Test("Removing the final requirement removes the section")
  func removesEmptyRequirementSection() throws {
    var manifest = ComposerManifest(fields: [
      "require-dev": .object(["phpunit/phpunit": .string("^11")])
    ])

    try manifest.setRequirement(
      package: "phpunit/phpunit",
      constraint: nil,
      in: .development
    )

    #expect(manifest["require-dev"] == nil)
  }

  @Test(arguments: [
    "vendor/package",
    "vendor/package--name",
    "php",
    "ext-json",
    "composer-runtime-api",
  ])
  func acceptsValidPackageNames(_ value: String) {
    #expect(ComposerPackageName.isValid(value))
  }

  @Test(arguments: [
    "Vendor/Package",
    "missing-slash",
    "vendor/",
    "vendor//package",
    "vendor/bad name",
    "vendor--name/package",
    "vendor/package---name",
  ])
  func rejectsInvalidPackageNames(_ value: String) {
    #expect(!ComposerPackageName.isValid(value))
  }
}
