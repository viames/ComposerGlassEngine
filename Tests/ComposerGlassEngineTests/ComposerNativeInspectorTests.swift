import Foundation
import Testing

@testable import ComposerGlassEngine

@Suite("Composer native inspector")
struct ComposerNativeInspectorTests {
  @Test("Validate reports stale locks, duplicate roots, and unsupported plugins")
  func validatesProjectSemantics() async throws {
    let project = try temporaryDirectory(prefix: "ComposerNativeInspectorTests")
    defer { try? FileManager.default.removeItem(at: project) }
    let manifestData = Data(
      #"{"require":{"vendor/plugin":"^1.0"},"require-dev":{"vendor/plugin":"^1.0"}}"#.utf8
    )
    try manifestData.write(to: project.appendingPathComponent("composer.json"))
    let plugin = try ComposerLockedPackage(
      name: "vendor/plugin",
      version: "1.0.0",
      fields: ["type": .string("composer-plugin")]
    )
    let lock = try ComposerLockFile(
      contentHash: String(repeating: "0", count: 32),
      packages: [plugin]
    )
    try lock.encoded().write(to: project.appendingPathComponent("composer.lock"))
    let inspector = ComposerNativeInspector(source: InspectorStubSource(packages: [:]))

    let result = try await inspector.validate(projectDirectoryURL: project)

    #expect(result.errors.map(\.code).contains(.lockFileStale))
    #expect(result.warnings.map(\.code).contains(.missingPackageName))
    #expect(result.warnings.map(\.code).contains(.duplicateRuntimeAndDevelopmentRequirement))
    #expect(result.warnings.map(\.code).contains(.unsupportedComposerPlugin))
  }

  @Test("Show identifies direct, transitive, runtime, and development packages")
  func showsLockedPackages() async throws {
    let project = try temporaryDirectory(prefix: "ComposerNativeInspectorTests")
    defer { try? FileManager.default.removeItem(at: project) }
    let manifestData = Data(
      #"{"require":{"vendor/app":"^1.0"},"require-dev":{"vendor/tool":"^2.0"}}"#.utf8
    )
    try manifestData.write(to: project.appendingPathComponent("composer.json"))
    let lock = try ComposerLockFile(
      contentHash: ComposerContentHash.compute(from: manifestData),
      packages: [
        try ComposerLockedPackage(name: "vendor/app", version: "1.0.0"),
        try ComposerLockedPackage(name: "vendor/transitive", version: "1.1.0"),
      ],
      developmentPackages: [
        try ComposerLockedPackage(name: "vendor/tool", version: "2.0.0")
      ]
    )
    try lock.encoded().write(to: project.appendingPathComponent("composer.lock"))
    let inspector = ComposerNativeInspector(source: InspectorStubSource(packages: [:]))

    let packages = try await inspector.show(projectDirectoryURL: project)

    #expect(packages.map(\.name) == ["vendor/app", "vendor/tool", "vendor/transitive"])
    #expect(packages.first(where: { $0.name == "vendor/app" })?.directRequirement == true)
    #expect(packages.first(where: { $0.name == "vendor/transitive" })?.directRequirement == false)
    #expect(packages.first(where: { $0.name == "vendor/tool" })?.isDevelopment == true)
  }

  @Test("Outdated distinguishes the latest release from the latest root-compatible release")
  func findsOutdatedPackages() async throws {
    let project = try temporaryDirectory(prefix: "ComposerNativeInspectorTests")
    defer { try? FileManager.default.removeItem(at: project) }
    let manifestData = Data(#"{"require":{"vendor/app":"^1.0"}}"#.utf8)
    try manifestData.write(to: project.appendingPathComponent("composer.json"))
    let lock = try ComposerLockFile(
      contentHash: ComposerContentHash.compute(from: manifestData),
      packages: [try ComposerLockedPackage(name: "vendor/app", version: "1.0.0")]
    )
    try lock.encoded().write(to: project.appendingPathComponent("composer.lock"))
    let source = InspectorStubSource(packages: [
      "vendor/app": [
        try ComposerRepositoryPackage(name: "vendor/app", version: "1.0.0"),
        try ComposerRepositoryPackage(name: "vendor/app", version: "1.8.0"),
        try ComposerRepositoryPackage(name: "vendor/app", version: "2.0.0"),
      ]
    ])

    let outdated = try await ComposerNativeInspector(source: source).outdated(
      projectDirectoryURL: project
    )

    #expect(outdated.first?.latestVersion == "2.0.0")
    #expect(outdated.first?.latestCompatibleVersion == "1.8.0")
  }
}

private actor InspectorStubSource: ComposerPackageSource {
  let stored: [String: [ComposerRepositoryPackage]]

  init(packages: [String: [ComposerRepositoryPackage]]) {
    stored = packages
  }

  func packages(
    named packageName: String,
    includeDevelopmentVersions: Bool
  ) async throws -> [ComposerRepositoryPackage] {
    stored[packageName] ?? []
  }
}

private func temporaryDirectory(prefix: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent(prefix + "-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
