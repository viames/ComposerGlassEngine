import Foundation
import Testing

@testable import ComposerGlassEngine

@Suite("Composer lock file")
struct ComposerLockFileTests {
  @Test("Unknown metadata survives a deterministic round trip")
  func preservesUnknownMetadata() throws {
    let source = Data(
      #"""
      {
        "content-hash": "0123456789abcdef0123456789abcdef",
        "packages": [
          {
            "name": "psr/log",
            "version": "3.0.2",
            "dist": {
              "type": "zip",
              "url": "https://example.com/psr-log.zip",
              "reference": "abc123"
            },
            "require": {"php": ">=8.0"},
            "custom-package-field": [true, "retained"]
          }
        ],
        "packages-dev": [],
        "minimum-stability": "stable",
        "plugin-api-version": "2.6.0",
        "custom-root-field": {"retained": true}
      }
      """#.utf8)

    let lockFile = try ComposerLockFile.decode(from: source)
    let encoded = try lockFile.encoded()
    let decoded = try ComposerLockFile.decode(from: encoded)
    let package = try #require(decoded.packages().first)

    #expect(package.name == "psr/log")
    #expect(package.version == "3.0.2")
    #expect(try package.requirements()["php"] == ">=8.0")
    #expect(package["custom-package-field"] == .array([.bool(true), .string("retained")]))
    #expect(decoded["custom-root-field"] == .object(["retained": .bool(true)]))
    #expect(decoded.minimumStability == "stable")
    #expect(decoded.pluginAPIVersion == "2.6.0")
  }

  @Test("Package entries are sorted by name and version")
  func sortsPackages() throws {
    let packageB = try ComposerLockedPackage(name: "vendor/b", version: "1.0.0")
    let packageA2 = try ComposerLockedPackage(name: "vendor/a", version: "2.0.0")
    var lockFile = try ComposerLockFile(
      contentHash: "0123456789abcdef0123456789abcdef"
    )

    try lockFile.setPackages([packageB, packageA2], in: .runtime)

    #expect(try lockFile.packages().map(\.name) == ["vendor/a", "vendor/b"])
  }

  @Test("Official nested attribute order survives a byte-identical round trip")
  func preservesOfficialNestedAttributeOrder() throws {
    let source = Data(
      #"""
      {
          "content-hash": "0123456789abcdef0123456789abcdef",
          "packages": [
              {
                  "name": "vendor/package",
                  "version": "1.2.3",
                  "extra": {
                      "component": {
                          "id": "package",
                          "path": "Package",
                          "entry": "README.md",
                          "target": "vendor/package.git"
                      }
                  },
                  "autoload": {
                      "files": [
                          "src/functions.php"
                      ],
                      "psr-4": {
                          "Vendor\\Package\\": "src/"
                      }
                  },
                  "support": {
                      "forum": "https://example.com/forum",
                      "issues": "https://example.com/issues",
                      "source": "https://example.com/source"
                  }
              }
          ],
          "packages-dev": []
      }

      """#.utf8
    )

    let lockFile = try ComposerLockFile.decode(from: source)

    #expect(try lockFile.encoded() == source)
  }

  @Test("Encoding matches Composer key escaping and package field order")
  func matchesComposerJSONLayout() throws {
    let package = try ComposerLockedPackage(
      name: "vendor/package",
      version: "1.2.3",
      fields: [
        "require-dev": .object(["phpunit/phpunit": .string("^12.0")]),
        "time": .string("2026-09-27T00:00:00+00:00"),
        "type": .string("library"),
        "autoload": .object([
          "psr-4": .object(["Vendor\\Package\\": .string("src/")])
        ]),
        "authors": .array([
          .object([
            "email": .string("team@example.com"),
            "name": .string("Example Team"),
          ])
        ]),
        "funding": .array([
          .object([
            "type": .string("github"),
            "url": .string("https://github.com/sponsors/example"),
          ])
        ]),
      ]
    )
    let lockFile = try ComposerLockFile(
      contentHash: "0123456789abcdef0123456789abcdef",
      packages: [package]
    )

    let expected = Data(
      #"""
      {
          "content-hash": "0123456789abcdef0123456789abcdef",
          "packages": [
              {
                  "name": "vendor/package",
                  "version": "1.2.3",
                  "require-dev": {
                      "phpunit/phpunit": "^12.0"
                  },
                  "type": "library",
                  "autoload": {
                      "psr-4": {
                          "Vendor\\Package\\": "src/"
                      }
                  },
                  "authors": [
                      {
                          "name": "Example Team",
                          "email": "team@example.com"
                      }
                  ],
                  "funding": [
                      {
                          "url": "https://github.com/sponsors/example",
                          "type": "github"
                      }
                  ],
                  "time": "2026-09-27T00:00:00+00:00"
              }
          ],
          "packages-dev": []
      }

      """#.utf8
    )

    #expect(try lockFile.encoded() == expected)
  }

  @Test("Duplicate packages are rejected")
  func rejectsDuplicatePackages() throws {
    let first = try ComposerLockedPackage(name: "vendor/package", version: "1.0.0")
    let second = try ComposerLockedPackage(name: "vendor/package", version: "2.0.0")
    var lockFile = try ComposerLockFile(
      contentHash: "0123456789abcdef0123456789abcdef"
    )

    #expect(throws: ComposerLockError.duplicatePackage("vendor/package")) {
      try lockFile.setPackages([first, second], in: .runtime)
    }
  }

  @Test("Required lock fields are validated")
  func validatesRequiredFields() {
    let missingHash = Data(#"{"packages":[],"packages-dev":[]}"#.utf8)
    let invalidHash = Data(#"{"content-hash":false,"packages":[],"packages-dev":[]}"#.utf8)
    let missingDevelopmentPackages = Data(
      #"{"content-hash":"0123456789abcdef0123456789abcdef","packages":[]}"#.utf8
    )

    #expect(throws: ComposerLockError.missingField("content-hash")) {
      try ComposerLockFile.decode(from: missingHash)
    }
    #expect(throws: ComposerLockError.invalidField("content-hash")) {
      try ComposerLockFile.decode(from: invalidHash)
    }
    #expect(throws: ComposerLockError.invalidField("packages-dev")) {
      try ComposerLockFile.decode(from: missingDevelopmentPackages)
    }
  }
}
