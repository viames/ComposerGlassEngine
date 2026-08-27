import Foundation
import Testing

@testable import ComposerGlassEngine

@Suite("Composer dependency resolver")
struct ComposerDependencyResolverTests {
  @Test("The highest compatible stable version is selected deterministically")
  func selectsHighestCompatibleVersion() async throws {
    let source = StubPackageSource(packages: [
      "vendor/library": try packages("vendor/library", versions: ["2.0.0", "1.4.0", "1.9.0"])
    ])
    let resolver = ComposerDependencyResolver(source: source)

    let result = try await resolver.resolve(requirements: ["vendor/library": "^1.0"])

    #expect(result.packages.map(\.package.version) == ["1.9.0"])
  }

  @Test("Transitive requirements are included in the result")
  func resolvesTransitiveRequirements() async throws {
    let source = StubPackageSource(packages: [
      "vendor/application": [
        try package("vendor/application", "1.0.0", requires: ["vendor/library": "^2.0"])
      ],
      "vendor/library": try packages("vendor/library", versions: ["1.9.0", "2.3.0"]),
    ])
    let resolver = ComposerDependencyResolver(source: source)

    let result = try await resolver.resolve(requirements: ["vendor/application": "^1.0"])

    #expect(result.packages.map(\.package.name) == ["vendor/application", "vendor/library"])
    #expect(result.packages.map(\.package.version) == ["1.0.0", "2.3.0"])
  }

  @Test("A conflicting diamond dependency backtracks to a compatible version")
  func backtracksAcrossDiamondDependency() async throws {
    let source = StubPackageSource(packages: [
      "vendor/a": [
        try package("vendor/a", "2.0.0", requires: ["vendor/shared": "^2.0"]),
        try package("vendor/a", "1.0.0", requires: ["vendor/shared": "^1.0"]),
      ],
      "vendor/c": [
        try package("vendor/c", "1.0.0", requires: ["vendor/shared": "^1.0"])
      ],
      "vendor/shared": try packages("vendor/shared", versions: ["2.1.0", "1.8.0"]),
    ])
    let resolver = ComposerDependencyResolver(source: source)

    let result = try await resolver.resolve(requirements: [
      "vendor/a": "*",
      "vendor/c": "*",
    ])

    #expect(
      result.packages.map { "\($0.package.name)@\($0.package.version)" } == [
        "vendor/a@1.0.0",
        "vendor/c@1.0.0",
        "vendor/shared@1.8.0",
      ])
  }

  @Test("Circular requirements terminate once every selected version is compatible")
  func resolvesCircularRequirements() async throws {
    let source = StubPackageSource(packages: [
      "vendor/a": [try package("vendor/a", "1.0.0", requires: ["vendor/b": "^1.0"])],
      "vendor/b": [try package("vendor/b", "1.0.0", requires: ["vendor/a": "^1.0"])],
    ])
    let resolver = ComposerDependencyResolver(source: source)

    let result = try await resolver.resolve(requirements: ["vendor/a": "^1.0"])

    #expect(result.packages.map(\.package.name) == ["vendor/a", "vendor/b"])
  }

  @Test("Platform packages are validated and excluded from installable packages")
  func validatesPlatformPackages() async throws {
    let source = StubPackageSource(packages: [
      "vendor/library": [
        try package(
          "vendor/library",
          "1.0.0",
          requires: ["php": "^8.3", "ext-json": "*"]
        )
      ]
    ])
    let platform = try ComposerResolutionPlatform(packages: [
      "php": "8.4.1",
      "ext-json": "8.4.1",
    ])
    let resolver = ComposerDependencyResolver(source: source, platform: platform)

    let result = try await resolver.resolve(requirements: ["vendor/library": "*"])

    #expect(result.packages.map(\.package.name) == ["vendor/library"])
  }

  @Test("A missing extension produces a structured resolution problem")
  func explainsMissingPlatformPackage() async throws {
    let source = StubPackageSource(packages: [
      "vendor/library": [
        try package("vendor/library", "1.0.0", requires: ["ext-mbstring": "*"])
      ]
    ])
    let resolver = ComposerDependencyResolver(source: source)

    do {
      _ = try await resolver.resolve(requirements: ["vendor/library": "*"])
      Issue.record("Expected resolution to fail")
    } catch let ComposerDependencyResolverError.resolutionFailed(problem) {
      #expect(problem.package == "ext-mbstring")
      #expect(problem.reason == .platformPackageUnavailable)
      #expect(problem.requirements.first?.requiredBy == "vendor/library")
    }
  }

  @Test("Default minimum stability excludes pre-releases")
  func appliesMinimumStability() async throws {
    let source = StubPackageSource(packages: [
      "vendor/library": try packages(
        "vendor/library",
        versions: ["2.0.0-beta1", "1.9.0"]
      )
    ])
    let resolver = ComposerDependencyResolver(source: source)

    let stable = try await resolver.resolve(requirements: ["vendor/library": "*"])
    let beta = try await resolver.resolve(
      requirements: ["vendor/library": "*@beta"],
      minimumStability: .stable
    )

    #expect(stable.packages.first?.package.version == "1.9.0")
    #expect(beta.packages.first?.package.version == "2.0.0-beta1")
  }

  @Test("Prefer-stable can select a stable release over a newer pre-release")
  func prefersStableRelease() async throws {
    let source = StubPackageSource(packages: [
      "vendor/library": try packages(
        "vendor/library",
        versions: ["2.0.0-beta1", "1.9.0"]
      )
    ])
    let resolver = ComposerDependencyResolver(source: source)

    let result = try await resolver.resolve(
      requirements: ["vendor/library": "*"],
      minimumStability: .beta,
      preferStable: true
    )

    #expect(result.packages.first?.package.version == "1.9.0")
  }

  @Test("Manifest stability and development requirements feed the resolver")
  func resolvesManifestConfiguration() async throws {
    let source = StubPackageSource(packages: [
      "vendor/runtime": try packages("vendor/runtime", versions: ["1.0.0"]),
      "vendor/tool": try packages("vendor/tool", versions: ["2.0.0-beta1"]),
    ])
    let resolver = ComposerDependencyResolver(source: source)
    let manifest = ComposerManifest(fields: [
      "require": .object(["vendor/runtime": .string("^1.0")]),
      "require-dev": .object(["vendor/tool": .string("^2.0")]),
      "minimum-stability": .string("beta"),
    ])

    let result = try await resolver.resolve(
      manifest: manifest,
      includeDevelopmentRequirements: true
    )

    #expect(result.packages.map(\.package.name) == ["vendor/runtime", "vendor/tool"])
  }

  @Test("Runtime and development constraints for the same package are both preserved")
  func combinesManifestRequirementSections() async throws {
    let source = StubPackageSource(packages: [
      "vendor/library": try packages("vendor/library", versions: ["1.0.0", "2.0.0"])
    ])
    let resolver = ComposerDependencyResolver(source: source)
    let manifest = ComposerManifest(fields: [
      "require": .object(["vendor/library": .string("^1.0")]),
      "require-dev": .object(["vendor/library": .string("^2.0")]),
    ])

    do {
      _ = try await resolver.resolve(
        manifest: manifest,
        includeDevelopmentRequirements: true
      )
      Issue.record("Expected resolution to fail")
    } catch let ComposerDependencyResolverError.resolutionFailed(problem) {
      #expect(problem.requirements.map(\.constraint).sorted() == ["^1.0", "^2.0"])
    }
  }

  @Test("Unavailable versions retain constraints and repository evidence")
  func explainsIncompatibleVersions() async throws {
    let source = StubPackageSource(packages: [
      "vendor/library": try packages("vendor/library", versions: ["1.0.0", "2.0.0"])
    ])
    let resolver = ComposerDependencyResolver(source: source)

    do {
      _ = try await resolver.resolve(requirements: ["vendor/library": "^3.0"])
      Issue.record("Expected resolution to fail")
    } catch let ComposerDependencyResolverError.resolutionFailed(problem) {
      #expect(problem.package == "vendor/library")
      #expect(problem.reason == .noCompatibleVersion)
      #expect(problem.requirements.map(\.constraint) == ["^3.0"])
      #expect(problem.availableVersions == ["1.0.0", "2.0.0"])
    }
  }

  @Test("Repository package loads are cached across backtracking branches")
  func cachesPackageLoads() async throws {
    let source = StubPackageSource(packages: [
      "vendor/a": [
        try package("vendor/a", "2.0.0", requires: ["vendor/shared": "^2.0"]),
        try package("vendor/a", "1.0.0", requires: ["vendor/shared": "^1.0"]),
      ],
      "vendor/c": [try package("vendor/c", "1.0.0", requires: ["vendor/shared": "^1.0"])],
      "vendor/shared": try packages("vendor/shared", versions: ["1.0.0", "2.0.0"]),
    ])
    let resolver = ComposerDependencyResolver(source: source)

    _ = try await resolver.resolve(requirements: ["vendor/a": "*", "vendor/c": "*"])

    #expect(await source.loadCount(for: "vendor/shared") == 1)
  }

  @Test("A new resolution reloads repository metadata")
  func reloadsPackagesBetweenResolutions() async throws {
    let source = StubPackageSource(packages: [
      "vendor/library": try packages("vendor/library", versions: ["1.0.0"])
    ])
    let resolver = ComposerDependencyResolver(source: source)

    let first = try await resolver.resolve(requirements: ["vendor/library": "*"])
    await source.replacePackages(
      for: "vendor/library",
      with: try packages("vendor/library", versions: ["1.0.0", "2.0.0"])
    )
    let second = try await resolver.resolve(requirements: ["vendor/library": "*"])

    #expect(first.packages.first?.package.version == "1.0.0")
    #expect(second.packages.first?.package.version == "2.0.0")
    #expect(await source.loadCount(for: "vendor/library") == 2)
  }
}

private actor StubPackageSource: ComposerPackageSource {
  private var storedPackages: [String: [ComposerRepositoryPackage]]
  private var loadCounts: [String: Int] = [:]

  init(packages: [String: [ComposerRepositoryPackage]]) {
    self.storedPackages = packages
  }

  func packages(
    named packageName: String,
    includeDevelopmentVersions: Bool
  ) async throws -> [ComposerRepositoryPackage] {
    loadCounts[packageName, default: 0] += 1
    return storedPackages[packageName] ?? []
  }

  func loadCount(for packageName: String) -> Int {
    loadCounts[packageName, default: 0]
  }

  func replacePackages(
    for packageName: String,
    with packages: [ComposerRepositoryPackage]
  ) {
    storedPackages[packageName] = packages
  }
}

private func package(
  _ name: String,
  _ version: String,
  requires requirements: [String: String] = [:]
) throws -> ComposerRepositoryPackage {
  try ComposerRepositoryPackage(
    name: name,
    version: version,
    requirements: requirements
  )
}

private func packages(
  _ name: String,
  versions: [String]
) throws -> [ComposerRepositoryPackage] {
  try versions.map { try package(name, $0) }
}
