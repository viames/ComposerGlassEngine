import CryptoKit
import Foundation

public enum ComposerNativeStateStorageError: Error, Equatable, Sendable {
  case applicationSupportUnavailable
  case unsafeStorageLocation(URL)
  case symbolicLink(URL)
  case migrationConflict(source: URL, destination: URL)
}

/// Stores native Composer transaction state outside managed PHP projects.
///
/// Each project receives a stable, path-derived directory. Existing
/// `.composerglass-engine` data is moved into that directory the first time a
/// project is accessed, preserving interrupted-operation recovery and rollback.
public struct ComposerNativeStateStorage: Equatable, Sendable {
  private let configuredRootDirectoryURL: URL?

  /// The production store in the current user's Application Support directory.
  public static let applicationSupport = ComposerNativeStateStorage(
    configuredRootDirectoryURL: nil
  )

  /// Creates a store rooted at an explicit location, primarily for embedding
  /// applications and deterministic tests.
  public init(rootDirectoryURL: URL) {
    self.configuredRootDirectoryURL = rootDirectoryURL
  }

  private init(configuredRootDirectoryURL: URL?) {
    self.configuredRootDirectoryURL = configuredRootDirectoryURL
  }

  func stateDirectory(
    for projectDirectoryURL: URL,
    fileManager: FileManager = .default
  ) throws -> URL {
    let projectURL = projectDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
    let rootURL = try rootDirectory(fileManager: fileManager)
      .standardizedFileURL
      .resolvingSymlinksInPath()

    guard !Self.isSameOrDescendant(rootURL, of: projectURL),
      !Self.isSameOrDescendant(projectURL, of: rootURL)
    else {
      throw ComposerNativeStateStorageError.unsafeStorageLocation(rootURL)
    }

    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try rejectSymbolicLink(rootURL, fileManager: fileManager)

    let destinationURL = rootURL.appendingPathComponent(
      Self.projectDirectoryName(for: projectURL),
      isDirectory: true
    )
    let legacyURL = projectURL.appendingPathComponent(
      ".composerglass-engine",
      isDirectory: true
    )
    try migrateLegacyState(
      from: legacyURL,
      to: destinationURL,
      fileManager: fileManager
    )

    if fileManager.fileExists(atPath: destinationURL.path) {
      try rejectSymbolicLink(destinationURL, fileManager: fileManager)
    } else {
      try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    }
    return destinationURL
  }

  private func rootDirectory(fileManager: FileManager) throws -> URL {
    if let configuredRootDirectoryURL {
      return configuredRootDirectoryURL
    }
    guard let applicationSupportURL = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else {
      throw ComposerNativeStateStorageError.applicationSupportUnavailable
    }
    return applicationSupportURL
      .appendingPathComponent("ComposerGlass", isDirectory: true)
      .appendingPathComponent("NativeEngine", isDirectory: true)
      .appendingPathComponent("Projects", isDirectory: true)
  }

  private func migrateLegacyState(
    from legacyURL: URL,
    to destinationURL: URL,
    fileManager: FileManager
  ) throws {
    guard fileManager.fileExists(atPath: legacyURL.path) else {
      return
    }
    try rejectSymbolicLink(legacyURL, fileManager: fileManager)

    guard fileManager.fileExists(atPath: destinationURL.path) else {
      try fileManager.moveItem(at: legacyURL, to: destinationURL)
      do {
        try rewriteMigratedJournalPaths(
          in: destinationURL,
          replacing: legacyURL,
          with: destinationURL,
          fileManager: fileManager
        )
      } catch {
        try? fileManager.moveItem(at: destinationURL, to: legacyURL)
        throw error
      }
      return
    }

    try rejectSymbolicLink(destinationURL, fileManager: fileManager)
    try validateMerge(
      sourceURL: legacyURL,
      destinationURL: destinationURL,
      fileManager: fileManager
    )
    try mergeDirectory(
      sourceURL: legacyURL,
      destinationURL: destinationURL,
      fileManager: fileManager
    )
    try rewriteMigratedJournalPaths(
      in: destinationURL,
      replacing: legacyURL,
      with: destinationURL,
      fileManager: fileManager
    )
    if try fileManager.contentsOfDirectory(atPath: legacyURL.path).isEmpty {
      try fileManager.removeItem(at: legacyURL)
    }
  }

  private func validateMerge(
    sourceURL: URL,
    destinationURL: URL,
    fileManager: FileManager
  ) throws {
    let children = try fileManager.contentsOfDirectory(
      at: sourceURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
      options: []
    )
    for sourceChildURL in children {
      let sourceValues = try sourceChildURL.resourceValues(forKeys: [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
      ])
      if sourceValues.isSymbolicLink == true {
        throw ComposerNativeStateStorageError.symbolicLink(sourceChildURL)
      }
      let destinationChildURL = destinationURL.appendingPathComponent(
        sourceChildURL.lastPathComponent,
        isDirectory: sourceValues.isDirectory == true
      )
      guard fileManager.fileExists(atPath: destinationChildURL.path) else {
        continue
      }
      let destinationValues = try destinationChildURL.resourceValues(forKeys: [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
      ])
      if destinationValues.isSymbolicLink == true {
        throw ComposerNativeStateStorageError.symbolicLink(destinationChildURL)
      }
      if sourceValues.isDirectory == true, destinationValues.isDirectory == true {
        try validateMerge(
          sourceURL: sourceChildURL,
          destinationURL: destinationChildURL,
          fileManager: fileManager
        )
        continue
      }
      guard sourceValues.isRegularFile == true, destinationValues.isRegularFile == true,
        try Data(contentsOf: sourceChildURL) == Data(contentsOf: destinationChildURL)
      else {
        throw ComposerNativeStateStorageError.migrationConflict(
          source: sourceChildURL,
          destination: destinationChildURL
        )
      }
    }
  }

  private func mergeDirectory(
    sourceURL: URL,
    destinationURL: URL,
    fileManager: FileManager
  ) throws {
    let children = try fileManager.contentsOfDirectory(
      at: sourceURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
      options: []
    )
    for sourceChildURL in children {
      let sourceValues = try sourceChildURL.resourceValues(forKeys: [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
      ])
      if sourceValues.isSymbolicLink == true {
        throw ComposerNativeStateStorageError.symbolicLink(sourceChildURL)
      }
      let destinationChildURL = destinationURL.appendingPathComponent(
        sourceChildURL.lastPathComponent,
        isDirectory: sourceValues.isDirectory == true
      )
      guard fileManager.fileExists(atPath: destinationChildURL.path) else {
        try fileManager.moveItem(at: sourceChildURL, to: destinationChildURL)
        continue
      }

      let destinationValues = try destinationChildURL.resourceValues(forKeys: [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
      ])
      if destinationValues.isSymbolicLink == true {
        throw ComposerNativeStateStorageError.symbolicLink(destinationChildURL)
      }
      if sourceValues.isDirectory == true, destinationValues.isDirectory == true {
        try mergeDirectory(
          sourceURL: sourceChildURL,
          destinationURL: destinationChildURL,
          fileManager: fileManager
        )
        if try fileManager.contentsOfDirectory(atPath: sourceChildURL.path).isEmpty {
          try fileManager.removeItem(at: sourceChildURL)
        }
        continue
      }
      if sourceValues.isRegularFile == true, destinationValues.isRegularFile == true,
        try Data(contentsOf: sourceChildURL) == Data(contentsOf: destinationChildURL)
      {
        try fileManager.removeItem(at: sourceChildURL)
        continue
      }
      throw ComposerNativeStateStorageError.migrationConflict(
        source: sourceChildURL,
        destination: destinationChildURL
      )
    }
  }

  private func rejectSymbolicLink(_ url: URL, fileManager: FileManager) throws {
    if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
      throw ComposerNativeStateStorageError.symbolicLink(url)
    }
  }

  private func rewriteMigratedJournalPaths(
    in stateURL: URL,
    replacing legacyURL: URL,
    with destinationURL: URL,
    fileManager: FileManager
  ) throws {
    let journalNames: Set<String> = [
      "active-project-mutation.json",
      "active-transaction.json",
      "mutation.json",
      "transaction.json",
    ]
    guard let enumerator = fileManager.enumerator(
      at: stateURL,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: []
    ) else {
      return
    }
    for case let journalURL as URL in enumerator
    where journalNames.contains(journalURL.lastPathComponent) {
      let values = try journalURL.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey,
      ])
      if values.isSymbolicLink == true {
        throw ComposerNativeStateStorageError.symbolicLink(journalURL)
      }
      guard values.isRegularFile == true else {
        continue
      }
      let object = try JSONSerialization.jsonObject(with: Data(contentsOf: journalURL))
      let rewritten = Self.replacingPathPrefix(
        in: object,
        sourcePath: legacyURL.path,
        destinationPath: destinationURL.path
      )
      let data = try JSONSerialization.data(
        withJSONObject: rewritten,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      )
      try data.write(to: journalURL, options: .atomic)
    }
  }

  private static func replacingPathPrefix(
    in value: Any,
    sourcePath: String,
    destinationPath: String
  ) -> Any {
    if let string = value as? String,
      string == sourcePath || string.hasPrefix(sourcePath + "/")
    {
      return destinationPath + String(string.dropFirst(sourcePath.count))
    }
    if let array = value as? [Any] {
      return array.map {
        replacingPathPrefix(
          in: $0,
          sourcePath: sourcePath,
          destinationPath: destinationPath
        )
      }
    }
    if let dictionary = value as? [String: Any] {
      return dictionary.mapValues {
        replacingPathPrefix(
          in: $0,
          sourcePath: sourcePath,
          destinationPath: destinationPath
        )
      }
    }
    return value
  }

  private static func projectDirectoryName(for projectURL: URL) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let sanitized = projectURL.lastPathComponent.unicodeScalars
      .map { allowed.contains($0) ? String($0) : "-" }
      .joined()
    let name = sanitized.isEmpty ? "Project" : sanitized
    let digest = SHA256.hash(data: Data(projectURL.path.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return "\(name)-\(digest.prefix(16))"
  }

  private static func isSameOrDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
    let candidateComponents = candidate.standardizedFileURL.pathComponents
    let ancestorComponents = ancestor.standardizedFileURL.pathComponents
    guard candidateComponents.count >= ancestorComponents.count else {
      return false
    }
    return Array(candidateComponents.prefix(ancestorComponents.count)) == ancestorComponents
  }
}
