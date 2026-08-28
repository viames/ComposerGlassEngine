import Foundation

public enum ComposerBinaryGenerationError: Error, Equatable, Sendable {
  case vendorDirectoryMissing(URL)
  case invalidPackageManifest(URL)
  case invalidBinaryMetadata(package: String)
  case unsafeBinaryPath(package: String, path: String)
  case binaryMissing(package: String, path: String)
  case symbolicLink(URL)
  case duplicateBinary(String)
}

public struct ComposerGeneratedBinary: Equatable, Sendable {
  public let packageName: String
  public let sourceRelativePath: String
  public let proxyURL: URL

  public init(packageName: String, sourceRelativePath: String, proxyURL: URL) {
    self.packageName = packageName
    self.sourceRelativePath = sourceRelativePath
    self.proxyURL = proxyURL
  }
}

/// Generates deterministic POSIX proxies for dependency binaries. The
/// generator validates metadata and writes files but never executes them.
public struct ComposerBinaryGenerator {
  private struct PlannedBinary {
    let packageName: String
    let relativePath: String
    let proxyName: String
  }

  private let fileManager: FileManager

  public init() {
    self.fileManager = FileManager()
  }

  public func generate(
    in vendorDirectoryURL: URL
  ) throws -> [ComposerGeneratedBinary] {
    let vendorURL = vendorDirectoryURL.standardizedFileURL
    try validateDirectory(vendorURL, missing: .vendorDirectoryMissing(vendorURL))
    let planned = try plannedBinaries(in: vendorURL)
    var names = Set<String>()
    for binary in planned {
      guard names.insert(binary.proxyName).inserted else {
        throw ComposerBinaryGenerationError.duplicateBinary(binary.proxyName)
      }
    }

    let binaryDirectoryURL = vendorURL.appendingPathComponent("bin", isDirectory: true)
    if fileManager.fileExists(atPath: binaryDirectoryURL.path) {
      try rejectSymbolicLink(binaryDirectoryURL)
    }
    try fileManager.createDirectory(
      at: binaryDirectoryURL,
      withIntermediateDirectories: true
    )
    var generated: [ComposerGeneratedBinary] = []
    generated.reserveCapacity(planned.count)
    do {
      for binary in planned {
        let proxyURL = binaryDirectoryURL.appendingPathComponent(binary.proxyName)
        let target = "../\(binary.packageName)/\(binary.relativePath)"
        try Data(Self.proxySource(target: target).utf8).write(
          to: proxyURL,
          options: .atomic
        )
        try fileManager.setAttributes(
          [.posixPermissions: NSNumber(value: 0o755)],
          ofItemAtPath: proxyURL.path
        )
        generated.append(
          ComposerGeneratedBinary(
            packageName: binary.packageName,
            sourceRelativePath: binary.relativePath,
            proxyURL: proxyURL
          )
        )
      }
    } catch {
      for binary in generated {
        try? fileManager.removeItem(at: binary.proxyURL)
      }
      throw error
    }
    return generated
  }

  private func plannedBinaries(in vendorURL: URL) throws -> [PlannedBinary] {
    var planned: [PlannedBinary] = []
    for vendorDirectory in try directoryChildren(of: vendorURL)
    where vendorDirectory.lastPathComponent != "composer"
      && vendorDirectory.lastPathComponent != "bin"
    {
      for packageDirectory in try directoryChildren(of: vendorDirectory) {
        let manifestURL = packageDirectory.appendingPathComponent("composer.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
          continue
        }
        let manifest: ComposerManifest
        do {
          manifest = try ComposerManifest.decode(from: Data(contentsOf: manifestURL))
        } catch {
          throw ComposerBinaryGenerationError.invalidPackageManifest(manifestURL)
        }
        let expectedName =
          "\(vendorDirectory.lastPathComponent)/\(packageDirectory.lastPathComponent)"
        guard manifest.name == expectedName else {
          throw ComposerBinaryGenerationError.invalidPackageManifest(manifestURL)
        }
        guard let bin = manifest["bin"] else {
          continue
        }
        let paths = try binaryPaths(bin, package: expectedName)
        for path in paths {
          let relativePath = try validatedRelativePath(path, package: expectedName)
          let sourceURL = packageDirectory.appendingPathComponent(relativePath)
          guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw ComposerBinaryGenerationError.binaryMissing(
              package: expectedName,
              path: path
            )
          }
          let values = try sourceURL.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey,
          ])
          if values.isSymbolicLink == true {
            throw ComposerBinaryGenerationError.symbolicLink(sourceURL)
          }
          guard values.isRegularFile == true else {
            throw ComposerBinaryGenerationError.binaryMissing(
              package: expectedName,
              path: path
            )
          }
          let proxyName = sourceURL.lastPathComponent
          guard !proxyName.isEmpty, proxyName != ".", proxyName != ".." else {
            throw ComposerBinaryGenerationError.unsafeBinaryPath(
              package: expectedName,
              path: path
            )
          }
          planned.append(
            PlannedBinary(
              packageName: expectedName,
              relativePath: relativePath,
              proxyName: proxyName
            )
          )
        }
      }
    }
    return planned.sorted {
      ($0.proxyName, $0.packageName, $0.relativePath)
        < ($1.proxyName, $1.packageName, $1.relativePath)
    }
  }

  private func binaryPaths(_ value: JSONValue, package: String) throws -> [String] {
    if let path = value.stringValue {
      return [path]
    }
    guard case .array(let values) = value else {
      throw ComposerBinaryGenerationError.invalidBinaryMetadata(package: package)
    }
    let paths = values.compactMap(\.stringValue)
    guard paths.count == values.count else {
      throw ComposerBinaryGenerationError.invalidBinaryMetadata(package: package)
    }
    return paths
  }

  private func validatedRelativePath(_ path: String, package: String) throws -> String {
    let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
    guard
      !path.hasPrefix("/"), !path.contains("\\"), !normalized.isEmpty,
      !components.contains(".."), !components.contains("."), !components.contains("")
    else {
      throw ComposerBinaryGenerationError.unsafeBinaryPath(package: package, path: path)
    }
    return normalized
  }

  private func directoryChildren(of directoryURL: URL) throws -> [URL] {
    try fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ).filter { url in
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      if values.isSymbolicLink == true {
        throw ComposerBinaryGenerationError.symbolicLink(url)
      }
      return values.isDirectory == true
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private func validateDirectory(
    _ url: URL,
    missing error: ComposerBinaryGenerationError
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
      throw ComposerBinaryGenerationError.symbolicLink(url)
    }
  }

  private static func proxySource(target: String) -> String {
    let escaped = target.replacingOccurrences(of: "'", with: "'\\''")
    return """
      #!/bin/sh
      case $0 in
          */*) composer_glass_bin_dir=${0%/*} ;;
          *) composer_glass_bin_dir=. ;;
      esac
      exec "$composer_glass_bin_dir"/'\(escaped)' "$@"
      """ + "\n"
  }
}
