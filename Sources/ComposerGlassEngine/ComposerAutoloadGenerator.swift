import CryptoKit
import Foundation

public enum ComposerAutoloadGenerationError: Error, Equatable, Sendable {
  case vendorDirectoryMissing(URL)
  case invalidPackageManifest(URL)
  case invalidInstalledMetadata(URL)
  case invalidAutoload(package: String, field: String)
  case unsafePath(package: String, path: String)
  case symbolicLink(URL)
  case duplicateClass(String)
  case upstreamResourceMissing(String)
}

public struct ComposerAutoloadGenerationResult: Equatable, Sendable {
  public let autoloadURL: URL
  public let packageCount: Int
  public let classmapCount: Int
  public let filesCount: Int

  public init(
    autoloadURL: URL,
    packageCount: Int,
    classmapCount: Int,
    filesCount: Int
  ) {
    self.autoloadURL = autoloadURL
    self.packageCount = packageCount
    self.classmapCount = classmapCount
    self.filesCount = filesCount
  }
}

/// Generates Composer-compatible PHP autoload metadata without invoking PHP,
/// Composer, a shell, or package code.
public struct ComposerAutoloadGenerator {
  private enum BaseLocation: Hashable, Sendable {
    case project
    case package(String)
  }

  private struct PackageManifest: Sendable {
    let name: String
    let manifest: ComposerManifest
    let directoryURL: URL
    let baseLocation: BaseLocation
    let includeDevelopmentAutoload: Bool
  }

  private struct PHPPath: Hashable, Sendable {
    let location: BaseLocation
    let relativePath: String

    var mapExpression: String {
      let suffix = relativePath.isEmpty ? "" : "/\(relativePath)"
      switch location {
      case .project:
        return "$baseDir . \(Self.quote(suffix))"
      case .package(let package):
        return "$vendorDir . \(Self.quote("/\(package)\(suffix)"))"
      }
    }

    var staticExpression: String {
      let suffix = relativePath.isEmpty ? "" : "/\(relativePath)"
      switch location {
      case .project:
        return "__DIR__ . '/../..' . \(Self.quote(suffix))"
      case .package(let package):
        return "__DIR__ . '/..' . \(Self.quote("/\(package)\(suffix)"))"
      }
    }

    private static func quote(_ value: String) -> String {
      "'\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'"))'"
    }
  }

  private struct FileAutoload: Hashable, Sendable {
    let identifier: String
    let path: PHPPath
  }

  private let fileManager: FileManager

  public init() {
    self.fileManager = FileManager()
  }

  public func generate(
    rootManifest: ComposerManifest,
    projectDirectoryURL: URL,
    vendorDirectoryURL: URL,
    includeDevelopmentAutoload: Bool = true,
    regenerateInstalledMetadata: Bool = true
  ) throws -> ComposerAutoloadGenerationResult {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: vendorDirectoryURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw ComposerAutoloadGenerationError.vendorDirectoryMissing(vendorDirectoryURL)
    }

    let rootPackage = PackageManifest(
      name: rootManifest.name ?? "__root__",
      manifest: rootManifest,
      directoryURL: projectDirectoryURL.standardizedFileURL,
      baseLocation: .project,
      includeDevelopmentAutoload: includeDevelopmentAutoload
    )
    let packages = dependencySorted(try packageManifests(in: vendorDirectoryURL))

    var psr4: [String: [PHPPath]] = [:]
    var psr0: [String: [PHPPath]] = [:]
    var files: [FileAutoload] = []
    var classmap: [String: PHPPath] = [:]
    let classmapExclusions = try classmapExclusions(
      in: [rootPackage] + packages,
      includeDevelopmentAutoload: includeDevelopmentAutoload
    )
    let optimizeAutoloader = rootManifest["config"]?.objectValue?["optimize-autoloader"]?
      .boolValue == true

    for package in [rootPackage] + packages.reversed() {
      let sections =
        package.includeDevelopmentAutoload
        ? ["autoload", "autoload-dev"]
        : ["autoload"]
      for section in sections {
        guard let value = package.manifest[section] else {
          continue
        }
        guard case .object(let autoload) = value else {
          throw ComposerAutoloadGenerationError.invalidAutoload(
            package: package.name,
            field: section
          )
        }
        try appendNamespaceMap(
          autoload["psr-4"],
          field: "\(section).psr-4",
          package: package,
          into: &psr4
        )
        try appendNamespaceMap(
          autoload["psr-0"],
          field: "\(section).psr-0",
          package: package,
          into: &psr0
        )
        try appendClassmap(
          autoload["classmap"],
          field: "\(section).classmap",
          package: package,
          exclusions: classmapExclusions,
          into: &classmap
        )
        if optimizeAutoloader {
          try appendOptimizedClassmap(
            autoload["psr-4"],
            field: "\(section).psr-4",
            package: package,
            exclusions: classmapExclusions,
            into: &classmap
          )
          try appendOptimizedClassmap(
            autoload["psr-0"],
            field: "\(section).psr-0",
            package: package,
            exclusions: classmapExclusions,
            into: &classmap
          )
        }
      }
    }
    for package in packages + [rootPackage] {
      let sections = package.includeDevelopmentAutoload
        ? ["autoload", "autoload-dev"]
        : ["autoload"]
      for section in sections {
        guard case .object(let autoload)? = package.manifest[section] else { continue }
        try appendFiles(
          autoload["files"],
          field: "\(section).files",
          package: package,
          into: &files
        )
      }
    }

    psr4 = psr4.mapValues(Self.unique)
    psr0 = psr0.mapValues(Self.unique)
    files = Self.uniqueFiles(files)

    classmap["Composer\\InstalledVersions"] = PHPPath(
      location: .package("composer"),
      relativePath: "InstalledVersions.php"
    )

    let composerDirectory = vendorDirectoryURL.appendingPathComponent(
      "composer",
      isDirectory: true
    )
    try fileManager.createDirectory(
      at: composerDirectory,
      withIntermediateDirectories: true
    )
    if regenerateInstalledMetadata {
      try ComposerInstalledVersionsGenerator.write(
        rootManifest: rootManifest,
        projectDirectoryURL: projectDirectoryURL,
        composerDirectoryURL: composerDirectory,
        fileManager: fileManager
      )
    }
    let suffix = try Self.autoloaderSuffix(
      rootManifest: rootManifest,
      projectDirectoryURL: projectDirectoryURL,
      vendorDirectoryURL: vendorDirectoryURL
    )
    try Self.copyComposerResource("ClassLoader.php", to: composerDirectory)
    try Self.copyComposerResource("LICENSE", to: composerDirectory)
    try Self.write(
      Self.namespaceMapSource(psr4),
      named: "autoload_psr4.php",
      to: composerDirectory
    )
    try Self.write(
      Self.namespaceMapSource(psr0, fileName: "autoload_namespaces.php"),
      named: "autoload_namespaces.php",
      to: composerDirectory
    )
    try Self.write(
      Self.classmapSource(classmap),
      named: "autoload_classmap.php",
      to: composerDirectory
    )
    let filesURL = composerDirectory.appendingPathComponent("autoload_files.php")
    if files.isEmpty {
      try? fileManager.removeItem(at: filesURL)
    } else {
      try Self.write(Self.filesSource(files), named: "autoload_files.php", to: composerDirectory)
    }
    try Self.write(
      Self.staticSource(
        suffix: suffix,
        psr4: psr4,
        psr0: psr0,
        classmap: classmap,
        files: files
      ),
      named: "autoload_static.php",
      to: composerDirectory
    )
    let platformCheck = try Self.platformCheckSource(
      rootManifest: rootManifest,
      projectDirectoryURL: projectDirectoryURL,
      includeDevelopmentPackages: includeDevelopmentAutoload
    )
    let platformCheckURL = composerDirectory.appendingPathComponent("platform_check.php")
    if let platformCheck {
      try Self.write(platformCheck, named: "platform_check.php", to: composerDirectory)
    } else {
      try? fileManager.removeItem(at: platformCheckURL)
    }
    try Self.write(
      Self.realSource(
        suffix: suffix,
        hasFiles: !files.isEmpty,
        checksPlatform: platformCheck != nil
      ),
      named: "autoload_real.php",
      to: composerDirectory
    )
    let autoloadURL = vendorDirectoryURL.appendingPathComponent("autoload.php")
    try Data(Self.autoloadSource(suffix: suffix).utf8).write(
      to: autoloadURL,
      options: .atomic
    )

    return ComposerAutoloadGenerationResult(
      autoloadURL: autoloadURL,
      packageCount: packages.count,
      classmapCount: classmap.count,
      filesCount: files.count
    )
  }

  private func packageManifests(in vendorDirectoryURL: URL) throws -> [PackageManifest] {
    let vendorDirectories = try directoryChildren(of: vendorDirectoryURL)
    var manifests: [PackageManifest] = []
    for vendorURL in vendorDirectories {
      for packageURL in try directoryChildren(of: vendorURL) {
        let manifestURL = packageURL.appendingPathComponent("composer.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
          continue
        }
        let manifest: ComposerManifest
        do {
          manifest = try ComposerManifest.decode(from: Data(contentsOf: manifestURL))
        } catch {
          throw ComposerAutoloadGenerationError.invalidPackageManifest(manifestURL)
        }
        let fallbackName = "\(vendorURL.lastPathComponent)/\(packageURL.lastPathComponent)"
        let name = manifest.name ?? fallbackName
        guard name == fallbackName else {
          throw ComposerAutoloadGenerationError.invalidPackageManifest(manifestURL)
        }
        manifests.append(
          PackageManifest(
            name: name,
            manifest: manifest,
            directoryURL: packageURL.standardizedFileURL,
            baseLocation: .package(name),
            includeDevelopmentAutoload: false
          )
        )
      }
    }
    return manifests.sorted { $0.name < $1.name }
  }

  private func dependencySorted(_ packages: [PackageManifest]) -> [PackageManifest] {
    let packageNames = Set(packages.map(\.name))
    var users: [String: [String]] = [:]
    for package in packages {
      guard case .object(let requirements)? = package.manifest["require"] else { continue }
      for target in requirements.keys where packageNames.contains(target) {
        users[target, default: []].append(package.name)
      }
    }
    var computing = Set<String>()
    var computed: [String: Int] = [:]
    func importance(_ name: String) -> Int {
      if let value = computed[name] { return value }
      guard computing.insert(name).inserted else { return 0 }
      var weight = 0
      for user in users[name] ?? [] {
        weight -= 1 - importance(user)
      }
      computing.remove(name)
      computed[name] = weight
      return weight
    }
    return packages.sorted { lhs, rhs in
      let lhsWeight = importance(lhs.name)
      let rhsWeight = importance(rhs.name)
      if lhsWeight != rhsWeight { return lhsWeight < rhsWeight }
      return lhs.name.compare(
        rhs.name,
        options: [.caseInsensitive, .numeric]
      ) == .orderedAscending
    }
  }

  private func directoryChildren(of directoryURL: URL) throws -> [URL] {
    try fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ).filter { url in
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      if values.isSymbolicLink == true {
        throw ComposerAutoloadGenerationError.symbolicLink(url)
      }
      return values.isDirectory == true
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private func appendNamespaceMap(
    _ value: JSONValue?,
    field: String,
    package: PackageManifest,
    into map: inout [String: [PHPPath]]
  ) throws {
    guard let value else {
      return
    }
    guard case .object(let entries) = value else {
      throw ComposerAutoloadGenerationError.invalidAutoload(
        package: package.name,
        field: field
      )
    }
    for (prefix, pathValue) in entries.sorted(by: { $0.key < $1.key }) {
      let paths = try stringList(
        pathValue,
        package: package.name,
        field: field
      )
      for path in paths {
        let normalized = try validatedRelativePath(path, package: package)
        map[prefix, default: []].append(
          PHPPath(location: package.baseLocation, relativePath: normalized)
        )
      }
    }
  }

  private func appendFiles(
    _ value: JSONValue?,
    field: String,
    package: PackageManifest,
    into files: inout [FileAutoload]
  ) throws {
    guard let value else {
      return
    }
    guard case .array(let values) = value else {
      throw ComposerAutoloadGenerationError.invalidAutoload(
        package: package.name,
        field: field
      )
    }
    for value in values {
      guard let path = value.stringValue else {
        throw ComposerAutoloadGenerationError.invalidAutoload(
          package: package.name,
          field: field
        )
      }
      let normalized = try validatedRelativePath(path, package: package)
      files.append(
        FileAutoload(
          identifier: Self.md5("\(package.name):\(path)"),
          path: PHPPath(
          location: package.baseLocation,
            relativePath: normalized
          )
        )
      )
    }
  }

  private func appendClassmap(
    _ value: JSONValue?,
    field: String,
    package: PackageManifest,
    exclusions: [NSRegularExpression],
    into classmap: inout [String: PHPPath]
  ) throws {
    guard let value else {
      return
    }
    guard case .array(let values) = value else {
      throw ComposerAutoloadGenerationError.invalidAutoload(
        package: package.name,
        field: field
      )
    }
    for value in values {
      guard let path = value.stringValue else {
        throw ComposerAutoloadGenerationError.invalidAutoload(
          package: package.name,
          field: field
        )
      }
      let relativePath = try validatedRelativePath(path, package: package)
      try scanClassmapPath(
        relativePath,
        package: package,
        exclusions: exclusions,
        into: &classmap
      )
    }
  }

  private func appendOptimizedClassmap(
    _ value: JSONValue?,
    field: String,
    package: PackageManifest,
    exclusions: [NSRegularExpression],
    into classmap: inout [String: PHPPath]
  ) throws {
    guard case .object(let entries)? = value else {
      if value != nil {
        throw ComposerAutoloadGenerationError.invalidAutoload(
          package: package.name,
          field: field
        )
      }
      return
    }
    for pathValue in entries.values {
      for path in try stringList(pathValue, package: package.name, field: field) {
        try scanClassmapPath(
          validatedRelativePath(path, package: package),
          package: package,
          exclusions: exclusions,
          into: &classmap
        )
      }
    }
  }

  private func scanClassmapPath(
    _ relativePath: String,
    package: PackageManifest,
    exclusions: [NSRegularExpression],
    into classmap: inout [String: PHPPath]
  ) throws {
    let targetURL = relativePath.isEmpty
      ? package.directoryURL
      : package.directoryURL.appendingPathComponent(relativePath)
    for fileURL in try phpFiles(at: targetURL) where !isExcluded(fileURL, by: exclusions) {
      let packagePath = package.directoryURL.resolvingSymlinksInPath().standardizedFileURL.path
      let filePath = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
      let relativePrefix = packagePath + "/"
      guard filePath.hasPrefix(relativePrefix) else {
        throw ComposerAutoloadGenerationError.unsafePath(
          package: package.name,
          path: fileURL.path
        )
      }
      let relativeFilePath = String(filePath.dropFirst(relativePrefix.count))
      let phpPath = PHPPath(
        location: package.baseLocation,
        relativePath: relativeFilePath
      )
      for className in try Self.declaredClasses(in: fileURL) {
        if let existingPath = classmap[className] {
          if existingPath.mapExpression == phpPath.mapExpression { continue }
          throw ComposerAutoloadGenerationError.duplicateClass(className)
        }
        classmap[className] = phpPath
      }
    }
  }

  private func classmapExclusions(
    in packages: [PackageManifest],
    includeDevelopmentAutoload: Bool
  ) throws -> [NSRegularExpression] {
    var expressions: [NSRegularExpression] = []
    for package in packages {
      let sections = package.includeDevelopmentAutoload && includeDevelopmentAutoload
        ? ["autoload", "autoload-dev"]
        : ["autoload"]
      for section in sections {
        guard case .object(let autoload)? = package.manifest[section],
          case .array(let patterns)? = autoload["exclude-from-classmap"]
        else { continue }
        for value in patterns {
          guard let pattern = value.stringValue else {
            throw ComposerAutoloadGenerationError.invalidAutoload(
              package: package.name,
              field: "\(section).exclude-from-classmap"
            )
          }
          expressions.append(
            try exclusionExpression(pattern, package: package)
          )
        }
      }
    }
    return expressions
  }

  private func exclusionExpression(
    _ pattern: String,
    package: PackageManifest
  ) throws -> NSRegularExpression {
    let relative = pattern.replacingOccurrences(of: "\\", with: "/")
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let components = relative.split(separator: "/", omittingEmptySubsequences: false)
    guard !pattern.contains("\\"), !components.contains(".."), !components.contains(".") else {
      throw ComposerAutoloadGenerationError.unsafePath(package: package.name, path: pattern)
    }
    let absolute = package.directoryURL.standardizedFileURL.path
      + (relative.isEmpty ? "" : "/" + relative)
    let characters = Array(absolute)
    var regex = "^"
    var index = 0
    while index < characters.count {
      if characters[index] == "*" {
        if index + 1 < characters.count, characters[index + 1] == "*" {
          regex += ".*"
          index += 2
        } else {
          regex += "[^/]*"
          index += 1
        }
      } else if characters[index] == "?" {
        regex += "[^/]"
        index += 1
      } else {
        regex += NSRegularExpression.escapedPattern(for: String(characters[index]))
        index += 1
      }
    }
    if pattern.hasSuffix("/") { regex += ".*" }
    regex += "$"
    return try NSRegularExpression(pattern: regex)
  }

  private func isExcluded(_ url: URL, by expressions: [NSRegularExpression]) -> Bool {
    let path = url.standardizedFileURL.path
    let range = NSRange(path.startIndex..<path.endIndex, in: path)
    return expressions.contains { $0.firstMatch(in: path, range: range) != nil }
  }

  private func validatedRelativePath(
    _ path: String,
    package: PackageManifest
  ) throws -> String {
    let normalized = path.replacingOccurrences(of: "\\", with: "/")
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
    guard
      !path.hasPrefix("/"), !path.contains("\\"),
      !components.contains(".."), !components.contains("."),
      !components.contains("")
    else {
      if normalized.isEmpty, path.isEmpty || path == "." || path == "./" {
        return ""
      }
      throw ComposerAutoloadGenerationError.unsafePath(
        package: package.name,
        path: path
      )
    }
    let baseURL = package.directoryURL.standardizedFileURL
    let targetURL = baseURL.appendingPathComponent(normalized).standardizedFileURL
    guard
      targetURL.path == baseURL.path
        || targetURL.path.hasPrefix(baseURL.path + "/")
    else {
      throw ComposerAutoloadGenerationError.unsafePath(
        package: package.name,
        path: path
      )
    }
    return normalized
  }

  private func stringList(
    _ value: JSONValue,
    package: String,
    field: String
  ) throws -> [String] {
    if let string = value.stringValue {
      return [string]
    }
    guard case .array(let values) = value else {
      throw ComposerAutoloadGenerationError.invalidAutoload(package: package, field: field)
    }
    let strings = values.compactMap(\.stringValue)
    guard strings.count == values.count else {
      throw ComposerAutoloadGenerationError.invalidAutoload(package: package, field: field)
    }
    return strings
  }

  private func phpFiles(at targetURL: URL) throws -> [URL] {
    guard fileManager.fileExists(atPath: targetURL.path) else {
      return []
    }
    let values = try targetURL.resourceValues(forKeys: [
      .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
    ])
    if values.isSymbolicLink == true {
      throw ComposerAutoloadGenerationError.symbolicLink(targetURL)
    }
    if values.isRegularFile == true {
      return targetURL.pathExtension.lowercased() == "php" ? [targetURL] : []
    }
    guard values.isDirectory == true else {
      return []
    }
    guard
      let enumerator = fileManager.enumerator(
        at: targetURL,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }
    var files: [URL] = []
    for case let fileURL as URL in enumerator {
      let resourceValues = try fileURL.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey,
      ])
      if resourceValues.isSymbolicLink == true {
        throw ComposerAutoloadGenerationError.symbolicLink(fileURL)
      }
      if resourceValues.isRegularFile == true, fileURL.pathExtension.lowercased() == "php" {
        files.append(fileURL)
      }
    }
    return files.sorted { $0.path < $1.path }
  }

  private static func unique(_ values: [PHPPath]) -> [PHPPath] {
    var seen = Set<PHPPath>()
    return values.filter { seen.insert($0).inserted }
  }

  private static func uniqueFiles(_ values: [FileAutoload]) -> [FileAutoload] {
    var identifiers = Set<String>()
    return values.filter { identifiers.insert($0.identifier).inserted }
  }

  private static func declaredClasses(in fileURL: URL) throws -> [String] {
    let source = try String(contentsOf: fileURL, encoding: .utf8)
    let tokens = PHPTokenScanner(source: source).tokens()
    var namespace = ""
    var classes: [String] = []
    var index = 0
    while index < tokens.count {
      let token = tokens[index]
      if token == "namespace" {
        index += 1
        var components: [String] = []
        while index < tokens.count, tokens[index] != ";", tokens[index] != "{" {
          if tokens[index] != "\\" {
            components.append(tokens[index])
          }
          index += 1
        }
        namespace = components.joined(separator: "\\")
      } else if ["class", "interface", "trait", "enum"].contains(token) {
        let previous = index > 0 ? tokens[index - 1] : ""
        let memberAccessTokens = ["new", "$", ">", ":", "\\"]
        if !memberAccessTokens.contains(previous), index + 1 < tokens.count,
          Self.isPHPIdentifier(tokens[index + 1])
        {
          let name = tokens[index + 1]
          classes.append(namespace.isEmpty ? name : "\(namespace)\\\(name)")
        }
      }
      index += 1
    }
    return classes
  }

  private static func isPHPIdentifier(_ value: String) -> Bool {
    value.range(of: #"^[A-Za-z_\x80-\xff][A-Za-z0-9_\x80-\xff]*$"#, options: .regularExpression)
      != nil
  }

  private static func write(_ source: String, named name: String, to directory: URL) throws {
    try Data(source.utf8).write(
      to: directory.appendingPathComponent(name),
      options: .atomic
    )
  }

  private static func phpQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'"))'"
  }

  private static func namespaceMapSource(
    _ map: [String: [PHPPath]],
    fileName: String? = nil
  ) -> String {
    let generatedName = fileName ?? "autoload_psr4.php"
    let entries = map.sorted { $0.key > $1.key }.map { prefix, paths in
      let values = paths.map(\.mapExpression).joined(separator: ", ")
      return "    \(phpQuote(prefix)) => array(\(values)),\n"
    }.joined()
    return """
      <?php

      // \(generatedName) @generated by Composer

      $vendorDir = dirname(__DIR__);
      $baseDir = dirname($vendorDir);

      return array(
      \(entries));
      """ + "\n"
  }

  private static func classmapSource(_ map: [String: PHPPath]) -> String {
    let entries = map.sorted { $0.key < $1.key }.map { name, path in
      "    \(phpQuote(name)) => \(path.mapExpression),\n"
    }.joined()
    return """
      <?php

      // autoload_classmap.php @generated by Composer

      $vendorDir = dirname(__DIR__);
      $baseDir = dirname($vendorDir);

      return array(
      \(entries));
      """ + "\n"
  }

  private static func filesSource(_ files: [FileAutoload]) -> String {
    let entries = files.map { file in
      "    \(phpQuote(file.identifier)) => \(file.path.mapExpression),\n"
    }.joined()
    return """
      <?php

      // autoload_files.php @generated by Composer

      $vendorDir = dirname(__DIR__);
      $baseDir = dirname($vendorDir);

      return array(
      \(entries));
      """ + "\n"
  }

  private static func copyComposerResource(_ name: String, to directory: URL) throws {
    guard let source = Bundle.module.url(
      forResource: name,
      withExtension: nil,
      subdirectory: "Composer"
    ) else {
      throw ComposerAutoloadGenerationError.upstreamResourceMissing(name)
    }
    let destination = directory.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.copyItem(at: source, to: destination)
  }

  private static func autoloaderSuffix(
    rootManifest: ComposerManifest,
    projectDirectoryURL: URL,
    vendorDirectoryURL: URL
  ) throws -> String {
    if case .object(let config)? = rootManifest["config"],
      let configured = config["autoloader-suffix"]?.stringValue,
      !configured.isEmpty
    {
      return configured
    }

    let existingAutoloadURL = vendorDirectoryURL.appendingPathComponent("autoload.php")
    if let source = try? String(contentsOf: existingAutoloadURL, encoding: .utf8),
      let expression = try? NSRegularExpression(
        pattern: #"ComposerAutoloaderInit([^:\s]+)::"#
      ),
      let match = expression.firstMatch(
        in: source,
        range: NSRange(source.startIndex..<source.endIndex, in: source)
      ),
      let range = Range(match.range(at: 1), in: source)
    {
      return String(source[range])
    }

    let lockURL = projectDirectoryURL.appendingPathComponent("composer.lock")
    if let data = try? Data(contentsOf: lockURL),
      let value = try? JSONDecoder().decode(JSONValue.self, from: data),
      let suffix = value.objectValue?["content-hash"]?.stringValue,
      !suffix.isEmpty,
      suffix.range(of: #"^[a-f0-9]+$"#, options: .regularExpression) != nil
    {
      return suffix
    }

    return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }

  private static func md5(_ value: String) -> String {
    Insecure.MD5.hash(data: Data(value.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
  }

  private static func autoloadSource(suffix: String) -> String {
    """
    <?php

    // autoload.php @generated by Composer

    if (PHP_VERSION_ID < 50600) {
        if (!headers_sent()) {
            header('HTTP/1.1 500 Internal Server Error');
        }
        $err = 'Composer 2.3.0 dropped support for autoloading on PHP <5.6 and you are running '.PHP_VERSION.', please upgrade PHP or use Composer 2.2 LTS via "composer self-update --2.2". Aborting.'.PHP_EOL;
        if (!ini_get('display_errors')) {
            if (PHP_SAPI === 'cli' || PHP_SAPI === 'phpdbg') {
                fwrite(STDERR, $err);
            } elseif (!headers_sent()) {
                echo $err;
            }
        }
        throw new RuntimeException($err);
    }

    require_once __DIR__ . '/composer/autoload_real.php';

    return ComposerAutoloaderInit\(suffix)::getLoader();
    """ + "\n"
  }

  private static func realSource(
    suffix: String,
    hasFiles: Bool,
    checksPlatform: Bool
  ) -> String {
    var source = """
    <?php

    // autoload_real.php @generated by Composer

    class ComposerAutoloaderInit\(suffix)
    {
        private static $loader;

        public static function loadClassLoader($class)
        {
            if ('Composer\\Autoload\\ClassLoader' === $class) {
                require __DIR__ . '/ClassLoader.php';
            }
        }

        /**
         * @return \\Composer\\Autoload\\ClassLoader
         */
        public static function getLoader()
        {
            if (null !== self::$loader) {
                return self::$loader;
            }

    """
    if checksPlatform {
      source += "\n        require __DIR__ . '/platform_check.php';\n\n"
    }
    source += """
            spl_autoload_register(array('ComposerAutoloaderInit\(suffix)', 'loadClassLoader'), true, true);
            self::$loader = $loader = new \\Composer\\Autoload\\ClassLoader(\\dirname(__DIR__));
            spl_autoload_unregister(array('ComposerAutoloaderInit\(suffix)', 'loadClassLoader'));

            require __DIR__ . '/autoload_static.php';
            call_user_func(\\Composer\\Autoload\\ComposerStaticInit\(suffix)::getInitializer($loader));

            $loader->register(true);

    """
    if hasFiles {
      source += "\n" + [
        "        $filesToLoad = \\Composer\\Autoload\\ComposerStaticInit\(suffix)::$files;",
        "        $requireFile = \\Closure::bind(static function ($fileIdentifier, $file) {",
        "            if (empty($GLOBALS['__composer_autoload_files'][$fileIdentifier])) {",
        "                $GLOBALS['__composer_autoload_files'][$fileIdentifier] = true;",
        "",
        "                require $file;",
        "            }",
        "        }, null, null);",
        "        foreach ($filesToLoad as $fileIdentifier => $file) {",
        "            $requireFile($fileIdentifier, $file);",
        "        }",
        "",
      ].joined(separator: "\n")
    }
    source += "\n" + """
            return $loader;
        }
    }
    """
    return source + "\n"
  }

  private static func staticSource(
    suffix: String,
    psr4: [String: [PHPPath]],
    psr0: [String: [PHPPath]],
    classmap: [String: PHPPath],
    files: [FileAutoload]
  ) -> String {
    var properties: [(String, String)] = []
    if !files.isEmpty {
      let entries = files.map {
        "        \(phpQuote($0.identifier)) => \($0.path.staticExpression),\n"
      }.joined()
      properties.append(("files", "array (\n\(entries)    )"))
    }

    let psr4Prefixes = psr4.keys.filter { !$0.isEmpty }.sorted(by: >)
    if !psr4Prefixes.isEmpty {
      var groups: [(Character, [String])] = []
      for prefix in psr4Prefixes {
        guard let first = prefix.first else { continue }
        if groups.last?.0 == first {
          groups[groups.count - 1].1.append(prefix)
        } else {
          groups.append((first, [prefix]))
        }
      }
      let groupSource = groups.map { first, prefixes in
        let entries = prefixes.map {
          "            \(phpQuote($0)) => \($0.count),\n"
        }.joined()
        return "        \(phpQuote(String(first))) =>\n        array (\n\(entries)        ),\n"
      }.joined()
      properties.append(("prefixLengthsPsr4", "array (\n\(groupSource)    )"))

      let directorySource = psr4Prefixes.map { prefix in
        let entries = (psr4[prefix] ?? []).enumerated().map { index, path in
          "            \(index) => \(path.staticExpression),\n"
        }.joined()
        return "        \(phpQuote(prefix)) =>\n        array (\n\(entries)        ),\n"
      }.joined()
      properties.append(("prefixDirsPsr4", "array (\n\(directorySource)    )"))
    }
    if let fallback = psr4[""], !fallback.isEmpty {
      let entries = fallback.enumerated().map {
        "        \($0.offset) => \($0.element.staticExpression),\n"
      }.joined()
      properties.append(("fallbackDirsPsr4", "array (\n\(entries)    )"))
    }

    let psr0Prefixes = psr0.keys.filter { !$0.isEmpty }.sorted(by: >)
    if !psr0Prefixes.isEmpty {
      var groups: [(Character, [String])] = []
      for prefix in psr0Prefixes {
        guard let first = prefix.first else { continue }
        if groups.last?.0 == first {
          groups[groups.count - 1].1.append(prefix)
        } else {
          groups.append((first, [prefix]))
        }
      }
      let groupSource = groups.map { first, prefixes in
        let prefixSource = prefixes.map { prefix in
          let entries = (psr0[prefix] ?? []).enumerated().map { index, path in
            "                \(index) => \(path.staticExpression),\n"
          }.joined()
          return "            \(phpQuote(prefix)) =>\n            array (\n\(entries)            ),\n"
        }.joined()
        return "        \(phpQuote(String(first))) =>\n        array (\n\(prefixSource)        ),\n"
      }.joined()
      properties.append(("prefixesPsr0", "array (\n\(groupSource)    )"))
    }
    if let fallback = psr0[""], !fallback.isEmpty {
      let entries = fallback.enumerated().map {
        "        \($0.offset) => \($0.element.staticExpression),\n"
      }.joined()
      properties.append(("fallbackDirsPsr0", "array (\n\(entries)    )"))
    }

    if !classmap.isEmpty {
      let entries = classmap.sorted { $0.key < $1.key }.map {
        "        \(phpQuote($0.key)) => \($0.value.staticExpression),\n"
      }.joined()
      properties.append(("classMap", "array (\n\(entries)    )"))
    }

    let propertySource = properties.map {
      "    public static $\($0.0) = \($0.1);\n\n"
    }.joined()
    let initializerSource = properties.filter { $0.0 != "files" }.map {
      "            $loader->\($0.0) = ComposerStaticInit\(suffix)::$\($0.0);\n"
    }.joined()
    return """
      <?php

      // autoload_static.php @generated by Composer

      namespace Composer\\Autoload;

      class ComposerStaticInit\(suffix)
      {
      \(propertySource)    public static function getInitializer(ClassLoader $loader)
          {
              return \\Closure::bind(function () use ($loader) {
      \(initializerSource)
              }, null, ClassLoader::class);
          }
      }
      """ + "\n"
  }

  private static func platformCheckSource(
    rootManifest: ComposerManifest,
    projectDirectoryURL: URL,
    includeDevelopmentPackages: Bool
  ) throws -> String? {
    if case .object(let config)? = rootManifest["config"],
      config["platform-check"]?.boolValue == false
    {
      return nil
    }
    var constraints: [String] = []
    var requires64BitPHP = false
    if case .object(let requirements)? = rootManifest["require"],
      let php = requirements["php"]?.stringValue
    {
      constraints.append(php)
    }
    let lockURL = projectDirectoryURL.appendingPathComponent("composer.lock")
    if let lock = try? ComposerLockFile.decode(from: Data(contentsOf: lockURL)) {
      var packages = try lock.packages()
      if includeDevelopmentPackages {
        packages += try lock.packages(in: .development)
      }
      for package in packages {
        let requirements = try package.requirements()
        if let php = requirements["php"] {
          constraints.append(php)
        }
        requires64BitPHP = requires64BitPHP || requirements["php-64bit"] != nil
      }
    }
    guard let minimum = constraints.compactMap(minimumPHPVersion).max(by: {
      if $0.0 != $1.0 { return $0.0 < $1.0 }
      if $0.1 != $1.1 { return $0.1 < $1.1 }
      return $0.2 < $1.2
    }) else {
      return nil
    }
    let versionID = minimum.0 * 10_000 + minimum.1 * 100 + minimum.2
    let human = "\(minimum.0).\(minimum.1).\(minimum.2)"
    let widthCheck = requires64BitPHP
      ? [
        "",
        "if (PHP_INT_SIZE !== 8) {",
        "    $issues[] = 'Your Composer dependencies require a 64-bit build of PHP.';",
        "}",
        "",
      ].joined(separator: "\n")
      : ""
    return """
      <?php

      // platform_check.php @generated by Composer

      $issues = array();

      if (!(PHP_VERSION_ID >= \(versionID))) {
          $issues[] = 'Your Composer dependencies require a PHP version ">= \(human)". You are running ' . PHP_VERSION . '.';
      }
      \(widthCheck)
      if ($issues) {
          if (!headers_sent()) {
              header('HTTP/1.1 500 Internal Server Error');
          }
          if (!ini_get('display_errors')) {
              if (PHP_SAPI === 'cli' || PHP_SAPI === 'phpdbg') {
                  fwrite(STDERR, 'Composer detected issues in your platform:' . PHP_EOL.PHP_EOL . implode(PHP_EOL, $issues) . PHP_EOL.PHP_EOL);
              } elseif (!headers_sent()) {
                  echo 'Composer detected issues in your platform:' . PHP_EOL.PHP_EOL . str_replace('You are running '.PHP_VERSION.'.', '', implode(PHP_EOL, $issues)) . PHP_EOL.PHP_EOL;
              }
          }
          throw new \\RuntimeException(
              'Composer detected issues in your platform: ' . implode(' ', $issues)
          );
      }
      """ + "\n"
  }

  private static func minimumPHPVersion(_ constraint: String) -> (Int, Int, Int)? {
    guard let expression = try? NSRegularExpression(pattern: #"(?:>=|\^|~|>|=)?\s*(\d+)(?:\.(\d+))?(?:\.(\d+))?"#),
      let match = expression.firstMatch(
        in: constraint,
        range: NSRange(constraint.startIndex..<constraint.endIndex, in: constraint)
      )
    else {
      return nil
    }
    func component(_ index: Int) -> Int {
      guard match.range(at: index).location != NSNotFound,
        let range = Range(match.range(at: index), in: constraint)
      else { return 0 }
      return Int(constraint[range]) ?? 0
    }
    return (component(1), component(2), component(3))
  }
}

private struct PHPTokenScanner {
  let source: String

  func tokens() -> [String] {
    let characters = Array(source)
    var result: [String] = []
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if character.isWhitespace {
        index += 1
      } else if character == "/", index + 1 < characters.count,
        characters[index + 1] == "/"
      {
        index = skipLine(in: characters, from: index + 2)
      } else if character == "#" {
        index = skipLine(in: characters, from: index + 1)
      } else if character == "/", index + 1 < characters.count,
        characters[index + 1] == "*"
      {
        index = skipBlockComment(in: characters, from: index + 2)
      } else if character == "'" || character == "\"" {
        index = skipString(in: characters, from: index + 1, quote: character)
      } else if character == "<", index + 2 < characters.count,
        characters[index + 1] == "<", characters[index + 2] == "<"
      {
        index = skipHeredoc(in: characters, from: index + 3)
      } else if character.isLetter || character == "_" || isNonASCII(character) {
        let start = index
        index += 1
        while index < characters.count {
          let candidate = characters[index]
          guard
            candidate.isLetter || candidate.isNumber || candidate == "_"
              || isNonASCII(candidate)
          else {
            break
          }
          index += 1
        }
        let word = String(characters[start..<index])
        let lowercased = word.lowercased()
        let keywords = ["namespace", "class", "interface", "trait", "enum", "new"]
        result.append(keywords.contains(lowercased) ? lowercased : word)
      } else {
        result.append(String(character))
        index += 1
      }
    }
    return result
  }

  private func skipLine(in characters: [Character], from start: Int) -> Int {
    var index = start
    while index < characters.count, characters[index] != "\n" { index += 1 }
    return index
  }

  private func skipBlockComment(in characters: [Character], from start: Int) -> Int {
    var index = start
    while index + 1 < characters.count {
      if characters[index] == "*", characters[index + 1] == "/" { return index + 2 }
      index += 1
    }
    return characters.count
  }

  private func skipString(in characters: [Character], from start: Int, quote: Character) -> Int {
    var index = start
    while index < characters.count {
      if characters[index] == "\\" {
        index += 2
        continue
      }
      if characters[index] == quote { return index + 1 }
      index += 1
    }
    return characters.count
  }

  private func skipHeredoc(in characters: [Character], from start: Int) -> Int {
    var index = start
    while index < characters.count, characters[index].isWhitespace, characters[index] != "\n" {
      index += 1
    }
    let quote: Character? = index < characters.count && ["'", "\""].contains(characters[index])
      ? characters[index]
      : nil
    if quote != nil { index += 1 }
    let labelStart = index
    while index < characters.count,
      characters[index].isLetter || characters[index].isNumber || characters[index] == "_"
    {
      index += 1
    }
    guard index > labelStart else { return start }
    let label = String(characters[labelStart..<index])
    if let quote, index < characters.count, characters[index] == quote { index += 1 }
    index = skipLine(in: characters, from: index)
    if index < characters.count { index += 1 }
    while index < characters.count {
      let lineStart = index
      let lineEnd = skipLine(in: characters, from: lineStart)
      let line = String(characters[lineStart..<lineEnd])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if line == label || line == "\(label);" {
        return lineEnd < characters.count ? lineEnd + 1 : lineEnd
      }
      index = lineEnd < characters.count ? lineEnd + 1 : lineEnd
    }
    return characters.count
  }

  private func isNonASCII(_ character: Character) -> Bool {
    character.unicodeScalars.contains { $0.value >= 128 }
  }
}
