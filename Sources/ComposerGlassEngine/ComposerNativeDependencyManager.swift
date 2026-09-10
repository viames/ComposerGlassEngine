import CryptoKit
import Foundation

public enum ComposerNativeDependencyError: Error, Equatable, Sendable {
  case projectDirectoryMissing(URL)
  case composerManifestMissing(URL)
  case composerLockMissing(URL)
  case invalidPackageName(String)
  case packageNotLocked(String)
  case packageNotRequired(String)
  case interruptedMutationExists(URL)
  case invalidMutationJournal(URL)
  case rollbackConflict(URL)
}

public enum ComposerNativeDependencyOperation: Equatable, Sendable {
  case updateAll
  case updateSelected(packages: [String], withDependencies: Bool)
  case require(package: String, constraint: String?, development: Bool)
  case remove(package: String)
}

public enum ComposerNativeDependencyEvent: Equatable, Sendable {
  case recovering
  case resolving
  case resolvingPackage(name: String, candidateCount: Int)
  case tryingVersion(package: String, version: String)
  case backtracking(package: String, version: String)
  case writingProjectFiles
  case installing(ComposerNativeInstallEvent)
  case completed
}

public struct ComposerNativeMutationResult: Equatable, Sendable {
  public let identifier: UUID
  public let projectDirectoryURL: URL
  public let backupDirectoryURL: URL
  public let vendorTransaction: ComposerVendorTransactionResult
  public let installedManifestDigest: String
  public let installedLockDigest: String

  public init(
    identifier: UUID,
    projectDirectoryURL: URL,
    backupDirectoryURL: URL,
    vendorTransaction: ComposerVendorTransactionResult,
    installedManifestDigest: String,
    installedLockDigest: String
  ) {
    self.identifier = identifier
    self.projectDirectoryURL = projectDirectoryURL
    self.backupDirectoryURL = backupDirectoryURL
    self.vendorTransaction = vendorTransaction
    self.installedManifestDigest = installedManifestDigest
    self.installedLockDigest = installedLockDigest
  }
}

public struct ComposerNativeDependencyResult: Equatable, Sendable {
  public let manifest: ComposerManifest
  public let lockFile: ComposerLockFile
  public let installResult: ComposerNativeInstallResult?
  public let mutation: ComposerNativeMutationResult?
  public let isDryRun: Bool

  public init(
    manifest: ComposerManifest,
    lockFile: ComposerLockFile,
    installResult: ComposerNativeInstallResult?,
    mutation: ComposerNativeMutationResult?,
    isDryRun: Bool
  ) {
    self.manifest = manifest
    self.lockFile = lockFile
    self.installResult = installResult
    self.mutation = mutation
    self.isDryRun = isDryRun
  }
}

enum ComposerNativeDependencyManagerInterruptionPoint: Sendable {
  case afterProjectFilesWritten
  case afterVendorInstalled
}

enum ComposerNativeDependencyManagerTestError: Error {
  case simulatedInterruption
}

/// Resolves and applies dependency mutations without invoking PHP, Composer,
/// package scripts, plugins, or external executables.
public actor ComposerNativeDependencyManager {
  private enum MutationPhase: String, Codable {
    case prepared
    case filesWritten
  }

  private struct VendorRecord: Codable {
    let identifier: UUID
    let projectPath: String
    let vendorPath: String
    let backupPath: String
    let installedDigest: String
    let replacedExistingVendor: Bool

    init(_ result: ComposerVendorTransactionResult) {
      identifier = result.identifier
      projectPath = result.projectDirectoryURL.path
      vendorPath = result.vendorDirectoryURL.path
      backupPath = result.backupDirectoryURL.path
      installedDigest = result.installedDigest
      replacedExistingVendor = result.replacedExistingVendor
    }

    var result: ComposerVendorTransactionResult {
      ComposerVendorTransactionResult(
        identifier: identifier,
        projectDirectoryURL: URL(fileURLWithPath: projectPath),
        vendorDirectoryURL: URL(fileURLWithPath: vendorPath),
        backupDirectoryURL: URL(fileURLWithPath: backupPath),
        installedDigest: installedDigest,
        replacedExistingVendor: replacedExistingVendor
      )
    }
  }

  private struct MutationJournal: Codable {
    let identifier: UUID
    let projectPath: String
    let backupPath: String
    let createdAt: Date
    let manifestExisted: Bool
    let lockExisted: Bool
    let installedManifestDigest: String
    let installedLockDigest: String
    let previousVendorTransactionIdentifiers: [UUID]
    var phase: MutationPhase
    var vendor: VendorRecord?
  }

  private let resolver: ComposerDependencyResolver
  private let installer: ComposerNativeInstaller
  private let lockGenerator: ComposerLockGenerator
  private let fileManager: FileManager
  private let stateStorage: ComposerNativeStateStorage
  private let interruptionPoint: ComposerNativeDependencyManagerInterruptionPoint?

  public init(
    source: any ComposerPackageSource,
    platform: ComposerResolutionPlatform = .empty,
    installer: ComposerNativeInstaller,
    lockGenerator: ComposerLockGenerator = ComposerLockGenerator(),
    stateStorage: ComposerNativeStateStorage = .applicationSupport
  ) {
    self.resolver = ComposerDependencyResolver(source: source, platform: platform)
    self.installer = installer
    self.lockGenerator = lockGenerator
    self.fileManager = FileManager()
    self.stateStorage = stateStorage
    self.interruptionPoint = nil
  }

  init(
    source: any ComposerPackageSource,
    platform: ComposerResolutionPlatform = .empty,
    installer: ComposerNativeInstaller,
    lockGenerator: ComposerLockGenerator = ComposerLockGenerator(),
    stateStorage: ComposerNativeStateStorage = .applicationSupport,
    interruptionPoint: ComposerNativeDependencyManagerInterruptionPoint?
  ) {
    self.resolver = ComposerDependencyResolver(source: source, platform: platform)
    self.installer = installer
    self.lockGenerator = lockGenerator
    self.fileManager = FileManager()
    self.stateStorage = stateStorage
    self.interruptionPoint = interruptionPoint
  }

  public func perform(
    _ operation: ComposerNativeDependencyOperation,
    in projectDirectoryURL: URL,
    dryRun: Bool = false,
    progress: (@Sendable (ComposerNativeDependencyEvent) async -> Void)? = nil
  ) async throws -> ComposerNativeDependencyResult {
    let projectURL = projectDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
    try validateProject(projectURL)
    await progress?(.recovering)
    _ = try await recoverInterruptedMutation(in: projectURL)
    try Task.checkCancellation()

    let manifestURL = projectURL.appendingPathComponent("composer.json")
    let lockURL = projectURL.appendingPathComponent("composer.lock")
    let originalManifestData = try Data(contentsOf: manifestURL)
    var manifest = try ComposerManifest.decode(from: originalManifestData)
    let originalLock = try existingLockIfRequired(operation, at: lockURL)

    try mutateManifest(&manifest, for: operation)
    await progress?(.resolving)
    var resolution = try await resolve(
      manifest: manifest,
      operation: operation,
      existingLock: originalLock,
      progress: progress
    )

    if case .require(let package, nil, let development) = operation {
      guard let selected = resolution.packages.first(where: { $0.package.name == package }) else {
        throw ComposerLockGeneratorError.resolvedPackageMissing(package)
      }
      try manifest.setRequirement(
        package: package,
        constraint: Self.suggestedConstraint(for: selected),
        in: development ? .development : .runtime
      )
      resolution = try await resolver.resolve(
        manifest: manifest,
        includeDevelopmentRequirements: true,
        progress: { event in
          await progress?(Self.dependencyEvent(for: event))
        }
      )
    }

    let manifestData = try manifest.encoded(prettyPrinted: true)
    let lockFile = try lockGenerator.generate(
      manifest: manifest,
      manifestData: manifestData,
      resolution: resolution
    )
    let lockData = try lockFile.encoded()
    if dryRun {
      await progress?(.completed)
      return ComposerNativeDependencyResult(
        manifest: manifest,
        lockFile: lockFile,
        installResult: nil,
        mutation: nil,
        isDryRun: true
      )
    }

    try Task.checkCancellation()
    let journalURL = try activeJournalURL(in: projectURL)
    let journal = try await beginMutation(
      projectURL: projectURL,
      manifestData: manifestData,
      lockData: lockData
    )
    var filesWereWritten = false
    do {
      await progress?(.writingProjectFiles)
      try manifestData.write(to: manifestURL, options: .atomic)
      try lockData.write(to: lockURL, options: .atomic)
      filesWereWritten = true
      var writtenJournal = journal
      writtenJournal.phase = .filesWritten
      try write(writtenJournal, to: journalURL)
      if interruptionPoint == .afterProjectFilesWritten {
        throw ComposerNativeDependencyManagerTestError.simulatedInterruption
      }
      try Task.checkCancellation()

      let installResult = try await installer.install(projectDirectoryURL: projectURL) { event in
        await progress?(.installing(event))
      }
      if interruptionPoint == .afterVendorInstalled {
        throw ComposerNativeDependencyManagerTestError.simulatedInterruption
      }
      writtenJournal.vendor = VendorRecord(installResult.transaction)
      let mutation = try completeMutation(writtenJournal, activeJournalURL: journalURL)
      await progress?(.completed)
      return ComposerNativeDependencyResult(
        manifest: manifest,
        lockFile: lockFile,
        installResult: installResult,
        mutation: mutation,
        isDryRun: false
      )
    } catch ComposerNativeDependencyManagerTestError.simulatedInterruption {
      throw ComposerNativeDependencyManagerTestError.simulatedInterruption
    } catch {
      if filesWereWritten {
        try? restoreProjectFiles(from: journal)
      }
      try? fileManager.removeItem(at: journalURL)
      try? fileManager.removeItem(at: URL(fileURLWithPath: journal.backupPath))
      throw error
    }
  }

  public func rollback(_ mutation: ComposerNativeMutationResult) async throws {
    let projectURL = mutation.projectDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
    let manifestURL = projectURL.appendingPathComponent("composer.json")
    let lockURL = projectURL.appendingPathComponent("composer.lock")
    guard try digestOfFile(at: manifestURL) == mutation.installedManifestDigest,
      try digestOfFile(at: lockURL) == mutation.installedLockDigest
    else {
      throw ComposerNativeDependencyError.rollbackConflict(projectURL)
    }
    let recordURL = mutation.backupDirectoryURL.appendingPathComponent("mutation.json")
    let journal = try readJournal(at: recordURL)
    guard journal.identifier == mutation.identifier else {
      throw ComposerNativeDependencyError.invalidMutationJournal(recordURL)
    }

    try await installer.rollback(mutation.vendorTransaction)
    do {
      try restoreProjectFiles(from: journal)
      try fileManager.removeItem(at: mutation.backupDirectoryURL)
    } catch {
      throw error
    }
  }

  public func completedMutations(
    in projectDirectoryURL: URL
  ) throws -> [ComposerNativeMutationResult] {
    let projectURL = projectDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
    let root = try projectBackupsURL(in: projectURL)
    guard fileManager.fileExists(atPath: root.path) else {
      return []
    }
    let directories = try fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    )
    var results: [(Date, ComposerNativeMutationResult)] = []
    for directory in directories {
      let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        continue
      }
      let journal = try readJournal(at: directory.appendingPathComponent("mutation.json"))
      guard journal.projectPath == projectURL.path,
        journal.identifier.uuidString == directory.lastPathComponent,
        journal.vendor != nil
      else {
        throw ComposerNativeDependencyError.invalidMutationJournal(directory)
      }
      results.append((journal.createdAt, result(from: journal)))
    }
    return results.sorted { $0.0 > $1.0 }.map(\.1)
  }

  @discardableResult
  public func recoverInterruptedMutation(
    in projectDirectoryURL: URL
  ) async throws -> ComposerNativeMutationResult? {
    let projectURL = projectDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
    let journalURL = try activeJournalURL(in: projectURL)
    guard fileManager.fileExists(atPath: journalURL.path) else {
      return nil
    }
    var journal = try readJournal(at: journalURL)
    guard journal.projectPath == projectURL.path else {
      throw ComposerNativeDependencyError.invalidMutationJournal(journalURL)
    }
    if journal.phase == .prepared {
      try fileManager.removeItem(at: journalURL)
      try? fileManager.removeItem(at: URL(fileURLWithPath: journal.backupPath))
      return nil
    }

    let recovery = try await installer.recoverInterruptedTransaction(in: projectURL)
    if case .completedInstallation(let transaction) = recovery {
      journal.vendor = VendorRecord(transaction)
      return try completeMutation(journal, activeJournalURL: journalURL)
    }
    if recovery == nil {
      let previous = Set(journal.previousVendorTransactionIdentifiers)
      if let transaction = try await installer.completedTransactions(in: projectURL)
        .first(where: { !previous.contains($0.identifier) })
      {
        journal.vendor = VendorRecord(transaction)
        return try completeMutation(journal, activeJournalURL: journalURL)
      }
    }

    try restoreProjectFiles(from: journal)
    try fileManager.removeItem(at: journalURL)
    try? fileManager.removeItem(at: URL(fileURLWithPath: journal.backupPath))
    return nil
  }

  private func resolve(
    manifest: ComposerManifest,
    operation: ComposerNativeDependencyOperation,
    existingLock: ComposerLockFile?,
    progress: (@Sendable (ComposerNativeDependencyEvent) async -> Void)?
  ) async throws -> ComposerResolutionResult {
    guard case .updateSelected(let packages, let withDependencies) = operation,
      let existingLock
    else {
      return try await resolver.resolve(
        manifest: manifest,
        includeDevelopmentRequirements: true,
        progress: { event in
          await progress?(Self.dependencyEvent(for: event))
        }
      )
    }

    let selected = Set(packages)
    let lockedPackages = try existingLock.packages() + existingLock.packages(in: .development)
    let lockedByName = Dictionary(uniqueKeysWithValues: lockedPackages.map { ($0.name, $0) })
    for package in selected where lockedByName[package] == nil {
      throw ComposerNativeDependencyError.packageNotLocked(package)
    }
    let unlocked =
      withDependencies
      ? try dependencyClosure(startingAt: selected, lockedByName: lockedByName)
      : selected
    var resolutionManifest = manifest
    let runtimeRequirements = try manifest.requirements()
    let developmentRequirements = try manifest.requirements(in: .development)
    for package in lockedPackages where !unlocked.contains(package.name) {
      if let constraint = runtimeRequirements[package.name] {
        try resolutionManifest.setRequirement(
          package: package.name,
          constraint: constraint + " =" + package.version
        )
      } else if let constraint = developmentRequirements[package.name] {
        try resolutionManifest.setRequirement(
          package: package.name,
          constraint: constraint + " =" + package.version,
          in: .development
        )
      } else {
        try resolutionManifest.setRequirement(
          package: package.name,
          constraint: "=" + package.version
        )
      }
    }
    return try await resolver.resolve(
      manifest: resolutionManifest,
      includeDevelopmentRequirements: true,
      progress: { event in
        await progress?(Self.dependencyEvent(for: event))
      }
    )
  }

  private static func dependencyEvent(
    for event: ComposerResolutionEvent
  ) -> ComposerNativeDependencyEvent {
    switch event {
    case .evaluatingPackage(let name, let candidateCount):
      return .resolvingPackage(name: name, candidateCount: candidateCount)
    case .tryingVersion(let package, let version):
      return .tryingVersion(package: package, version: version)
    case .backtracking(let package, let version):
      return .backtracking(package: package, version: version)
    }
  }

  private func mutateManifest(
    _ manifest: inout ComposerManifest,
    for operation: ComposerNativeDependencyOperation
  ) throws {
    switch operation {
    case .updateAll, .updateSelected:
      return
    case .require(let package, let constraint, let development):
      try validatePackageName(package)
      try manifest.setRequirement(
        package: package,
        constraint: constraint ?? "*",
        in: development ? .development : .runtime
      )
    case .remove(let package):
      try validatePackageName(package)
      let runtime = try manifest.requirements()
      let development = try manifest.requirements(in: .development)
      guard runtime[package] != nil || development[package] != nil else {
        throw ComposerNativeDependencyError.packageNotRequired(package)
      }
      try manifest.setRequirement(package: package, constraint: nil, in: .runtime)
      try manifest.setRequirement(package: package, constraint: nil, in: .development)
    }
  }

  private func existingLockIfRequired(
    _ operation: ComposerNativeDependencyOperation,
    at lockURL: URL
  ) throws -> ComposerLockFile? {
    let exists = fileManager.fileExists(atPath: lockURL.path)
    if case .updateSelected = operation, !exists {
      throw ComposerNativeDependencyError.composerLockMissing(lockURL)
    }
    return exists ? try ComposerLockFile.decode(from: Data(contentsOf: lockURL)) : nil
  }

  private func dependencyClosure(
    startingAt roots: Set<String>,
    lockedByName: [String: ComposerLockedPackage]
  ) throws -> Set<String> {
    var result = Set<String>()
    var pending = roots.sorted()
    while let package = pending.first {
      pending.removeFirst()
      guard result.insert(package).inserted, let locked = lockedByName[package] else {
        continue
      }
      pending.append(
        contentsOf: try locked.requirements().keys.filter {
          !ComposerPlatformPackage.isPlatformName($0)
        }.sorted()
      )
    }
    return result
  }

  private func beginMutation(
    projectURL: URL,
    manifestData: Data,
    lockData: Data
  ) async throws -> MutationJournal {
    let stateURL = try stateDirectoryURL(in: projectURL)
    try fileManager.createDirectory(at: stateURL, withIntermediateDirectories: true)
    let journalURL = stateURL.appendingPathComponent("active-project-mutation.json")
    guard !fileManager.fileExists(atPath: journalURL.path) else {
      throw ComposerNativeDependencyError.interruptedMutationExists(journalURL)
    }
    let identifier = UUID()
    let backupURL = stateURL
      .appendingPathComponent("project-backups", isDirectory: true)
      .appendingPathComponent(identifier.uuidString, isDirectory: true)
    try fileManager.createDirectory(at: backupURL, withIntermediateDirectories: true)
    let manifestURL = projectURL.appendingPathComponent("composer.json")
    let lockURL = projectURL.appendingPathComponent("composer.lock")
    let manifestExisted = fileManager.fileExists(atPath: manifestURL.path)
    let lockExisted = fileManager.fileExists(atPath: lockURL.path)
    if manifestExisted {
      try fileManager.copyItem(
        at: manifestURL,
        to: backupURL.appendingPathComponent("composer.json")
      )
    }
    if lockExisted {
      try fileManager.copyItem(at: lockURL, to: backupURL.appendingPathComponent("composer.lock"))
    }
    let previousTransactions = try await installer.completedTransactions(in: projectURL)
      .map(\.identifier)
    let journal = MutationJournal(
      identifier: identifier,
      projectPath: projectURL.path,
      backupPath: backupURL.path,
      createdAt: Date(),
      manifestExisted: manifestExisted,
      lockExisted: lockExisted,
      installedManifestDigest: Self.digest(manifestData),
      installedLockDigest: Self.digest(lockData),
      previousVendorTransactionIdentifiers: previousTransactions,
      phase: .prepared,
      vendor: nil
    )
    try write(journal, to: journalURL)
    return journal
  }

  private func completeMutation(
    _ journal: MutationJournal,
    activeJournalURL: URL
  ) throws -> ComposerNativeMutationResult {
    guard journal.vendor != nil else {
      throw ComposerNativeDependencyError.invalidMutationJournal(activeJournalURL)
    }
    let backupURL = URL(fileURLWithPath: journal.backupPath)
    try write(journal, to: backupURL.appendingPathComponent("mutation.json"))
    try fileManager.removeItem(at: activeJournalURL)
    return result(from: journal)
  }

  private func result(from journal: MutationJournal) -> ComposerNativeMutationResult {
    ComposerNativeMutationResult(
      identifier: journal.identifier,
      projectDirectoryURL: URL(fileURLWithPath: journal.projectPath),
      backupDirectoryURL: URL(fileURLWithPath: journal.backupPath),
      vendorTransaction: journal.vendor!.result,
      installedManifestDigest: journal.installedManifestDigest,
      installedLockDigest: journal.installedLockDigest
    )
  }

  private func restoreProjectFiles(from journal: MutationJournal) throws {
    let projectURL = URL(fileURLWithPath: journal.projectPath)
    let backupURL = URL(fileURLWithPath: journal.backupPath)
    try restoreFile(
      named: "composer.json",
      existed: journal.manifestExisted,
      projectURL: projectURL,
      backupURL: backupURL
    )
    try restoreFile(
      named: "composer.lock",
      existed: journal.lockExisted,
      projectURL: projectURL,
      backupURL: backupURL
    )
  }

  private func restoreFile(
    named name: String,
    existed: Bool,
    projectURL: URL,
    backupURL: URL
  ) throws {
    let destination = projectURL.appendingPathComponent(name)
    let backup = backupURL.appendingPathComponent(name)
    if fileManager.fileExists(atPath: destination.path) {
      try fileManager.removeItem(at: destination)
    }
    if existed {
      try fileManager.copyItem(at: backup, to: destination)
    }
  }

  private func validateProject(_ url: URL) throws {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
    else {
      throw ComposerNativeDependencyError.projectDirectoryMissing(url)
    }
    let manifestURL = url.appendingPathComponent("composer.json")
    guard fileManager.fileExists(atPath: manifestURL.path) else {
      throw ComposerNativeDependencyError.composerManifestMissing(manifestURL)
    }
  }

  private func validatePackageName(_ package: String) throws {
    guard ComposerPackageName.isValid(package), package == package.lowercased() else {
      throw ComposerNativeDependencyError.invalidPackageName(package)
    }
  }

  private func stateDirectoryURL(in projectURL: URL) throws -> URL {
    try stateStorage.stateDirectory(for: projectURL, fileManager: fileManager)
  }

  private func activeJournalURL(in projectURL: URL) throws -> URL {
    try stateDirectoryURL(in: projectURL)
      .appendingPathComponent("active-project-mutation.json")
  }

  private func projectBackupsURL(in projectURL: URL) throws -> URL {
    try stateDirectoryURL(in: projectURL).appendingPathComponent(
      "project-backups",
      isDirectory: true
    )
  }

  private func write(_ journal: MutationJournal, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(journal).write(to: url, options: .atomic)
  }

  private func readJournal(at url: URL) throws -> MutationJournal {
    do {
      return try JSONDecoder().decode(MutationJournal.self, from: Data(contentsOf: url))
    } catch {
      throw ComposerNativeDependencyError.invalidMutationJournal(url)
    }
  }

  private func digestOfFile(at url: URL) throws -> String {
    guard fileManager.fileExists(atPath: url.path) else {
      throw ComposerNativeDependencyError.rollbackConflict(url)
    }
    return Self.digest(try Data(contentsOf: url))
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func suggestedConstraint(for package: ComposerResolvedPackage) -> String {
    let version = package.parsedVersion
    if package.package.version.lowercased().hasPrefix("dev-") {
      return package.package.version
    }
    if version.major > 0 {
      return "^\(version.major).\(version.minor)"
    }
    if version.minor > 0 {
      return "^0.\(version.minor)"
    }
    return "^0.0.\(version.patch)"
  }
}
