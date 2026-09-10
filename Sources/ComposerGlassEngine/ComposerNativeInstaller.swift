import Foundation

public enum ComposerNativeInstallError: Error, Equatable, Sendable {
  case projectDirectoryMissing(URL)
  case composerManifestMissing(URL)
  case composerLockMissing(URL)
  case staleLockFile
}

public struct ComposerNativeInstallOptions: Equatable, Sendable {
  public let includeDevelopmentPackages: Bool
  public let requireFreshLockFile: Bool

  public init(
    includeDevelopmentPackages: Bool = true,
    requireFreshLockFile: Bool = true
  ) {
    self.includeDevelopmentPackages = includeDevelopmentPackages
    self.requireFreshLockFile = requireFreshLockFile
  }
}

public enum ComposerNativeInstallEvent: Equatable, Sendable {
  case recovering
  case validating
  case downloading(package: String, completed: Int, total: Int)
  case installing(package: String, completed: Int, total: Int)
  case generatingAutoload
  case generatingBinaries
  case activatingVendor
  case completed
}

public struct ComposerNativeInstallResult: Equatable, Sendable {
  public let transaction: ComposerVendorTransactionResult
  public let installedPackages: [ComposerMaterializedPackage]
  public let generatedAutoload: ComposerAutoloadGenerationResult
  public let generatedBinaries: [ComposerGeneratedBinary]
  public let skippedScriptNames: [String]
  public let skippedPluginNames: [String]

  public init(
    transaction: ComposerVendorTransactionResult,
    installedPackages: [ComposerMaterializedPackage],
    generatedAutoload: ComposerAutoloadGenerationResult,
    generatedBinaries: [ComposerGeneratedBinary],
    skippedScriptNames: [String],
    skippedPluginNames: [String] = []
  ) {
    self.transaction = transaction
    self.installedPackages = installedPackages
    self.generatedAutoload = generatedAutoload
    self.generatedBinaries = generatedBinaries
    self.skippedScriptNames = skippedScriptNames
    self.skippedPluginNames = skippedPluginNames
  }
}

/// Coordinates the safe App Store profile for `composer install` from an
/// existing lock file. Scripts, plugins, shells, and package code are never
/// executed.
public actor ComposerNativeInstaller {
  private let materializer: ComposerPackageMaterializer
  private let transaction: ComposerVendorTransaction
  private let autoloadGenerator: ComposerAutoloadGenerator
  private let binaryGenerator: ComposerBinaryGenerator
  private let fileManager: FileManager
  private let stateStorage: ComposerNativeStateStorage

  public init(
    cacheDirectoryURL: URL,
    stateStorage: ComposerNativeStateStorage = .applicationSupport
  ) throws {
    self.materializer = ComposerPackageMaterializer(
      downloader: try ComposerPackageDownloader(cacheDirectory: cacheDirectoryURL)
    )
    self.transaction = ComposerVendorTransaction(stateStorage: stateStorage)
    self.autoloadGenerator = ComposerAutoloadGenerator()
    self.binaryGenerator = ComposerBinaryGenerator()
    self.fileManager = FileManager()
    self.stateStorage = stateStorage
  }

  public init(
    downloader: ComposerPackageDownloader,
    stateStorage: ComposerNativeStateStorage = .applicationSupport
  ) {
    self.materializer = ComposerPackageMaterializer(downloader: downloader)
    self.transaction = ComposerVendorTransaction(stateStorage: stateStorage)
    self.autoloadGenerator = ComposerAutoloadGenerator()
    self.binaryGenerator = ComposerBinaryGenerator()
    self.fileManager = FileManager()
    self.stateStorage = stateStorage
  }

  public func install(
    projectDirectoryURL: URL,
    options: ComposerNativeInstallOptions = ComposerNativeInstallOptions(),
    progress: (@Sendable (ComposerNativeInstallEvent) async -> Void)? = nil
  ) async throws -> ComposerNativeInstallResult {
    let projectURL = projectDirectoryURL.standardizedFileURL
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: projectURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw ComposerNativeInstallError.projectDirectoryMissing(projectURL)
    }

    await progress?(.recovering)
    _ = try await transaction.recoverInterruptedTransaction(in: projectURL)
    try Task.checkCancellation()
    await progress?(.validating)

    let manifestURL = projectURL.appendingPathComponent("composer.json")
    let lockURL = projectURL.appendingPathComponent("composer.lock")
    guard fileManager.fileExists(atPath: manifestURL.path) else {
      throw ComposerNativeInstallError.composerManifestMissing(manifestURL)
    }
    guard fileManager.fileExists(atPath: lockURL.path) else {
      throw ComposerNativeInstallError.composerLockMissing(lockURL)
    }
    let manifestData = try Data(contentsOf: manifestURL)
    let manifest = try ComposerManifest.decode(from: manifestData)
    let lockFile = try ComposerLockFile.decode(from: Data(contentsOf: lockURL))
    if options.requireFreshLockFile, try !lockFile.isFresh(for: manifestData) {
      throw ComposerNativeInstallError.staleLockFile
    }
    let stateURL = try stateStorage.stateDirectory(
      for: projectURL,
      fileManager: fileManager
    )
    let stagingRootURL =
      stateURL
      .appendingPathComponent("staging", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let stagedVendorURL = stagingRootURL.appendingPathComponent("vendor", isDirectory: true)
    try fileManager.createDirectory(
      at: stagingRootURL,
      withIntermediateDirectories: true
    )
    var activated = false
    defer {
      if !activated {
        try? fileManager.removeItem(at: stagingRootURL)
      }
    }

    let materialized = try await materializer.materialize(
      lockFile,
      includeDevelopmentPackages: options.includeDevelopmentPackages,
      at: stagedVendorURL,
      reusingPackagesFrom: projectURL.appendingPathComponent("vendor", isDirectory: true)
    ) { event in
      switch event {
      case .downloading(let package, let completed, let total):
        await progress?(.downloading(package: package, completed: completed, total: total))
      case .installed(let package, let completed, let total):
        await progress?(.installing(package: package, completed: completed, total: total))
      }
    }
    try Task.checkCancellation()

    await progress?(.generatingAutoload)
    let autoload = try autoloadGenerator.generate(
      rootManifest: manifest,
      projectDirectoryURL: projectURL,
      vendorDirectoryURL: stagedVendorURL,
      includeDevelopmentAutoload: options.includeDevelopmentPackages
    )
    try Task.checkCancellation()

    await progress?(.generatingBinaries)
    let binaries = try binaryGenerator.generate(in: stagedVendorURL)
    try Task.checkCancellation()

    await progress?(.activatingVendor)
    let transactionResult = try await transaction.install(
      preparedVendorURL: stagedVendorURL,
      in: projectURL
    )
    activated = true
    try? fileManager.removeItem(at: stagingRootURL)
    await progress?(.completed)
    return ComposerNativeInstallResult(
      transaction: transactionResult,
      installedPackages: materialized.packages,
      generatedAutoload: autoload,
      generatedBinaries: binaries,
      skippedScriptNames: Self.scriptNames(in: manifest),
      skippedPluginNames: try Self.pluginNames(
        lockFile,
        includeDevelopmentPackages: options.includeDevelopmentPackages
      )
    )
  }

  public func rollback(_ result: ComposerNativeInstallResult) async throws {
    try await transaction.rollback(result.transaction)
  }

  public func rollback(_ transactionResult: ComposerVendorTransactionResult) async throws {
    try await transaction.rollback(transactionResult)
  }

  public func completedTransactions(
    in projectDirectoryURL: URL
  ) async throws -> [ComposerVendorTransactionResult] {
    try await transaction.completedTransactions(in: projectDirectoryURL)
  }

  public func recoverInterruptedTransaction(
    in projectDirectoryURL: URL
  ) async throws -> ComposerVendorRecoveryResult? {
    try await transaction.recoverInterruptedTransaction(in: projectDirectoryURL)
  }

  private static func pluginNames(
    _ lockFile: ComposerLockFile,
    includeDevelopmentPackages: Bool
  ) throws -> [String] {
    var packages = try lockFile.packages()
    if includeDevelopmentPackages {
      packages += try lockFile.packages(in: .development)
    }
    return packages
      .filter { $0.packageType?.lowercased() == "composer-plugin" }
      .map(\.name)
      .sorted()
  }

  private static func scriptNames(in manifest: ComposerManifest) -> [String] {
    guard case .object(let scripts)? = manifest["scripts"] else {
      return []
    }
    return scripts.keys.sorted()
  }
}
