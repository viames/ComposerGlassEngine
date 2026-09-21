import Foundation
import Testing

@testable import ComposerGlassEngine

@Suite("Composer native maintenance")
struct ComposerNativeMaintenanceTests {
  @Test("Dump-autoload replaces generated metadata transactionally and supports rollback")
  func dumpsAutoloadAndRollsBack() async throws {
    let project = try maintenanceTemporaryDirectory()
    defer { removeNativeTestArtifacts(for: project) }
    try Data(
      #"{"autoload":{"psr-4":{"Project\\":"src/"}}}"#.utf8
    ).write(to: project.appendingPathComponent("composer.json"))
    let vendor = project.appendingPathComponent("vendor", isDirectory: true)
    try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
    let composerDirectory = vendor.appendingPathComponent("composer", isDirectory: true)
    try FileManager.default.createDirectory(
      at: composerDirectory,
      withIntermediateDirectories: true
    )
    let installedPHP = composerDirectory.appendingPathComponent("installed.php")
    try Data("<?php return 'preserved';\n".utf8).write(to: installedPHP)
    let marker = vendor.appendingPathComponent("before.txt")
    try Data("before".utf8).write(to: marker)
    let maintenance = ComposerNativeMaintenance(
      stateStorage: nativeTestStateStorage(for: project)
    )

    let result = try await maintenance.dumpAutoload(projectDirectoryURL: project)

    #expect(
      FileManager.default.fileExists(atPath: vendor.appendingPathComponent("autoload.php").path))
    #expect(FileManager.default.fileExists(atPath: marker.path))
    #expect(try String(contentsOf: installedPHP, encoding: .utf8) == "<?php return 'preserved';\n")

    try await maintenance.rollback(result)

    #expect(
      !FileManager.default.fileExists(atPath: vendor.appendingPathComponent("autoload.php").path))
    #expect(try String(contentsOf: marker, encoding: .utf8) == "before")
  }

  @Test("Symbolic links are rejected before vendor is copied")
  func rejectsSymbolicLinks() async throws {
    let project = try maintenanceTemporaryDirectory()
    defer { removeNativeTestArtifacts(for: project) }
    try Data(#"{}"#.utf8).write(to: project.appendingPathComponent("composer.json"))
    let vendor = project.appendingPathComponent("vendor", isDirectory: true)
    try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
    let target = project.appendingPathComponent("target")
    try Data().write(to: target)
    let link = vendor.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    do {
      _ = try await ComposerNativeMaintenance(
        stateStorage: nativeTestStateStorage(for: project)
      ).dumpAutoload(projectDirectoryURL: project)
      Issue.record("Expected symbolic-link validation to fail")
    } catch let ComposerNativeMaintenanceError.symbolicLink(url) {
      #expect(url.lastPathComponent == "link")
    }
  }
}

private func maintenanceTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("ComposerNativeMaintenanceTests-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
