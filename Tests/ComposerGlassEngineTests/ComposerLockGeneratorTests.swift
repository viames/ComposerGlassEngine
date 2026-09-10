import Foundation
import Testing

@testable import ComposerGlassEngine

@Suite("Composer lock generator")
struct ComposerLockGeneratorTests {
  @Test("Runtime and development dependency graphs are separated deterministically")
  func separatesRuntimeAndDevelopmentPackages() throws {
    let manifestData = Data(
      #"{"require":{"vendor/app":"^1.0","php":"^8.3"},"require-dev":{"vendor/tool":"^2.0"},"minimum-stability":"beta","prefer-stable":true}"#
        .utf8
    )
    let manifest = try ComposerManifest.decode(from: manifestData)
    let app = try repositoryPackage(
      "vendor/app",
      "1.0.0",
      requirements: ["vendor/shared": "^1.0"]
    )
    let shared = try repositoryPackage("vendor/shared", "1.2.0")
    let tool = try repositoryPackage("vendor/tool", "2.0.0-beta1")
    let result = try resolution([tool, shared, app])

    let lock = try ComposerLockGenerator().generate(
      manifest: manifest,
      manifestData: manifestData,
      resolution: result
    )

    #expect(try lock.packages().map(\.name) == ["vendor/app", "vendor/shared"])
    #expect(try lock.packages(in: .development).map(\.name) == ["vendor/tool"])
    #expect(lock.minimumStability == "beta")
    #expect(lock["prefer-stable"] == .bool(true))
    #expect(lock["platform"] == .object(["php": .string("^8.3")]))
    #expect(try lock.isFresh(for: manifestData))
  }

  @Test("Repository installation metadata and explicit stability flags are retained")
  func preservesPackageMetadataAndStabilityFlags() throws {
    let manifestData = Data(
      #"{"require":{"vendor/app":"^1.0@beta"},"config":{"platform":{"php":"8.3.0"}}}"#.utf8
    )
    let manifest = try ComposerManifest.decode(from: manifestData)
    let package = try repositoryPackage(
      "vendor/app",
      "1.0.0-beta1",
      additionalFields: [
        "dist": .object([
          "type": .string("zip"),
          "url": .string("https://example.com/app.zip"),
          "reference": .string("abc123"),
        ]),
        "autoload": .object(["psr-4": .object(["App\\\\": .string("src/")])]),
      ]
    )

    let lock = try ComposerLockGenerator().generate(
      manifest: manifest,
      manifestData: manifestData,
      resolution: try resolution([package])
    )
    let locked = try #require(lock.packages().first)

    #expect(locked["dist"] == package["dist"])
    #expect(locked["autoload"] == package["autoload"])
    #expect(lock["stability-flags"] == .object(["vendor/app": .number(10)]))
    #expect(lock["platform-overrides"] == .object(["php": .string("8.3.0")]))
    #expect(lock.pluginAPIVersion == "2.9.0")
  }

  @Test("A missing package in a resolved runtime graph is rejected")
  func rejectsIncompleteResolution() throws {
    let manifestData = Data(#"{"require":{"vendor/missing":"*"}}"#.utf8)
    let manifest = try ComposerManifest.decode(from: manifestData)

    #expect(throws: ComposerLockGeneratorError.resolvedPackageMissing("vendor/missing")) {
      try ComposerLockGenerator().generate(
        manifest: manifest,
        manifestData: manifestData,
        resolution: ComposerResolutionResult(packages: [])
      )
    }
  }

  @Test("Virtual providers and branch aliases are represented in the lock file")
  func writesVirtualProviderAndAliasMetadata() throws {
    let manifestData = Data(#"{"require":{"virtual/logger":"^1.0@dev"}}"#.utf8)
    let manifest = try ComposerManifest.decode(from: manifestData)
    let provider = try repositoryPackage(
      "vendor/logger",
      "dev-main",
      additionalFields: [
        "provide": .object(["virtual/logger": .string("1.1.0")]),
        "extra": .object([
          "branch-alias": .object(["dev-main": .string("1.2.x-dev")])
        ]),
      ]
    )
    let parsed = ComposerVersion(
      major: 1,
      minor: 2,
      patch: 9_999_999,
      build: 9_999_999,
      stability: .development
    )
    let resolution = ComposerResolutionResult(
      packages: [ComposerResolvedPackage(package: provider, parsedVersion: parsed)],
      aliases: [
        ComposerResolvedAlias(
          package: "vendor/logger",
          version: "dev-main",
          alias: "1.2.x-dev",
          normalizedAlias: "1.2.9999999.9999999-dev"
        )
      ]
    )

    let lock = try ComposerLockGenerator().generate(
      manifest: manifest,
      manifestData: manifestData,
      resolution: resolution
    )

    #expect(try lock.packages().map(\.name) == ["vendor/logger"])
    #expect(
      lock["aliases"]
        == .array([
          .object([
            "package": .string("vendor/logger"),
            "version": .string("dev-main"),
            "alias": .string("1.2.x-dev"),
            "alias_normalized": .string("1.2.9999999.9999999-dev"),
          ])
        ]))
  }

  private func repositoryPackage(
    _ name: String,
    _ version: String,
    requirements: [String: String] = [:],
    additionalFields: [String: JSONValue] = [:]
  ) throws -> ComposerRepositoryPackage {
    try ComposerRepositoryPackage(
      name: name,
      version: version,
      requirements: requirements,
      additionalFields: additionalFields
    )
  }

  private func resolution(
    _ packages: [ComposerRepositoryPackage]
  ) throws -> ComposerResolutionResult {
    ComposerResolutionResult(
      packages: try packages.map {
        ComposerResolvedPackage(
          package: $0,
          parsedVersion: try ComposerVersion($0.normalizedVersion ?? $0.version)
        )
      }
    )
  }
}
