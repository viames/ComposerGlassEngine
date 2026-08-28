import Foundation

public enum ComposerNativeMaintenanceError: Error, Equatable, Sendable {
  case projectDirectoryMissing(URL)
  case composerManifestMissing(URL)
  case vendorDirectoryMissing(URL)
  case symbolicLink(URL)
}

public enum ComposerNativeMaintenanceEvent: Equatable, Sendable {
  case preparingVendor
  case generatingAutoload
  case generatingBinaries
  case activatingVendor
  case completed
}

public struct ComposerNativeMaintenanceResult: Equatable, Sendable {
  public let transaction: ComposerVendorTransactionResult
  public let autoload: ComposerAutoloadGenerationResult
  public let binaries: [ComposerGeneratedBinary]

  public init(
    transaction: ComposerVendorTransactionResult,
    autoload: ComposerAutoloadGenerationResult,
    binaries: [ComposerGeneratedBinary]
  ) {
    self.transaction = transaction
    self.autoload = autoload
    self.binaries = binaries
  }
}

/// Rebuilds generated vendor metadata on a private copy and activates it with
/// the same crash-recoverable transaction used by native installation.
public actor ComposerNativeMaintenance {
  private let transaction = ComposerVendorTransaction()
  private let autoloadGenerator = ComposerAutoloadGenerator()
  private let binaryGenerator = ComposerBinaryGenerator()
  private let fileManager = FileManager()

  public init() {}

  public func dumpAutoload(
    projectDirectoryURL: URL,
    includeDevelopmentAutoload: Bool = true,
    progress: (@Sendable (ComposerNativeMaintenanceEvent) async -> Void)? = nil
  ) async throws -> ComposerNativeMaintenanceResult {
    let projectURL = projectDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
    let manifestURL = projectURL.appendingPathComponent("composer.json")
    let vendorURL = projectURL.appendingPathComponent("vendor", isDirectory: true)
    try validateDirectory(
      projectURL,
      missing: .projectDirectoryMissing(projectURL)
    )
    guard fileManager.fileExists(atPath: manifestURL.path) else {
      throw ComposerNativeMaintenanceError.composerManifestMissing(manifestURL)
    }
    try validateDirectory(vendorURL, missing: .vendorDirectoryMissing(vendorURL))
    try rejectSymbolicLinks(in: vendorURL)
    _ = try await transaction.recoverInterruptedTransaction(in: projectURL)
    try Task.checkCancellation()

    let stagingRoot =
      projectURL
      .appendingPathComponent(".composerglass-engine", isDirectory: true)
      .appendingPathComponent("staging", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let stagedVendor = stagingRoot.appendingPathComponent("vendor", isDirectory: true)
    try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    var activated = false
    defer {
      if !activated {
        try? fileManager.removeItem(at: stagingRoot)
      }
    }

    await progress?(.preparingVendor)
    try fileManager.copyItem(at: vendorURL, to: stagedVendor)
    try Task.checkCancellation()
    let manifest = try ComposerManifest.decode(from: Data(contentsOf: manifestURL))
    await progress?(.generatingAutoload)
    let autoload = try autoloadGenerator.generate(
      rootManifest: manifest,
      projectDirectoryURL: projectURL,
      vendorDirectoryURL: stagedVendor,
      includeDevelopmentAutoload: includeDevelopmentAutoload
    )
    try Task.checkCancellation()
    await progress?(.generatingBinaries)
    let binaries = try binaryGenerator.generate(in: stagedVendor)
    try Task.checkCancellation()
    await progress?(.activatingVendor)
    let transactionResult = try await transaction.install(
      preparedVendorURL: stagedVendor,
      in: projectURL
    )
    activated = true
    try? fileManager.removeItem(at: stagingRoot)
    await progress?(.completed)
    return ComposerNativeMaintenanceResult(
      transaction: transactionResult,
      autoload: autoload,
      binaries: binaries
    )
  }

  public func rollback(_ result: ComposerNativeMaintenanceResult) async throws {
    try await transaction.rollback(result.transaction)
  }

  private func validateDirectory(
    _ url: URL,
    missing error: ComposerNativeMaintenanceError
  ) throws {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
    else {
      throw error
    }
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
    if values.isSymbolicLink == true {
      throw ComposerNativeMaintenanceError.symbolicLink(url)
    }
  }

  private func rejectSymbolicLinks(in rootURL: URL) throws {
    guard
      let enumerator = fileManager.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isSymbolicLinkKey],
        options: []
      )
    else {
      return
    }
    for case let url as URL in enumerator {
      if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
        throw ComposerNativeMaintenanceError.symbolicLink(url)
      }
    }
  }
}
