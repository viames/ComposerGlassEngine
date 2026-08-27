import Foundation
import Testing

@testable import ComposerGlassEngine

@Suite("Composer content hash")
struct ComposerContentHashTests {
  @Test("Hash matches Composer for a typical project")
  func matchesComposerReference() throws {
    let source = Data(
      #"""
      {
        "name": "acme/basic-app",
        "description": "Basic Composer project",
        "type": "project",
        "license": "MIT",
        "require": {
          "php": "^8.2",
          "monolog/monolog": "^3.0"
        },
        "require-dev": {
          "phpunit/phpunit": "^10.0"
        },
        "autoload": {
          "psr-4": {
            "Acme\\Basic\\": "src/"
          }
        },
        "scripts": {
          "test": "phpunit"
        },
        "config": {
          "sort-packages": true
        },
        "minimum-stability": "stable",
        "prefer-stable": true
      }
      """#.utf8)

    #expect(
      try ComposerContentHash.compute(from: source)
        == "434c30245e524ce95ff44fde1df708b8"
    )
  }

  @Test("Hash matches Composer for platform overrides and encoded values")
  func matchesComposerReferenceForComplexValues() throws {
    let source = Data(
      #"""
      {
        "extra": {
          "message": "Caffè 😀",
          "number": 1.0,
          "url": "https://example.com/archive.zip",
          "nested": {"z": 1, "a": 2}
        },
        "config": {
          "sort-packages": true,
          "platform": {"php": "8.3.0", "ext-json": "*"}
        },
        "repositories": [
          {"type": "composer", "url": "https://repo.packagist.org"}
        ],
        "require": {"vendor/package": "^1.0"},
        "name": "acme/example"
      }
      """#.utf8)

    #expect(
      try ComposerContentHash.compute(from: source)
        == "a185f2e64a64b872db2412b932c241c2"
    )
  }

  @Test("Unrelated manifest fields do not affect the hash")
  func ignoresUnrelatedFields() throws {
    let first = Data(
      #"{"name":"acme/example","description":"First","require":{"php":"^8.3"}}"#.utf8
    )
    let second = Data(
      #"{"scripts":{"test":"phpunit"},"require":{"php":"^8.3"},"description":"Second","name":"acme/example"}"#
        .utf8
    )

    #expect(
      try ComposerContentHash.compute(from: first)
        == ComposerContentHash.compute(from: second)
    )
  }

  @Test("Dependency changes make an existing lock file stale")
  func detectsStaleLockFile() throws {
    let original = Data(#"{"name":"acme/example","require":{"php":"^8.3"}}"#.utf8)
    let changed = Data(#"{"name":"acme/example","require":{"php":"^8.4"}}"#.utf8)
    let hash = try ComposerContentHash.compute(from: original)
    let lockFile = try ComposerLockFile(contentHash: hash)

    #expect(try lockFile.isFresh(for: original))
    #expect(try !lockFile.isFresh(for: changed))
  }

  @Test("The manifest root must be an object")
  func rejectsNonObjectRoot() {
    #expect(throws: ComposerContentHashError.rootIsNotObject) {
      try ComposerContentHash.compute(from: Data("[]".utf8))
    }
  }
}
