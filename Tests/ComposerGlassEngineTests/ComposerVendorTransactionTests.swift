import Foundation
import Testing

@testable import ComposerGlassEngine

@Suite("Composer vendor transaction")
struct ComposerVendorTransactionTests {
  @Test("Installation replaces vendor and rollback restores it")
  func installsAndRollsBack() async throws {
    let project = try transactionProject()
    defer { removeNativeTestArtifacts(for: project) }
    let oldVendor = project.appendingPathComponent("vendor")
    try FileManager.default.createDirectory(at: oldVendor, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: oldVendor.appendingPathComponent("old.txt"))
    let prepared = project.appendingPathComponent("prepared-vendor")
    try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
    try Data("new".utf8).write(to: prepared.appendingPathComponent("new.txt"))
    let transaction = ComposerVendorTransaction(
      stateStorage: nativeTestStateStorage(for: project)
    )

    let result = try await transaction.install(
      preparedVendorURL: prepared,
      in: project
    )

    #expect(result.replacedExistingVendor)
    #expect(!FileManager.default.fileExists(atPath: prepared.path))
    #expect(
      try Data(contentsOf: oldVendor.appendingPathComponent("new.txt")) == Data("new".utf8)
    )
    #expect(
      FileManager.default.fileExists(
        atPath: result.backupDirectoryURL.appendingPathComponent("vendor/old.txt").path
      )
    )

    try await transaction.rollback(result)

    #expect(
      try Data(contentsOf: oldVendor.appendingPathComponent("old.txt")) == Data("old".utf8)
    )
    #expect(
      !FileManager.default.fileExists(atPath: oldVendor.appendingPathComponent("new.txt").path))
    #expect(!FileManager.default.fileExists(atPath: result.backupDirectoryURL.path))
  }

  @Test("Rollback removes a newly introduced vendor directory")
  func rollsBackWithoutPreviousVendor() async throws {
    let project = try transactionProject()
    defer { removeNativeTestArtifacts(for: project) }
    let prepared = project.appendingPathComponent("prepared-vendor")
    try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
    try Data("new".utf8).write(to: prepared.appendingPathComponent("new.txt"))
    let transaction = ComposerVendorTransaction(
      stateStorage: nativeTestStateStorage(for: project)
    )
    let result = try await transaction.install(preparedVendorURL: prepared, in: project)

    try await transaction.rollback(result)

    #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("vendor").path))
  }

  @Test("Rollback refuses an externally changed vendor tree")
  func rejectsChangedVendorRollback() async throws {
    let project = try transactionProject()
    defer { removeNativeTestArtifacts(for: project) }
    let prepared = project.appendingPathComponent("prepared-vendor")
    try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
    try Data("new".utf8).write(to: prepared.appendingPathComponent("new.txt"))
    let transaction = ComposerVendorTransaction(
      stateStorage: nativeTestStateStorage(for: project)
    )
    let result = try await transaction.install(preparedVendorURL: prepared, in: project)
    try Data("changed".utf8).write(
      to: project.appendingPathComponent("vendor/new.txt"),
      options: .atomic
    )

    do {
      try await transaction.rollback(result)
      Issue.record("Expected changed vendor rollback to fail")
    } catch let error as ComposerVendorTransactionError {
      guard case .rollbackConflict(let expected, let actual) = error else {
        Issue.record("Expected rollback conflict, received \(error)")
        return
      }
      #expect(expected == result.installedDigest)
      #expect(actual != nil)
      #expect(actual != expected)
    }
    #expect(
      try Data(contentsOf: project.appendingPathComponent("vendor/new.txt"))
        == Data("changed".utf8)
    )
  }

  @Test("Recovery restores the previous vendor after an interrupted move")
  func recoversOldVendorMove() async throws {
    let project = try transactionProject()
    defer { removeNativeTestArtifacts(for: project) }
    let active = project.appendingPathComponent("vendor")
    try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: active.appendingPathComponent("old.txt"))
    let prepared = project.appendingPathComponent("prepared-vendor")
    try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
    try Data("new".utf8).write(to: prepared.appendingPathComponent("new.txt"))
    let stateStorage = nativeTestStateStorage(for: project)
    let interrupted = ComposerVendorTransaction(
      interruptionPoint: .afterOldVendorMoved,
      stateStorage: stateStorage
    )

    await #expect(throws: ComposerVendorTransactionTestError.simulatedInterruption) {
      try await interrupted.install(preparedVendorURL: prepared, in: project)
    }

    let recovery = ComposerVendorTransaction(stateStorage: stateStorage)
    let result = try await recovery.recoverInterruptedTransaction(in: project)
    #expect(result == .restoredPreviousVendor)
    #expect(
      try Data(contentsOf: active.appendingPathComponent("old.txt")) == Data("old".utf8)
    )
    #expect(FileManager.default.fileExists(atPath: prepared.appendingPathComponent("new.txt").path))
  }

  @Test("Recovery completes an installation interrupted after the new move")
  func completesInterruptedInstallation() async throws {
    let project = try transactionProject()
    defer { removeNativeTestArtifacts(for: project) }
    let prepared = project.appendingPathComponent("prepared-vendor")
    try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
    try Data("new".utf8).write(to: prepared.appendingPathComponent("new.txt"))
    let stateStorage = nativeTestStateStorage(for: project)
    let interrupted = ComposerVendorTransaction(
      interruptionPoint: .afterNewVendorMoved,
      stateStorage: stateStorage
    )

    await #expect(throws: ComposerVendorTransactionTestError.simulatedInterruption) {
      try await interrupted.install(preparedVendorURL: prepared, in: project)
    }

    let recovery = ComposerVendorTransaction(stateStorage: stateStorage)
    let result = try await recovery.recoverInterruptedTransaction(in: project)
    guard case .completedInstallation(let transaction)? = result else {
      Issue.record("Expected installation recovery")
      return
    }
    #expect(!transaction.replacedExistingVendor)
    #expect(
      try Data(contentsOf: project.appendingPathComponent("vendor/new.txt")) == Data("new".utf8)
    )
    try await recovery.rollback(transaction)
    #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("vendor").path))
  }
}

private func transactionProject() throws -> URL {
  try zipTemporaryDirectory()
}
