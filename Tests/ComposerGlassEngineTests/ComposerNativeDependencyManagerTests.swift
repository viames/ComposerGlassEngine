import Foundation
import Testing

@testable import ComposerGlassEngine

@Suite("Composer native dependency manager")
struct ComposerNativeDependencyManagerTests {
  @Test("Require resolves, writes, installs, and rolls back every project artifact")
  func requiresAndRollsBackPackage() async throws {
    let projectURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: projectURL) }
    let originalManifest = Data(#"{"name":"example/project"}"#.utf8)
    try originalManifest.write(to: projectURL.appendingPathComponent("composer.json"))
    let source = DependencyStubSource(packages: [
      "vendor/library": [try metapackage("vendor/library", "1.4.2")]
    ])
    let manager = try makeManager(source: source, projectURL: projectURL)

    let result = try await manager.perform(
      .require(package: "vendor/library", constraint: nil, development: false),
      in: projectURL
    )
    let manifest = try ComposerManifest.decode(
      from: Data(contentsOf: projectURL.appendingPathComponent("composer.json"))
    )
    let lock = try ComposerLockFile.decode(
      from: Data(contentsOf: projectURL.appendingPathComponent("composer.lock"))
    )

    #expect(try manifest.requirements()["vendor/library"] == "^1.4")
    #expect(try lock.packages().map(\.name) == ["vendor/library"])
    #expect(
      FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("vendor").path))
    let mutation = try #require(result.mutation)
    #expect(
      try await manager.completedMutations(in: projectURL).map(\.identifier) == [
        mutation.identifier
      ])

    try await manager.rollback(mutation)

    #expect(
      try Data(contentsOf: projectURL.appendingPathComponent("composer.json")) == originalManifest)
    #expect(
      !FileManager.default.fileExists(
        atPath: projectURL.appendingPathComponent("composer.lock").path))
    #expect(
      !FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("vendor").path))
  }

  @Test("Remove updates the manifest and can restore the preceding installed state")
  func removesAndRestoresPackage() async throws {
    let projectURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: projectURL) }
    try Data(#"{"require":{"vendor/library":"^1.0"}}"#.utf8).write(
      to: projectURL.appendingPathComponent("composer.json")
    )
    let source = DependencyStubSource(packages: [
      "vendor/library": [try metapackage("vendor/library", "1.2.0")]
    ])
    let manager = try makeManager(source: source, projectURL: projectURL)
    _ = try await manager.perform(.updateAll, in: projectURL)
    let installedManifest = try Data(contentsOf: projectURL.appendingPathComponent("composer.json"))
    let installedLock = try Data(contentsOf: projectURL.appendingPathComponent("composer.lock"))

    let removal = try await manager.perform(.remove(package: "vendor/library"), in: projectURL)
    let removedManifest = try ComposerManifest.decode(
      from: Data(contentsOf: projectURL.appendingPathComponent("composer.json"))
    )
    #expect(try removedManifest.requirements().isEmpty)
    #expect(try removal.lockFile.packages().isEmpty)

    try await manager.rollback(try #require(removal.mutation))

    #expect(
      try Data(contentsOf: projectURL.appendingPathComponent("composer.json")) == installedManifest)
    #expect(
      try Data(contentsOf: projectURL.appendingPathComponent("composer.lock")) == installedLock)
  }

  @Test("A selective dry run keeps unrelated locked root packages pinned")
  func selectivelyUpdatesOnePackage() async throws {
    let projectURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: projectURL) }
    let manifestData = Data(
      #"{"require":{"vendor/a":"^1.0 || ^2.0","vendor/b":"^1.0 || ^2.0"}}"#.utf8
    )
    try manifestData.write(to: projectURL.appendingPathComponent("composer.json"))
    let oldA = try ComposerLockedPackage(
      name: "vendor/a",
      version: "1.0.0",
      fields: try metapackage("vendor/a", "1.0.0").fields
    )
    let oldB = try ComposerLockedPackage(
      name: "vendor/b",
      version: "1.0.0",
      fields: try metapackage("vendor/b", "1.0.0").fields
    )
    let lock = try ComposerLockFile(
      contentHash: ComposerContentHash.compute(from: manifestData),
      packages: [oldA, oldB]
    )
    try lock.encoded().write(to: projectURL.appendingPathComponent("composer.lock"))
    let source = DependencyStubSource(packages: [
      "vendor/a": [try metapackage("vendor/a", "1.0.0"), try metapackage("vendor/a", "2.0.0")],
      "vendor/b": [try metapackage("vendor/b", "1.0.0"), try metapackage("vendor/b", "2.0.0")],
    ])
    let manager = try makeManager(source: source, projectURL: projectURL)

    let result = try await manager.perform(
      .updateSelected(packages: ["vendor/a"], withDependencies: false),
      in: projectURL,
      dryRun: true
    )

    #expect(
      try result.lockFile.packages().map { $0.name + "@" + $0.version } == [
        "vendor/a@2.0.0", "vendor/b@1.0.0",
      ])
    #expect(
      try Data(contentsOf: projectURL.appendingPathComponent("composer.json")) == manifestData)
    #expect(
      !FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("vendor").path))
  }

  @Test("Removing an undeclared package fails without changing the project")
  func rejectsRemovingUndeclaredPackage() async throws {
    let projectURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: projectURL) }
    let manifestData = Data(#"{"name":"example/project"}"#.utf8)
    try manifestData.write(to: projectURL.appendingPathComponent("composer.json"))
    let manager = try makeManager(
      source: DependencyStubSource(packages: [:]), projectURL: projectURL)

    await #expect(throws: ComposerNativeDependencyError.packageNotRequired("vendor/missing")) {
      try await manager.perform(.remove(package: "vendor/missing"), in: projectURL)
    }

    #expect(
      try Data(contentsOf: projectURL.appendingPathComponent("composer.json")) == manifestData)
  }

  @Test("Recovery restores project files when interruption precedes vendor activation")
  func recoversBeforeVendorActivation() async throws {
    let projectURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: projectURL) }
    let manifestData = Data(#"{"require":{"vendor/library":"^1.0"}}"#.utf8)
    try manifestData.write(to: projectURL.appendingPathComponent("composer.json"))
    let source = DependencyStubSource(packages: [
      "vendor/library": [try metapackage("vendor/library", "1.0.0")]
    ])
    let interrupted = try makeManager(
      source: source,
      projectURL: projectURL,
      interruptionPoint: .afterProjectFilesWritten
    )

    await #expect(throws: ComposerNativeDependencyManagerTestError.simulatedInterruption) {
      try await interrupted.perform(.updateAll, in: projectURL)
    }
    let recovery = try makeManager(source: source, projectURL: projectURL)

    let recovered = try await recovery.recoverInterruptedMutation(in: projectURL)

    #expect(recovered == nil)
    #expect(
      try Data(contentsOf: projectURL.appendingPathComponent("composer.json")) == manifestData)
    #expect(
      !FileManager.default.fileExists(
        atPath: projectURL.appendingPathComponent("composer.lock").path
      ))
  }

  @Test("Recovery commits project files when vendor activation had completed")
  func recoversAfterVendorActivation() async throws {
    let projectURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: projectURL) }
    try Data(#"{"require":{"vendor/library":"^1.0"}}"#.utf8).write(
      to: projectURL.appendingPathComponent("composer.json")
    )
    let source = DependencyStubSource(packages: [
      "vendor/library": [try metapackage("vendor/library", "1.0.0")]
    ])
    let interrupted = try makeManager(
      source: source,
      projectURL: projectURL,
      interruptionPoint: .afterVendorInstalled
    )

    await #expect(throws: ComposerNativeDependencyManagerTestError.simulatedInterruption) {
      try await interrupted.perform(.updateAll, in: projectURL)
    }
    let recovery = try makeManager(source: source, projectURL: projectURL)

    let recovered = try #require(
      try await recovery.recoverInterruptedMutation(in: projectURL)
    )

    #expect(
      FileManager.default.fileExists(
        atPath: projectURL.appendingPathComponent("composer.lock").path
      ))
    #expect(
      FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("vendor").path))
    #expect(
      try await recovery.completedMutations(in: projectURL).first?.identifier
        == recovered.identifier)
  }

  private func makeManager(
    source: DependencyStubSource,
    projectURL: URL,
    interruptionPoint: ComposerNativeDependencyManagerInterruptionPoint? = nil
  ) throws -> ComposerNativeDependencyManager {
    let cacheURL = projectURL.appendingPathComponent("cache", isDirectory: true)
    let installer = ComposerNativeInstaller(
      downloader: try ComposerPackageDownloader(cacheDirectory: cacheURL)
    )
    return ComposerNativeDependencyManager(
      source: source,
      installer: installer,
      interruptionPoint: interruptionPoint
    )
  }

  private func metapackage(_ name: String, _ version: String) throws
    -> ComposerRepositoryPackage
  {
    try ComposerRepositoryPackage(
      name: name,
      version: version,
      additionalFields: ["type": .string("metapackage")]
    )
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ComposerNativeDependencyManagerTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

private actor DependencyStubSource: ComposerPackageSource {
  let storedPackages: [String: [ComposerRepositoryPackage]]

  init(packages: [String: [ComposerRepositoryPackage]]) {
    self.storedPackages = packages
  }

  func packages(
    named packageName: String,
    includeDevelopmentVersions: Bool
  ) async throws -> [ComposerRepositoryPackage] {
    storedPackages[packageName] ?? []
  }
}
