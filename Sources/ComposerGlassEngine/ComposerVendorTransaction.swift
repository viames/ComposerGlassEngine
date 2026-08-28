import CryptoKit
import Foundation

public enum ComposerVendorTransactionError: Error, Equatable, Sendable {
  case projectDirectoryMissing(URL)
  case preparedVendorMissing(URL)
  case preparedVendorIsActiveVendor
  case symbolicLink(URL)
  case differentVolume
  case interruptedTransactionExists(URL)
  case invalidJournal(URL)
  case recoveryConflict(URL)
  case rollbackConflict(expected: String, actual: String?)
  case invalidBackup(URL)
}

public struct ComposerVendorTransactionResult: Equatable, Sendable {
  public let identifier: UUID
  public let projectDirectoryURL: URL
  public let vendorDirectoryURL: URL
  public let backupDirectoryURL: URL
  public let installedDigest: String
  public let replacedExistingVendor: Bool

  public init(
    identifier: UUID,
    projectDirectoryURL: URL,
    vendorDirectoryURL: URL,
    backupDirectoryURL: URL,
    installedDigest: String,
    replacedExistingVendor: Bool
  ) {
    self.identifier = identifier
    self.projectDirectoryURL = projectDirectoryURL
    self.vendorDirectoryURL = vendorDirectoryURL
    self.backupDirectoryURL = backupDirectoryURL
    self.installedDigest = installedDigest
    self.replacedExistingVendor = replacedExistingVendor
  }
}

public enum ComposerVendorRecoveryResult: Equatable, Sendable {
  case restoredPreviousVendor
  case discardedUnstartedTransaction
  case completedInstallation(ComposerVendorTransactionResult)
}

enum ComposerVendorTransactionInterruptionPoint: Sendable {
  case afterOldVendorMoved
  case afterNewVendorMoved
}

enum ComposerVendorTransactionTestError: Error {
  case simulatedInterruption
}

/// Atomically activates a prepared vendor tree on the same volume and keeps a
/// persistent backup that can be rolled back after process restart.
public actor ComposerVendorTransaction {
  private enum Phase: String, Codable {
    case prepared
    case movingOldVendor
    case oldVendorMoved
    case installingNewVendor
    case newVendorInstalled
  }

  private struct Journal: Codable {
    let identifier: UUID
    let projectPath: String
    let preparedVendorPath: String
    let activeVendorPath: String
    let backupDirectoryPath: String
    let createdAt: Date
    var phase: Phase
    let replacedExistingVendor: Bool
    var installedDigest: String?
  }

  private let fileManager: FileManager
  private let interruptionPoint: ComposerVendorTransactionInterruptionPoint?

  public init() {
    self.fileManager = FileManager()
    self.interruptionPoint = nil
  }

  init(interruptionPoint: ComposerVendorTransactionInterruptionPoint?) {
    self.fileManager = FileManager()
    self.interruptionPoint = interruptionPoint
  }

  public func install(
    preparedVendorURL: URL,
    in projectDirectoryURL: URL
  ) throws -> ComposerVendorTransactionResult {
    let projectURL = projectDirectoryURL.standardizedFileURL
    let preparedURL = preparedVendorURL.standardizedFileURL
    let activeVendorURL = projectURL.appendingPathComponent("vendor", isDirectory: true)
    try validateDirectory(projectURL, missing: .projectDirectoryMissing(projectURL))
    try validateDirectory(preparedURL, missing: .preparedVendorMissing(preparedURL))
    guard preparedURL != activeVendorURL else {
      throw ComposerVendorTransactionError.preparedVendorIsActiveVendor
    }
    try validateSameVolume(preparedURL, activeVendorURL.deletingLastPathComponent())

    let stateDirectoryURL = try stateDirectory(in: projectURL)
    let activeJournalURL = stateDirectoryURL.appendingPathComponent("active-transaction.json")
    guard !fileManager.fileExists(atPath: activeJournalURL.path) else {
      throw ComposerVendorTransactionError.interruptedTransactionExists(activeJournalURL)
    }
    if fileManager.fileExists(atPath: activeVendorURL.path) {
      try rejectSymbolicLink(activeVendorURL)
    }

    let identifier = UUID()
    let backupDirectoryURL =
      stateDirectoryURL
      .appendingPathComponent("backups", isDirectory: true)
      .appendingPathComponent(identifier.uuidString, isDirectory: true)
    try fileManager.createDirectory(
      at: backupDirectoryURL,
      withIntermediateDirectories: true
    )
    let previousVendorURL = backupDirectoryURL.appendingPathComponent(
      "vendor",
      isDirectory: true
    )
    let replacedExistingVendor = fileManager.fileExists(atPath: activeVendorURL.path)
    var journal = Journal(
      identifier: identifier,
      projectPath: projectURL.path,
      preparedVendorPath: preparedURL.path,
      activeVendorPath: activeVendorURL.path,
      backupDirectoryPath: backupDirectoryURL.path,
      createdAt: Date(),
      phase: .prepared,
      replacedExistingVendor: replacedExistingVendor,
      installedDigest: nil
    )
    try write(journal, to: activeJournalURL)

    do {
      if replacedExistingVendor {
        journal.phase = .movingOldVendor
        try write(journal, to: activeJournalURL)
        try fileManager.moveItem(at: activeVendorURL, to: previousVendorURL)
      }
      journal.phase = .oldVendorMoved
      try write(journal, to: activeJournalURL)
      if interruptionPoint == .afterOldVendorMoved {
        throw ComposerVendorTransactionTestError.simulatedInterruption
      }

      journal.phase = .installingNewVendor
      try write(journal, to: activeJournalURL)
      try fileManager.moveItem(at: preparedURL, to: activeVendorURL)
      let digest = try treeDigest(at: activeVendorURL)
      journal.phase = .newVendorInstalled
      journal.installedDigest = digest
      try write(journal, to: activeJournalURL)
      if interruptionPoint == .afterNewVendorMoved {
        throw ComposerVendorTransactionTestError.simulatedInterruption
      }

      let result = result(from: journal, digest: digest)
      try persistCompleted(journal, at: activeJournalURL)
      return result
    } catch ComposerVendorTransactionTestError.simulatedInterruption {
      throw ComposerVendorTransactionTestError.simulatedInterruption
    } catch {
      try? restoreAfterFailure(journal)
      try? fileManager.removeItem(at: activeJournalURL)
      try? fileManager.removeItem(at: backupDirectoryURL)
      throw error
    }
  }

  public func recoverInterruptedTransaction(
    in projectDirectoryURL: URL
  ) throws -> ComposerVendorRecoveryResult? {
    let projectURL = projectDirectoryURL.standardizedFileURL
    let activeJournalURL =
      projectURL
      .appendingPathComponent(".composerglass-engine", isDirectory: true)
      .appendingPathComponent("active-transaction.json")
    guard fileManager.fileExists(atPath: activeJournalURL.path) else {
      return nil
    }
    var journal = try readJournal(at: activeJournalURL)
    guard journal.projectPath == projectURL.path else {
      throw ComposerVendorTransactionError.invalidJournal(activeJournalURL)
    }
    let activeURL = URL(fileURLWithPath: journal.activeVendorPath)
    let preparedURL = URL(fileURLWithPath: journal.preparedVendorPath)
    let backupURL = URL(fileURLWithPath: journal.backupDirectoryPath)
    let previousURL = backupURL.appendingPathComponent("vendor", isDirectory: true)

    switch journal.phase {
    case .prepared:
      try fileManager.removeItem(at: activeJournalURL)
      try? fileManager.removeItem(at: backupURL)
      return .discardedUnstartedTransaction

    case .movingOldVendor:
      let activeExists = fileManager.fileExists(atPath: activeURL.path)
      let previousExists = fileManager.fileExists(atPath: previousURL.path)
      if activeExists, !previousExists {
        try fileManager.removeItem(at: activeJournalURL)
        try? fileManager.removeItem(at: backupURL)
        return .discardedUnstartedTransaction
      }
      guard !activeExists, previousExists else {
        throw ComposerVendorTransactionError.recoveryConflict(activeURL)
      }
      try fileManager.moveItem(at: previousURL, to: activeURL)
      try fileManager.removeItem(at: activeJournalURL)
      try? fileManager.removeItem(at: backupURL)
      return .restoredPreviousVendor

    case .oldVendorMoved:
      guard !fileManager.fileExists(atPath: activeURL.path) else {
        throw ComposerVendorTransactionError.recoveryConflict(activeURL)
      }
      if journal.replacedExistingVendor {
        guard fileManager.fileExists(atPath: previousURL.path) else {
          throw ComposerVendorTransactionError.recoveryConflict(previousURL)
        }
        try fileManager.moveItem(at: previousURL, to: activeURL)
      }
      try fileManager.removeItem(at: activeJournalURL)
      try? fileManager.removeItem(at: backupURL)
      return .restoredPreviousVendor

    case .installingNewVendor:
      let activeExists = fileManager.fileExists(atPath: activeURL.path)
      let preparedExists = fileManager.fileExists(atPath: preparedURL.path)
      if activeExists, !preparedExists {
        let digest = try treeDigest(at: activeURL)
        journal.phase = .newVendorInstalled
        journal.installedDigest = digest
        try write(journal, to: activeJournalURL)
        let result = result(from: journal, digest: digest)
        try persistCompleted(journal, at: activeJournalURL)
        return .completedInstallation(result)
      }
      if !activeExists, preparedExists {
        if journal.replacedExistingVendor {
          guard fileManager.fileExists(atPath: previousURL.path) else {
            throw ComposerVendorTransactionError.recoveryConflict(previousURL)
          }
          try fileManager.moveItem(at: previousURL, to: activeURL)
        }
        try fileManager.removeItem(at: activeJournalURL)
        try? fileManager.removeItem(at: backupURL)
        return .restoredPreviousVendor
      }
      throw ComposerVendorTransactionError.recoveryConflict(activeURL)

    case .newVendorInstalled:
      guard let expectedDigest = journal.installedDigest,
        fileManager.fileExists(atPath: activeURL.path)
      else {
        throw ComposerVendorTransactionError.recoveryConflict(activeURL)
      }
      let actualDigest = try treeDigest(at: activeURL)
      guard actualDigest == expectedDigest else {
        throw ComposerVendorTransactionError.rollbackConflict(
          expected: expectedDigest,
          actual: actualDigest
        )
      }
      let result = result(from: journal, digest: expectedDigest)
      try persistCompleted(journal, at: activeJournalURL)
      return .completedInstallation(result)
    }
  }

  public func rollback(
    _ transaction: ComposerVendorTransactionResult
  ) throws {
    let backupURL = transaction.backupDirectoryURL.standardizedFileURL
    let recordURL = backupURL.appendingPathComponent("transaction.json")
    let journal = try readJournal(at: recordURL)
    guard journal.identifier == transaction.identifier,
      journal.projectPath == transaction.projectDirectoryURL.standardizedFileURL.path,
      journal.installedDigest == transaction.installedDigest
    else {
      throw ComposerVendorTransactionError.invalidBackup(backupURL)
    }
    let activeURL = URL(fileURLWithPath: journal.activeVendorPath)
    guard fileManager.fileExists(atPath: activeURL.path) else {
      throw ComposerVendorTransactionError.rollbackConflict(
        expected: transaction.installedDigest,
        actual: nil
      )
    }
    let actualDigest = try treeDigest(at: activeURL)
    guard actualDigest == transaction.installedDigest else {
      throw ComposerVendorTransactionError.rollbackConflict(
        expected: transaction.installedDigest,
        actual: actualDigest
      )
    }

    let discardedURL = backupURL.appendingPathComponent("replaced-vendor", isDirectory: true)
    try fileManager.moveItem(at: activeURL, to: discardedURL)
    do {
      let previousURL = backupURL.appendingPathComponent("vendor", isDirectory: true)
      if journal.replacedExistingVendor {
        guard fileManager.fileExists(atPath: previousURL.path) else {
          throw ComposerVendorTransactionError.invalidBackup(backupURL)
        }
        try fileManager.moveItem(at: previousURL, to: activeURL)
      }
      try fileManager.removeItem(at: discardedURL)
      try fileManager.removeItem(at: backupURL)
    } catch {
      if !fileManager.fileExists(atPath: activeURL.path),
        fileManager.fileExists(atPath: discardedURL.path)
      {
        try? fileManager.moveItem(at: discardedURL, to: activeURL)
      }
      throw error
    }
  }

  public func completedTransactions(
    in projectDirectoryURL: URL
  ) throws -> [ComposerVendorTransactionResult] {
    let projectURL = projectDirectoryURL.standardizedFileURL
    let backupsURL =
      projectURL
      .appendingPathComponent(".composerglass-engine", isDirectory: true)
      .appendingPathComponent("backups", isDirectory: true)
    guard fileManager.fileExists(atPath: backupsURL.path) else {
      return []
    }
    let directories = try fileManager.contentsOfDirectory(
      at: backupsURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    )
    var transactions: [(Date, ComposerVendorTransactionResult)] = []
    for directory in directories {
      let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        continue
      }
      let journal = try readJournal(at: directory.appendingPathComponent("transaction.json"))
      guard journal.projectPath == projectURL.path,
        journal.backupDirectoryPath == directory.standardizedFileURL.path,
        journal.phase == .newVendorInstalled,
        let digest = journal.installedDigest
      else {
        throw ComposerVendorTransactionError.invalidBackup(directory)
      }
      transactions.append((journal.createdAt, result(from: journal, digest: digest)))
    }
    return transactions.sorted { $0.0 > $1.0 }.map(\.1)
  }

  public func discardBackup(
    _ transaction: ComposerVendorTransactionResult
  ) throws {
    let backupURL = transaction.backupDirectoryURL.standardizedFileURL
    let journal = try readJournal(at: backupURL.appendingPathComponent("transaction.json"))
    guard journal.identifier == transaction.identifier else {
      throw ComposerVendorTransactionError.invalidBackup(backupURL)
    }
    try fileManager.removeItem(at: backupURL)
  }

  private func stateDirectory(in projectURL: URL) throws -> URL {
    let stateURL = projectURL.appendingPathComponent(
      ".composerglass-engine",
      isDirectory: true
    )
    if fileManager.fileExists(atPath: stateURL.path) {
      try rejectSymbolicLink(stateURL)
    }
    try fileManager.createDirectory(at: stateURL, withIntermediateDirectories: true)
    return stateURL
  }

  private func validateDirectory(
    _ url: URL,
    missing error: ComposerVendorTransactionError
  ) throws {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw error
    }
    try rejectSymbolicLink(url)
  }

  private func rejectSymbolicLink(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
    if values.isSymbolicLink == true {
      throw ComposerVendorTransactionError.symbolicLink(url)
    }
  }

  private func validateSameVolume(_ first: URL, _ second: URL) throws {
    let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
    let firstVolume = try first.resourceValues(forKeys: keys).volumeIdentifier as? AnyHashable
    let secondVolume = try second.resourceValues(forKeys: keys).volumeIdentifier as? AnyHashable
    guard firstVolume != nil, firstVolume == secondVolume else {
      throw ComposerVendorTransactionError.differentVolume
    }
  }

  private func write(_ journal: Journal, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(journal).write(to: url, options: .atomic)
  }

  private func readJournal(at url: URL) throws -> Journal {
    do {
      return try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
    } catch {
      throw ComposerVendorTransactionError.invalidJournal(url)
    }
  }

  private func persistCompleted(_ journal: Journal, at activeJournalURL: URL) throws {
    let backupURL = URL(fileURLWithPath: journal.backupDirectoryPath)
    try write(journal, to: backupURL.appendingPathComponent("transaction.json"))
    try fileManager.removeItem(at: activeJournalURL)
  }

  private func result(from journal: Journal, digest: String) -> ComposerVendorTransactionResult {
    ComposerVendorTransactionResult(
      identifier: journal.identifier,
      projectDirectoryURL: URL(fileURLWithPath: journal.projectPath),
      vendorDirectoryURL: URL(fileURLWithPath: journal.activeVendorPath),
      backupDirectoryURL: URL(fileURLWithPath: journal.backupDirectoryPath),
      installedDigest: digest,
      replacedExistingVendor: journal.replacedExistingVendor
    )
  }

  private func restoreAfterFailure(_ journal: Journal) throws {
    let activeURL = URL(fileURLWithPath: journal.activeVendorPath)
    let preparedURL = URL(fileURLWithPath: journal.preparedVendorPath)
    let previousURL = URL(fileURLWithPath: journal.backupDirectoryPath)
      .appendingPathComponent("vendor", isDirectory: true)
    if fileManager.fileExists(atPath: activeURL.path),
      !fileManager.fileExists(atPath: preparedURL.path)
    {
      try fileManager.moveItem(at: activeURL, to: preparedURL)
    }
    if journal.replacedExistingVendor,
      fileManager.fileExists(atPath: previousURL.path),
      !fileManager.fileExists(atPath: activeURL.path)
    {
      try fileManager.moveItem(at: previousURL, to: activeURL)
    }
  }

  private func treeDigest(at rootURL: URL) throws -> String {
    try rejectSymbolicLink(rootURL)
    guard
      let enumerator = fileManager.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [
          .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
          .fileSizeKey, .isExecutableKey,
        ],
        options: []
      )
    else {
      return Self.hex(SHA256.hash(data: Data()))
    }
    var entries: [URL] = []
    for case let url as URL in enumerator {
      entries.append(url)
    }
    entries.sort { $0.path < $1.path }
    var hasher = SHA256()
    for url in entries {
      let values = try url.resourceValues(forKeys: [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        .fileSizeKey, .isExecutableKey,
      ])
      if values.isSymbolicLink == true {
        throw ComposerVendorTransactionError.symbolicLink(url)
      }
      let relative = String(url.path.dropFirst(rootURL.path.count + 1))
      let kind = values.isDirectory == true ? "d" : "f"
      let executable = values.isExecutable == true ? "x" : "-"
      hasher.update(data: Data("\(kind)\(executable):\(relative)\u{0}".utf8))
      if values.isRegularFile == true {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: 64 * 1_024), !data.isEmpty {
          hasher.update(data: data)
        }
      }
    }
    return Self.hex(hasher.finalize())
  }

  private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
  }
}
