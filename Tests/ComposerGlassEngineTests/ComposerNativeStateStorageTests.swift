import Foundation
import Testing

@testable import ComposerGlassEngine

@Suite("Composer native state storage")
struct ComposerNativeStateStorageTests {
  @Test("State is stored outside the managed project")
  func storesStateOutsideProject() throws {
    let fixture = try stateStorageFixture()
    defer { try? FileManager.default.removeItem(at: fixture.workspaceURL) }

    let stateURL = try fixture.storage.stateDirectory(for: fixture.projectURL)

    #expect(stateURL.deletingLastPathComponent().standardizedFileURL == fixture.rootURL)
    #expect(!stateURL.path.hasPrefix(fixture.projectURL.path + "/"))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.projectURL.appendingPathComponent(".composerglass-engine").path
      )
    )
    #expect(try fixture.storage.stateDirectory(for: fixture.projectURL) == stateURL)
  }

  @Test("Legacy project state is migrated with rollback paths and hidden files")
  func migratesLegacyState() throws {
    let fixture = try stateStorageFixture()
    defer { try? FileManager.default.removeItem(at: fixture.workspaceURL) }
    let legacyURL = fixture.projectURL.appendingPathComponent(".composerglass-engine")
    let backupURL = legacyURL.appendingPathComponent("backups/transaction/vendor")
    try FileManager.default.createDirectory(at: backupURL, withIntermediateDirectories: true)
    try Data("protected".utf8).write(to: backupURL.appendingPathComponent(".htaccess"))
    let journalURL = legacyURL.appendingPathComponent("backups/transaction/transaction.json")
    let journal: [String: Any] = [
      "projectPath": fixture.projectURL.path,
      "backupDirectoryPath": legacyURL.appendingPathComponent("backups/transaction").path,
      "preparedVendorPath": legacyURL.appendingPathComponent("staging/id/vendor").path,
    ]
    try JSONSerialization.data(withJSONObject: journal).write(to: journalURL)

    let stateURL = try fixture.storage.stateDirectory(for: fixture.projectURL)

    #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    #expect(
      try String(
        contentsOf: stateURL.appendingPathComponent("backups/transaction/vendor/.htaccess"),
        encoding: .utf8
      ) == "protected"
    )
    let migrated = try #require(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: stateURL.appendingPathComponent("backups/transaction/transaction.json"))
      ) as? [String: String]
    )
    #expect(migrated["projectPath"] == fixture.projectURL.path)
    #expect(
      migrated["backupDirectoryPath"]
        == stateURL.appendingPathComponent("backups/transaction").path
    )
    #expect(
      migrated["preparedVendorPath"]
        == stateURL.appendingPathComponent("staging/id/vendor").path
    )
  }

  @Test("Legacy and current state merge without losing either side")
  func mergesLegacyState() throws {
    let fixture = try stateStorageFixture()
    defer { try? FileManager.default.removeItem(at: fixture.workspaceURL) }
    let stateURL = try fixture.storage.stateDirectory(for: fixture.projectURL)
    try Data("current".utf8).write(to: stateURL.appendingPathComponent("current.txt"))
    let legacyURL = fixture.projectURL.appendingPathComponent(".composerglass-engine")
    try FileManager.default.createDirectory(at: legacyURL, withIntermediateDirectories: true)
    try Data("legacy".utf8).write(to: legacyURL.appendingPathComponent("legacy.txt"))

    let mergedURL = try fixture.storage.stateDirectory(for: fixture.projectURL)

    #expect(try Data(contentsOf: mergedURL.appendingPathComponent("current.txt")) == Data("current".utf8))
    #expect(try Data(contentsOf: mergedURL.appendingPathComponent("legacy.txt")) == Data("legacy".utf8))
    #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
  }

  @Test("Conflicting migration data is preserved and reported")
  func preservesMigrationConflicts() throws {
    let fixture = try stateStorageFixture()
    defer { try? FileManager.default.removeItem(at: fixture.workspaceURL) }
    let stateURL = try fixture.storage.stateDirectory(for: fixture.projectURL)
    let destinationURL = stateURL.appendingPathComponent("active-transaction.json")
    try Data("current".utf8).write(to: destinationURL)
    let legacyURL = fixture.projectURL.appendingPathComponent(".composerglass-engine")
    try FileManager.default.createDirectory(at: legacyURL, withIntermediateDirectories: true)
    let sourceURL = legacyURL.appendingPathComponent("active-transaction.json")
    try Data("legacy".utf8).write(to: sourceURL)

    do {
      _ = try fixture.storage.stateDirectory(for: fixture.projectURL)
      Issue.record("Expected conflicting state migration to fail")
    } catch let ComposerNativeStateStorageError.migrationConflict(source, destination) {
      #expect(
        source.path.hasSuffix(
          "/Project/.composerglass-engine/active-transaction.json"
        )
      )
      #expect(destination == destinationURL)
    }
    #expect(try Data(contentsOf: sourceURL) == Data("legacy".utf8))
    #expect(try Data(contentsOf: destinationURL) == Data("current".utf8))
  }

  @Test("The state root cannot be inside the managed project")
  func rejectsProjectLocalStorage() throws {
    let fixture = try stateStorageFixture()
    defer { try? FileManager.default.removeItem(at: fixture.workspaceURL) }
    let unsafeRoot = fixture.projectURL.appendingPathComponent("State")
    let storage = ComposerNativeStateStorage(rootDirectoryURL: unsafeRoot)

    #expect(
      throws: ComposerNativeStateStorageError.unsafeStorageLocation(unsafeRoot)
    ) {
      try storage.stateDirectory(for: fixture.projectURL)
    }
  }
}

private struct ComposerNativeStateStorageFixture {
  let workspaceURL: URL
  let projectURL: URL
  let rootURL: URL
  let storage: ComposerNativeStateStorage
}

private func stateStorageFixture() throws -> ComposerNativeStateStorageFixture {
  let workspaceURL = try zipTemporaryDirectory()
  let projectURL = workspaceURL.appendingPathComponent("Project", isDirectory: true)
  let rootURL = workspaceURL.appendingPathComponent("State", isDirectory: true)
  try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
  return ComposerNativeStateStorageFixture(
    workspaceURL: workspaceURL,
    projectURL: projectURL,
    rootURL: rootURL,
    storage: ComposerNativeStateStorage(rootDirectoryURL: rootURL)
  )
}

func nativeTestStateRoot(for projectURL: URL) -> URL {
  projectURL.appendingPathExtension("composerglass-state")
}

func nativeTestStateStorage(for projectURL: URL) -> ComposerNativeStateStorage {
  ComposerNativeStateStorage(rootDirectoryURL: nativeTestStateRoot(for: projectURL))
}

func removeNativeTestArtifacts(for projectURL: URL) {
  try? FileManager.default.removeItem(at: projectURL)
  try? FileManager.default.removeItem(at: nativeTestStateRoot(for: projectURL))
}
