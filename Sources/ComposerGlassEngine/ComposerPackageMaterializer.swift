import CryptoKit
import Darwin
import Foundation

public enum ComposerPackageMaterializationError: Error, Equatable, Sendable {
  case destinationAlreadyExists(URL)
  case duplicatePackage(String)
}

public enum ComposerPackageMaterializationProgress: Equatable, Sendable {
  case downloading(package: String, completed: Int, total: Int)
  case installed(package: String, completed: Int, total: Int)
}

public struct ComposerMaterializedPackage: Equatable, Sendable {
  public let packageName: String
  public let version: String
  public let installURL: URL
  public let archiveSHA256: String
  public let isDevelopment: Bool
  public let wasReused: Bool

  public init(
    packageName: String,
    version: String,
    installURL: URL,
    archiveSHA256: String,
    isDevelopment: Bool = false,
    wasReused: Bool = false
  ) {
    self.packageName = packageName
    self.version = version
    self.installURL = installURL
    self.archiveSHA256 = archiveSHA256
    self.isDevelopment = isDevelopment
    self.wasReused = wasReused
  }
}

public struct ComposerMaterializationResult: Equatable, Sendable {
  public let vendorDirectoryURL: URL
  public let packages: [ComposerMaterializedPackage]

  public init(
    vendorDirectoryURL: URL,
    packages: [ComposerMaterializedPackage]
  ) {
    self.vendorDirectoryURL = vendorDirectoryURL
    self.packages = packages
  }
}

/// Builds a complete new vendor tree from resolved packages. The destination
/// must not exist and is removed in full if any package fails.
public actor ComposerPackageMaterializer {

  private struct PlannedPackage: Sendable {
    let package: ComposerRepositoryPackage
    let isDevelopment: Bool
  }

  private struct PreparedPackage: Sendable {
    let index: Int
    let planned: PlannedPackage
    let extractionURL: URL
    let contentRootURL: URL
    let archiveSHA256: String
    let treeSHA256: String
    let wasReused: Bool
  }

  private struct ReuseManifest: Codable, Sendable {
    let schemaVersion: Int
    let packages: [ReuseRecord]
  }

  private struct ReuseRecord: Codable, Sendable {
    let packageName: String
    let version: String
    let identitySHA256: String
    let archiveSHA256: String
    let treeSHA256: String
    let isDevelopment: Bool
  }

  private actor ProgressReporter {
    private var completed = 0

    func downloading(
      package: String,
      total: Int,
      progress: (@Sendable (ComposerPackageMaterializationProgress) async -> Void)?
    ) async {
      await progress?(.downloading(package: package, completed: completed, total: total))
    }

    func prepared(
      package: String,
      total: Int,
      progress: (@Sendable (ComposerPackageMaterializationProgress) async -> Void)?
    ) async {
      completed += 1
      await progress?(.installed(package: package, completed: completed, total: total))
    }
  }

  private let downloader: ComposerPackageDownloader
  private let extractor: ComposerZIPExtractor
  private let fileManager: FileManager
  private let maximumConcurrentPackages: Int

  public init(
    downloader: ComposerPackageDownloader,
    extractor: ComposerZIPExtractor = ComposerZIPExtractor(),
    maximumConcurrentPackages: Int = 8
  ) {
    self.downloader = downloader
    self.extractor = extractor
    self.fileManager = FileManager()
    self.maximumConcurrentPackages = max(1, maximumConcurrentPackages)
  }

  public func materialize(
    _ resolution: ComposerResolutionResult,
    at vendorDirectoryURL: URL,
    progress: (@Sendable (ComposerPackageMaterializationProgress) async -> Void)? = nil
  ) async throws -> ComposerMaterializationResult {
    try await materialize(
      packages: resolution.packages.map {
        PlannedPackage(package: $0.package, isDevelopment: false)
      },
      at: vendorDirectoryURL,
      progress: progress
    )
  }

  /// Builds a complete new vendor tree from the exact package versions in a
  /// lock file. Platform packages are not expected in either lock section.
  public func materialize(
    _ lockFile: ComposerLockFile,
    includeDevelopmentPackages: Bool = true,
    at vendorDirectoryURL: URL,
    reusingPackagesFrom existingVendorDirectoryURL: URL? = nil,
    reuseMetadataURL: URL? = nil,
    progress: (@Sendable (ComposerPackageMaterializationProgress) async -> Void)? = nil
  ) async throws -> ComposerMaterializationResult {
    let preserveJSONKeyOrder = !lockFile.wasGeneratedByComposerGlassEngine
    var packages = try lockFile.packages().map {
      PlannedPackage(
        package: try repositoryPackage(
          from: $0,
          preserveJSONKeyOrder: preserveJSONKeyOrder
        ),
        isDevelopment: false
      )
    }
    if includeDevelopmentPackages {
      packages += try lockFile.packages(in: .development).map {
        PlannedPackage(
          package: try repositoryPackage(
            from: $0,
            preserveJSONKeyOrder: preserveJSONKeyOrder
          ),
          isDevelopment: true
        )
      }
    }
    return try await materialize(
      packages: packages,
      at: vendorDirectoryURL,
      reusingPackagesFrom: existingVendorDirectoryURL,
      reuseMetadataURL: reuseMetadataURL,
      developmentMode: includeDevelopmentPackages,
      progress: progress
    )
  }

  private func materialize(
    packages: [PlannedPackage],
    at vendorDirectoryURL: URL,
    reusingPackagesFrom existingVendorDirectoryURL: URL? = nil,
    reuseMetadataURL: URL? = nil,
    developmentMode: Bool = false,
    progress: (@Sendable (ComposerPackageMaterializationProgress) async -> Void)?
  ) async throws -> ComposerMaterializationResult {
    guard !fileManager.fileExists(atPath: vendorDirectoryURL.path) else {
      throw ComposerPackageMaterializationError.destinationAlreadyExists(vendorDirectoryURL)
    }

    let sortedPackages = packages.sorted {
      ($0.package.name, $0.package.version) < ($1.package.name, $1.package.version)
    }
    var names = Set<String>()
    for planned in sortedPackages {
      guard names.insert(planned.package.name).inserted else {
        throw ComposerPackageMaterializationError.duplicatePackage(planned.package.name)
      }
    }

    try fileManager.createDirectory(
      at: vendorDirectoryURL,
      withIntermediateDirectories: false
    )
    var succeeded = false
    defer {
      if !succeeded {
        try? fileManager.removeItem(at: vendorDirectoryURL)
      }
    }

    let extractionDirectory = vendorDirectoryURL.appendingPathComponent(
      ".composerglass-extraction",
      isDirectory: true
    )
    try fileManager.createDirectory(
      at: extractionDirectory,
      withIntermediateDirectories: false
    )
    let reusablePackages = readReuseRecords(from: reuseMetadataURL)
    let progressReporter = ProgressReporter()
    let packagesToPrepare = sortedPackages.enumerated().filter {
      $0.element.package.packageType != "metapackage"
    }
    let preparedPackages = try await prepareConcurrently(
      packagesToPrepare,
      extractionDirectory: extractionDirectory,
      existingVendorDirectoryURL: existingVendorDirectoryURL,
      reusablePackages: reusablePackages,
      total: sortedPackages.count,
      progressReporter: progressReporter,
      progress: progress
    )

    var preparedByIndex = Dictionary(uniqueKeysWithValues: preparedPackages.map {
      ($0.index, $0)
    })
    var materialized: [ComposerMaterializedPackage] = []
    materialized.reserveCapacity(preparedPackages.count)
    var reuseRecords: [ReuseRecord] = []
    reuseRecords.reserveCapacity(preparedPackages.count)

    for (index, planned) in sortedPackages.enumerated() {
      try Task.checkCancellation()
      guard planned.package.packageType != "metapackage" else {
        await progressReporter.prepared(
          package: planned.package.name,
          total: sortedPackages.count,
          progress: progress
        )
        continue
      }
      guard let prepared = preparedByIndex.removeValue(forKey: index) else {
        preconditionFailure("Missing prepared Composer package")
      }
      let installURL = Self.installURL(
        for: planned.package.name,
        in: vendorDirectoryURL
      )
      try fileManager.createDirectory(
        at: installURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      guard !fileManager.fileExists(atPath: installURL.path) else {
        throw ComposerPackageMaterializationError.duplicatePackage(planned.package.name)
      }
      try fileManager.moveItem(at: prepared.contentRootURL, to: installURL)
      if fileManager.fileExists(atPath: prepared.extractionURL.path) {
        try fileManager.removeItem(at: prepared.extractionURL)
      }
      materialized.append(
        ComposerMaterializedPackage(
          packageName: planned.package.name,
          version: planned.package.version,
          installURL: installURL,
          archiveSHA256: prepared.archiveSHA256,
          isDevelopment: planned.isDevelopment,
          wasReused: prepared.wasReused
        )
      )
      reuseRecords.append(
        ReuseRecord(
          packageName: planned.package.name,
          version: planned.package.version,
          identitySHA256: Self.identitySHA256(for: planned.package),
          archiveSHA256: prepared.archiveSHA256,
          treeSHA256: prepared.treeSHA256,
          isDevelopment: planned.isDevelopment
        )
      )
    }

    try fileManager.removeItem(at: extractionDirectory)
    try writeInstalledMetadata(
      packages: sortedPackages,
      developmentMode: developmentMode,
      to: vendorDirectoryURL
    )
    if let reuseMetadataURL {
      try writeReuseManifest(reuseRecords, to: reuseMetadataURL)
    }
    succeeded = true
    return ComposerMaterializationResult(
      vendorDirectoryURL: vendorDirectoryURL,
      packages: materialized
    )
  }

  private func prepareConcurrently(
    _ packages: [(offset: Int, element: PlannedPackage)],
    extractionDirectory: URL,
    existingVendorDirectoryURL: URL?,
    reusablePackages: [String: ReuseRecord],
    total: Int,
    progressReporter: ProgressReporter,
    progress: (@Sendable (ComposerPackageMaterializationProgress) async -> Void)?
  ) async throws -> [PreparedPackage] {
    guard !packages.isEmpty else {
      return []
    }
    let downloader = downloader
    let extractor = extractor
    let concurrency = min(maximumConcurrentPackages, max(1, packages.count))
    return try await withThrowingTaskGroup(of: PreparedPackage.self) { group in
      var nextIndex = 0
      var results: [PreparedPackage] = []
      results.reserveCapacity(packages.count)

      while nextIndex < concurrency {
        let input = packages[nextIndex]
        group.addTask {
          try await Self.prepare(
            input,
            extractionDirectory: extractionDirectory,
            existingVendorDirectoryURL: existingVendorDirectoryURL,
            reuseRecord: reusablePackages[input.element.package.name],
            downloader: downloader,
            extractor: extractor,
            total: total,
            progressReporter: progressReporter,
            progress: progress
          )
        }
        nextIndex += 1
      }

      while let result = try await group.next() {
        results.append(result)
        if nextIndex < packages.count {
          let input = packages[nextIndex]
          group.addTask {
            try await Self.prepare(
              input,
              extractionDirectory: extractionDirectory,
              existingVendorDirectoryURL: existingVendorDirectoryURL,
              reuseRecord: reusablePackages[input.element.package.name],
              downloader: downloader,
              extractor: extractor,
              total: total,
              progressReporter: progressReporter,
              progress: progress
            )
          }
          nextIndex += 1
        }
      }
      return results.sorted { $0.index < $1.index }
    }
  }

  private static func prepare(
    _ input: (offset: Int, element: PlannedPackage),
    extractionDirectory: URL,
    existingVendorDirectoryURL: URL?,
    reuseRecord: ReuseRecord?,
    downloader: ComposerPackageDownloader,
    extractor: ComposerZIPExtractor,
    total: Int,
    progressReporter: ProgressReporter,
    progress: (@Sendable (ComposerPackageMaterializationProgress) async -> Void)?
  ) async throws -> PreparedPackage {
    let index = input.offset
    let planned = input.element
    let packageExtractionURL = extractionDirectory.appendingPathComponent(
      String(index),
      isDirectory: true
    )
    if let existingVendorDirectoryURL,
      let reuseRecord,
      reuseRecord.version == planned.package.version,
      reuseRecord.identitySHA256 == identitySHA256(for: planned.package),
      reuseRecord.isDevelopment == planned.isDevelopment
    {
      let sourceURL = installURL(
        for: planned.package.name,
        in: existingVendorDirectoryURL
      )
      do {
        let digest = try await treeDigest(at: sourceURL)
        if digest == reuseRecord.treeSHA256 {
          try Task.checkCancellation()
          try await cloneDirectory(from: sourceURL, to: packageExtractionURL)
          await progressReporter.prepared(
            package: planned.package.name,
            total: total,
            progress: progress
          )
          return PreparedPackage(
            index: index,
            planned: planned,
            extractionURL: packageExtractionURL,
            contentRootURL: packageExtractionURL,
            archiveSHA256: reuseRecord.archiveSHA256,
            treeSHA256: digest,
            wasReused: true
          )
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // A missing, changed, or unsafe source package is rebuilt from its archive.
      }
    }

    await progressReporter.downloading(
      package: planned.package.name,
      total: total,
      progress: progress
    )
    let archive = try await downloader.archive(for: planned.package)
    try Task.checkCancellation()
    let extracted = try await extractor.extract(
      archive: archive.fileURL,
      to: packageExtractionURL
    )
    try Task.checkCancellation()
    let digest = try await treeDigest(at: extracted.contentRootURL)
    await progressReporter.prepared(
      package: planned.package.name,
      total: total,
      progress: progress
    )
    return PreparedPackage(
      index: index,
      planned: planned,
      extractionURL: packageExtractionURL,
      contentRootURL: extracted.contentRootURL,
      archiveSHA256: archive.sha256,
      treeSHA256: digest,
      wasReused: false
    )
  }

  private func readReuseRecords(from manifestURL: URL?) -> [String: ReuseRecord] {
    guard let manifestURL else {
      return [:]
    }
    guard let data = fileManager.contents(atPath: manifestURL.path),
      let manifest = try? JSONDecoder().decode(ReuseManifest.self, from: data),
      manifest.schemaVersion == 1
    else {
      return [:]
    }
    return Dictionary(
      manifest.packages.map { ($0.packageName, $0) },
      uniquingKeysWith: { first, _ in first }
    )
  }

  private func writeReuseManifest(
    _ packages: [ReuseRecord],
    to manifestURL: URL
  ) throws {
    try fileManager.createDirectory(
      at: manifestURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(
      ReuseManifest(schemaVersion: 1, packages: packages)
    ).write(to: manifestURL, options: .atomic)
  }

  private static func identitySHA256(for package: ComposerRepositoryPackage) -> String {
    let identity = [
      package.name,
      package.version,
      package.packageType ?? "",
      package.distType ?? "",
      package.distURL?.absoluteString ?? "",
      package.distReference ?? "",
      package.distChecksum ?? "",
    ].joined(separator: "\u{0}")
    return SHA256.hash(data: Data(identity.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
  }

  private static func installURL(for packageName: String, in vendorURL: URL) -> URL {
    packageName.split(separator: "/").reduce(vendorURL) {
      $0.appendingPathComponent(String($1), isDirectory: true)
    }
  }

  private static func treeDigest(at rootURL: URL) async throws -> String {
    try await Task.detached(priority: .utility) {
      try treeDigestSynchronously(at: rootURL)
    }.value
  }

  private static func treeDigestSynchronously(at rootURL: URL) throws -> String {
    let fileManager = FileManager()
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    if try rootURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
      throw ComposerZIPExtractionError.symbolicLink(rootURL.path)
    }
    guard let enumerator = fileManager.enumerator(
      at: rootURL,
      includingPropertiesForKeys: [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isExecutableKey,
      ],
      options: []
    ) else {
      return SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
    }
    var entries: [URL] = []
    for case let url as URL in enumerator {
      entries.append(url)
    }
    entries.sort { $0.path < $1.path }
    var hasher = SHA256()
    for url in entries {
      if Task.isCancelled {
        throw CancellationError()
      }
      let values = try url.resourceValues(forKeys: [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isExecutableKey,
      ])
      if values.isSymbolicLink == true {
        throw ComposerZIPExtractionError.symbolicLink(url.path)
      }
      let relativePath = String(url.path.dropFirst(rootURL.path.count + 1))
      let kind = values.isDirectory == true ? "d" : "f"
      let executable = values.isExecutable == true ? "x" : "-"
      hasher.update(data: Data("\(kind)\(executable):\(relativePath)\u{0}".utf8))
      if values.isRegularFile == true {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: 64 * 1_024), !data.isEmpty {
          hasher.update(data: data)
        }
      }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func cloneDirectory(from sourceURL: URL, to destinationURL: URL) async throws {
    try await Task.detached(priority: .utility) {
      let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE)
      if copyfile(sourceURL.path, destinationURL.path, nil, flags) == 0 {
        return
      }
      let copyError = errno
      try? FileManager.default.removeItem(at: destinationURL)
      do {
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
      } catch {
        throw POSIXError(POSIXErrorCode(rawValue: copyError) ?? .EIO)
      }
    }.value
  }

  private func writeInstalledMetadata(
    packages: [PlannedPackage],
    developmentMode: Bool,
    to vendorDirectoryURL: URL
  ) throws {
    let composerDirectory = vendorDirectoryURL.appendingPathComponent(
      "composer",
      isDirectory: true
    )
    try fileManager.createDirectory(
      at: composerDirectory,
      withIntermediateDirectories: true
    )
    let installedPackages = packages.map { planned -> JSONValue in
      var fields = planned.package.fields
      fields["install-path"] =
        planned.package.packageType == "metapackage"
        ? .null
        : .string(Self.installedJSONPath(for: planned.package.name))
      fields["installation-source"] = .string("dist")
      return .object(fields)
    }
    var jsonKeyOrders: [String: [String]] = [:]
    for (index, planned) in packages.enumerated() {
      for (path, order) in planned.package.jsonKeyOrders where !path.isEmpty {
        jsonKeyOrders["/packages/\(index)\(path)"] = order
      }
    }
    let developmentNames =
      packages
      .filter(\.isDevelopment)
      .map { JSONValue.string($0.package.name) }
    let document = JSONValue.object([
      "packages": .array(installedPackages),
      "dev": .bool(developmentMode),
      "dev-package-names": .array(developmentNames),
    ])
    let data = Data(
      (try Self.composerJSON(
        document,
        context: "root",
        keyOrders: jsonKeyOrders
      ) + "\n").utf8
    )
    try data.write(
      to: composerDirectory.appendingPathComponent("installed.json"),
      options: .atomic
    )
  }

  private static func composerJSON(
    _ value: JSONValue,
    level: Int = 0,
    context: String,
    keyOrders: [String: [String]] = [:],
    path: String = ""
  ) throws -> String {
    switch value {
    case .null:
      return "null"
    case .bool(let value):
      return value ? "true" : "false"
    case .number(let value):
      let data = try JSONSerialization.data(
        withJSONObject: value,
        options: [.fragmentsAllowed, .withoutEscapingSlashes]
      )
      return String(decoding: data, as: UTF8.self)
    case .string(let value):
      let data = try JSONSerialization.data(
        withJSONObject: value,
        options: [.fragmentsAllowed, .withoutEscapingSlashes]
      )
      return String(decoding: data, as: UTF8.self)
    case .array(let values):
      guard !values.isEmpty else { return "[]" }
      let indentation = String(repeating: " ", count: (level + 1) * 4)
      let closing = String(repeating: " ", count: level * 4)
      let entries = try values.enumerated().map { index, value in
        let itemPath = childJSONPath(path, String(index))
        return indentation + (try composerJSON(
          value,
          level: level + 1,
          context: context,
          keyOrders: keyOrders,
          path: itemPath
        ))
      }.joined(separator: ",\n")
      return "[\n\(entries)\n\(closing)]"
    case .object(let fields):
      guard !fields.isEmpty else { return "{}" }
      let indentation = String(repeating: " ", count: (level + 1) * 4)
      let closing = String(repeating: " ", count: level * 4)
      let entries = try orderedKeys(
        in: fields,
        context: context,
        preservedOrder: keyOrders[path]
      ).map { key in
        let encodedKey = try composerJSON(.string(key), context: "key")
        let childContext = childJSONContext(parent: context, key: key)
        let encodedValue = try composerJSON(
          fields[key]!,
          level: level + 1,
          context: childContext,
          keyOrders: keyOrders,
          path: childJSONPath(path, key)
        )
        return "\(indentation)\(encodedKey): \(encodedValue)"
      }.joined(separator: ",\n")
      return "{\n\(entries)\n\(closing)}"
    }
  }

  private static func orderedKeys(
    in fields: [String: JSONValue],
    context: String,
    preservedOrder: [String]?
  ) -> [String] {
    if let preservedOrder, context != "root", context != "package" {
      let known = preservedOrder.filter { fields[$0] != nil }
      let remaining = fields.keys.filter { !known.contains($0) }.sorted()
      return known + remaining
    }
    let preferred: [String]
    switch context {
    case "root":
      preferred = ["packages", "dev", "dev-package-names"]
    case "package":
      preferred = [
        "name", "version", "version_normalized", "target-dir", "source", "dist",
        "require", "conflict", "provide", "replace", "require-dev", "suggest",
        "time", "default-branch", "bin", "type", "extra", "installation-source",
        "autoload", "autoload-dev", "notification-url", "include-path", "php-ext",
        "archive", "scripts", "license", "authors", "description", "homepage",
        "keywords", "repositories", "support", "funding", "abandoned",
        "minimum-stability", "transport-options", "install-path",
      ]
    case "source", "dist":
      preferred = ["type", "url", "reference", "shasum"]
    case "author":
      preferred = ["name", "email", "homepage", "role"]
    case "autoload":
      preferred = ["psr-4", "psr-0", "classmap", "files", "exclude-from-classmap"]
    case "support":
      preferred = ["issues", "source", "docs", "forum", "wiki", "irc", "email", "rss"]
    case "funding":
      preferred = ["url", "type"]
    default:
      preferred = []
    }
    let ranks = Dictionary(uniqueKeysWithValues: preferred.enumerated().map { ($0.element, $0.offset) })
    return fields.keys.sorted {
      let lhs = ranks[$0] ?? Int.max
      let rhs = ranks[$1] ?? Int.max
      return lhs == rhs ? $0 < $1 : lhs < rhs
    }
  }

  private static func childJSONContext(parent: String, key: String) -> String {
    if parent == "root", key == "packages" { return "package" }
    if key == "authors" { return "author" }
    if key == "funding" { return "funding" }
    if ["source", "dist", "autoload", "support"].contains(key) { return key }
    return key
  }

  private static func childJSONPath(_ parent: String, _ component: String) -> String {
    let escaped = component
      .replacingOccurrences(of: "~", with: "~0")
      .replacingOccurrences(of: "/", with: "~1")
    return parent + "/" + escaped
  }

  private static func installedJSONPath(for packageName: String) -> String {
    if packageName.hasPrefix("composer/") {
      return "./" + String(packageName.dropFirst("composer/".count))
    }
    return "../\(packageName)"
  }

  private func repositoryPackage(
    from lockedPackage: ComposerLockedPackage,
    preserveJSONKeyOrder: Bool = true
  ) throws -> ComposerRepositoryPackage {
    var additionalFields = lockedPackage.fields
    additionalFields.removeValue(forKey: "name")
    additionalFields.removeValue(forKey: "version")
    additionalFields.removeValue(forKey: "version_normalized")
    additionalFields.removeValue(forKey: "require")
    var package = try ComposerRepositoryPackage(
      name: lockedPackage.name,
      version: lockedPackage.version,
      normalizedVersion: lockedPackage["version_normalized"]?.stringValue
        ?? Self.normalizedVersion(lockedPackage.version),
      requirements: try lockedPackage.requirements(),
      additionalFields: additionalFields
    )
    package.jsonKeyOrders = preserveJSONKeyOrder ? lockedPackage.jsonKeyOrders : [:]
    return package
  }

  private static func normalizedVersion(_ version: String) -> String? {
    guard let parsed = try? ComposerVersion(version) else {
      return nil
    }
    var result = "\(parsed.major).\(parsed.minor).\(parsed.patch).\(parsed.build)"
    switch parsed.stability {
    case .development:
      result += "-dev"
    case .alpha:
      result += "-alpha\(parsed.stabilityNumber)"
    case .beta:
      result += "-beta\(parsed.stabilityNumber)"
    case .releaseCandidate:
      result += "-RC\(parsed.stabilityNumber)"
    case .stable:
      break
    }
    return result
  }
}
