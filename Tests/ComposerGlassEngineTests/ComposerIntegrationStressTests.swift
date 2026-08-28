import Foundation
import Testing

@testable import ComposerGlassEngine

@Suite("Composer integration and stress")
struct ComposerIntegrationStressTests {
  @Test("A realistic project fixture round-trips without losing dependency metadata")
  func readsRealWorldFixture() throws {
    let fixture = Bundle.module.url(
      forResource: "RealWorldProject",
      withExtension: nil,
      subdirectory: "Fixtures"
    )!
    let manifestData = try Data(contentsOf: fixture.appendingPathComponent("composer.json"))
    let lockData = try Data(contentsOf: fixture.appendingPathComponent("composer.lock"))

    let manifest = try ComposerManifest.decode(from: manifestData)
    let lock = try ComposerLockFile.decode(from: lockData)
    let roundTrip = try ComposerLockFile.decode(from: lock.encoded())

    #expect(manifest.name == "composerglass/fixture-project")
    #expect(try manifest.requirements().count == 3)
    #expect(
      try roundTrip.packages().map(\.name) == [
        "psr/log", "symfony/console", "symfony/string",
      ])
    #expect(try roundTrip.packages(in: .development).map(\.name) == ["phpunit/phpunit"])
    #expect(try roundTrip.packages().first?.requirements()["php"] == ">=8.0.0")
  }

  @Test("Resolver handles a 250-package transitive graph deterministically")
  func resolvesLargeGraph() async throws {
    var packagesByName: [String: [ComposerRepositoryPackage]] = [:]
    for index in 0..<250 {
      let name = String(format: "vendor/package%03d", index)
      let requirements =
        index == 249
        ? [:]
        : [String(format: "vendor/package%03d", index + 1): "^1.0"]
      packagesByName[name] = [
        try ComposerRepositoryPackage(
          name: name,
          version: "1.0.0",
          requirements: requirements
        )
      ]
    }
    let resolver = ComposerDependencyResolver(source: StressPackageSource(packagesByName))

    let first = try await resolver.resolve(requirements: ["vendor/package000": "^1.0"])
    let second = try await resolver.resolve(requirements: ["vendor/package000": "^1.0"])

    #expect(first.packages.count == 250)
    #expect(first == second)
    #expect(first.packages.first?.package.name == "vendor/package000")
    #expect(first.packages.last?.package.name == "vendor/package249")
  }

  @Test("Lock encoding remains deterministic for two thousand packages")
  func encodesLargeLockFile() throws {
    let packages = try (0..<2_000).map { index in
      try ComposerLockedPackage(
        name: String(format: "vendor/package%04d", index),
        version: "1.0.0",
        fields: ["description": .string("Stress package")]
      )
    }
    let lock = try ComposerLockFile(
      contentHash: String(repeating: "0", count: 32),
      packages: packages.reversed()
    )

    let first = try lock.encoded()
    let second = try lock.encoded()
    let decoded = try ComposerLockFile.decode(from: first)

    #expect(first == second)
    #expect(try decoded.packages().count == 2_000)
    #expect(try decoded.packages().first?.name == "vendor/package0000")
    #expect(try decoded.packages().last?.name == "vendor/package1999")
  }

  @Test("Vendor transactions preserve one thousand files across install and rollback")
  func transactsLargeVendorTree() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ComposerStressTransaction-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project")
    let oldVendor = project.appendingPathComponent("vendor")
    let prepared = root.appendingPathComponent("prepared")
    try FileManager.default.createDirectory(at: oldVendor, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
    for index in 0..<1_000 {
      try Data("old-\(index)".utf8).write(
        to: oldVendor.appendingPathComponent(String(format: "%04d.txt", index))
      )
      try Data("new-\(index)".utf8).write(
        to: prepared.appendingPathComponent(String(format: "%04d.txt", index))
      )
    }
    let transaction = ComposerVendorTransaction()

    let result = try await transaction.install(preparedVendorURL: prepared, in: project)
    #expect(
      try String(contentsOf: oldVendor.appendingPathComponent("0999.txt"), encoding: .utf8)
        == "new-999")

    try await transaction.rollback(result)
    #expect(
      try String(contentsOf: oldVendor.appendingPathComponent("0999.txt"), encoding: .utf8)
        == "old-999")
  }
}

private actor StressPackageSource: ComposerPackageSource {
  let packagesByName: [String: [ComposerRepositoryPackage]]

  init(_ packagesByName: [String: [ComposerRepositoryPackage]]) {
    self.packagesByName = packagesByName
  }

  func packages(
    named packageName: String,
    includeDevelopmentVersions: Bool
  ) async throws -> [ComposerRepositoryPackage] {
    packagesByName[packageName] ?? []
  }
}
