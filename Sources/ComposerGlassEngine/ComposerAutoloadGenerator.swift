import CryptoKit
import Foundation

public enum ComposerAutoloadGenerationError: Error, Equatable, Sendable {
  case vendorDirectoryMissing(URL)
  case invalidPackageManifest(URL)
  case invalidAutoload(package: String, field: String)
  case unsafePath(package: String, path: String)
  case symbolicLink(URL)
  case duplicateClass(String)
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

    var expression: String {
      let suffix = relativePath.isEmpty ? "" : "/\(relativePath)"
      switch location {
      case .project:
        return "dirname(__DIR__, 2) . \(Self.quote(suffix))"
      case .package(let package):
        return "__DIR__ . \(Self.quote("/../\(package)\(suffix)"))"
      }
    }

    private static func quote(_ value: String) -> String {
      "'\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'"))'"
    }
  }

  private let fileManager: FileManager

  public init() {
    self.fileManager = FileManager()
  }

  public func generate(
    rootManifest: ComposerManifest,
    projectDirectoryURL: URL,
    vendorDirectoryURL: URL,
    includeDevelopmentAutoload: Bool = true
  ) throws -> ComposerAutoloadGenerationResult {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: vendorDirectoryURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw ComposerAutoloadGenerationError.vendorDirectoryMissing(vendorDirectoryURL)
    }

    var manifests = [
      PackageManifest(
        name: "__root__",
        manifest: rootManifest,
        directoryURL: projectDirectoryURL.standardizedFileURL,
        baseLocation: .project,
        includeDevelopmentAutoload: includeDevelopmentAutoload
      )
    ]
    manifests += try packageManifests(in: vendorDirectoryURL)

    var psr4: [String: [PHPPath]] = [:]
    var psr0: [String: [PHPPath]] = [:]
    var files: [PHPPath] = []
    var classmap: [String: PHPPath] = [:]

    for package in manifests {
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
        try appendFiles(
          autoload["files"],
          field: "\(section).files",
          package: package,
          into: &files
        )
        try appendClassmap(
          autoload["classmap"],
          field: "\(section).classmap",
          package: package,
          into: &classmap
        )
      }
    }

    psr4 = psr4.mapValues(Self.unique)
    psr0 = psr0.mapValues(Self.unique)
    files = Self.unique(files)

    let composerDirectory = vendorDirectoryURL.appendingPathComponent(
      "composer",
      isDirectory: true
    )
    try fileManager.createDirectory(
      at: composerDirectory,
      withIntermediateDirectories: true
    )
    let initializer = Self.initializerName(
      psr4: psr4,
      psr0: psr0,
      classmap: classmap,
      files: files
    )
    try Self.write(Self.classLoaderSource, named: "ClassLoader.php", to: composerDirectory)
    try Self.write(
      Self.namespaceMapSource(psr4),
      named: "autoload_psr4.php",
      to: composerDirectory
    )
    try Self.write(
      Self.namespaceMapSource(psr0),
      named: "autoload_namespaces.php",
      to: composerDirectory
    )
    try Self.write(
      Self.classmapSource(classmap),
      named: "autoload_classmap.php",
      to: composerDirectory
    )
    try Self.write(
      Self.filesSource(files),
      named: "autoload_files.php",
      to: composerDirectory
    )
    try Self.write(
      Self.realSource(initializer: initializer),
      named: "autoload_real.php",
      to: composerDirectory
    )
    let autoloadURL = vendorDirectoryURL.appendingPathComponent("autoload.php")
    try Data(Self.autoloadSource(initializer: initializer).utf8).write(
      to: autoloadURL,
      options: .atomic
    )

    return ComposerAutoloadGenerationResult(
      autoloadURL: autoloadURL,
      packageCount: manifests.count - 1,
      classmapCount: classmap.count,
      filesCount: files.count
    )
  }

  private func packageManifests(in vendorDirectoryURL: URL) throws -> [PackageManifest] {
    let vendorDirectories = try directoryChildren(of: vendorDirectoryURL)
      .filter { $0.lastPathComponent != "composer" }
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
    into files: inout [PHPPath]
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
      files.append(
        PHPPath(
          location: package.baseLocation,
          relativePath: try validatedRelativePath(path, package: package)
        )
      )
    }
  }

  private func appendClassmap(
    _ value: JSONValue?,
    field: String,
    package: PackageManifest,
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
      let targetURL =
        relativePath.isEmpty
        ? package.directoryURL
        : package.directoryURL.appendingPathComponent(relativePath)
      for fileURL in try phpFiles(at: targetURL) {
        let relativeFilePath = fileURL.path.replacingOccurrences(
          of: package.directoryURL.path + "/",
          with: ""
        )
        let phpPath = PHPPath(
          location: package.baseLocation,
          relativePath: relativeFilePath
        )
        for className in try Self.declaredClasses(in: fileURL) {
          if classmap[className] != nil {
            throw ComposerAutoloadGenerationError.duplicateClass(className)
          }
          classmap[className] = phpPath
        }
      }
    }
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
        if previous != "new", index + 1 < tokens.count,
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

  private static func namespaceMapSource(_ map: [String: [PHPPath]]) -> String {
    let entries = map.sorted { $0.key < $1.key }.map { prefix, paths in
      let values = paths.map(\.expression).joined(separator: ", ")
      return "    \(phpQuote(prefix)) => array(\(values))"
    }.joined(separator: ",\n")
    return "<?php\n\nreturn array(\n\(entries)\n);\n"
  }

  private static func classmapSource(_ map: [String: PHPPath]) -> String {
    let entries = map.sorted { $0.key < $1.key }.map { name, path in
      "    \(phpQuote(name)) => \(path.expression)"
    }.joined(separator: ",\n")
    return "<?php\n\nreturn array(\n\(entries)\n);\n"
  }

  private static func filesSource(_ files: [PHPPath]) -> String {
    let entries = files.enumerated().map { index, path in
      "    \(phpQuote(String(index))) => \(path.expression)"
    }.joined(separator: ",\n")
    return "<?php\n\nreturn array(\n\(entries)\n);\n"
  }

  private static func initializerName(
    psr4: [String: [PHPPath]],
    psr0: [String: [PHPPath]],
    classmap: [String: PHPPath],
    files: [PHPPath]
  ) -> String {
    let description =
      String(describing: psr4) + String(describing: psr0)
      + String(describing: classmap) + String(describing: files)
    let digest = SHA256.hash(data: Data(description.utf8))
      .map { String(format: "%02x", $0) }.joined().prefix(16)
    return "ComposerGlassAutoloaderInit\(digest)"
  }

  private static func autoloadSource(initializer: String) -> String {
    """
    <?php

    require_once __DIR__ . '/composer/autoload_real.php';

    return \(initializer)::getLoader();
    """ + "\n"
  }

  private static func realSource(initializer: String) -> String {
    """
    <?php

    require_once __DIR__ . '/ClassLoader.php';

    final class \(initializer)
    {
        private static $loader;

        public static function getLoader()
        {
            if (self::$loader !== null) {
                return self::$loader;
            }

            $loader = new \\Composer\\Autoload\\ClassLoader();
            foreach (require __DIR__ . '/autoload_psr4.php' as $prefix => $paths) {
                $loader->setPsr4($prefix, $paths);
            }
            foreach (require __DIR__ . '/autoload_namespaces.php' as $prefix => $paths) {
                $loader->set($prefix, $paths);
            }
            $loader->addClassMap(require __DIR__ . '/autoload_classmap.php');
            $loader->register(true);

            $files = require __DIR__ . '/autoload_files.php';
            if (!isset($GLOBALS['__composer_autoload_files'])) {
                $GLOBALS['__composer_autoload_files'] = array();
            }
            foreach ($files as $identifier => $file) {
                if (empty($GLOBALS['__composer_autoload_files'][$identifier])) {
                    $GLOBALS['__composer_autoload_files'][$identifier] = true;
                    require $file;
                }
            }

            self::$loader = $loader;
            return $loader;
        }
    }
    """ + "\n"
  }

  private static let classLoaderSource = #"""
    <?php

    namespace Composer\Autoload;

    class ClassLoader
    {
        private $prefixDirsPsr4 = array();
        private $prefixesPsr0 = array();
        private $classMap = array();
        private $missingClasses = array();
        private $useIncludePath = false;
        private $classMapAuthoritative = false;
        private $apcuPrefix;

        public function getPrefixesPsr4() { return $this->prefixDirsPsr4; }
        public function getPrefixes() { return $this->prefixesPsr0; }
        public function getClassMap() { return $this->classMap; }
        public function addClassMap(array $classMap) { $this->classMap = array_merge($this->classMap, $classMap); }
        public function setUseIncludePath($value) { $this->useIncludePath = (bool) $value; }
        public function getUseIncludePath() { return $this->useIncludePath; }
        public function setClassMapAuthoritative($value) { $this->classMapAuthoritative = (bool) $value; }
        public function isClassMapAuthoritative() { return $this->classMapAuthoritative; }
        public function setApcuPrefix($prefix) { $this->apcuPrefix = $prefix; }
        public function getApcuPrefix() { return $this->apcuPrefix; }

        public function addPsr4($prefix, $paths, $prepend = false)
        {
            $paths = (array) $paths;
            if (!isset($this->prefixDirsPsr4[$prefix])) {
                $this->prefixDirsPsr4[$prefix] = $paths;
            } elseif ($prepend) {
                $this->prefixDirsPsr4[$prefix] = array_merge($paths, $this->prefixDirsPsr4[$prefix]);
            } else {
                $this->prefixDirsPsr4[$prefix] = array_merge($this->prefixDirsPsr4[$prefix], $paths);
            }
        }

        public function setPsr4($prefix, $paths) { $this->prefixDirsPsr4[$prefix] = (array) $paths; }

        public function add($prefix, $paths, $prepend = false)
        {
            $paths = (array) $paths;
            if (!isset($this->prefixesPsr0[$prefix])) {
                $this->prefixesPsr0[$prefix] = $paths;
            } elseif ($prepend) {
                $this->prefixesPsr0[$prefix] = array_merge($paths, $this->prefixesPsr0[$prefix]);
            } else {
                $this->prefixesPsr0[$prefix] = array_merge($this->prefixesPsr0[$prefix], $paths);
            }
        }

        public function set($prefix, $paths) { $this->prefixesPsr0[$prefix] = (array) $paths; }
        public function register($prepend = false) { spl_autoload_register(array($this, 'loadClass'), true, $prepend); }
        public function unregister() { spl_autoload_unregister(array($this, 'loadClass')); }

        public function loadClass($class)
        {
            $file = $this->findFile($class);
            if ($file === false) { return null; }
            includeFile($file);
            return true;
        }

        public function findFile($class)
        {
            if (isset($this->classMap[$class])) { return $this->classMap[$class]; }
            if ($this->classMapAuthoritative || isset($this->missingClasses[$class])) { return false; }

            foreach ($this->prefixDirsPsr4 as $prefix => $directories) {
                if ($prefix !== '' && strncmp($class, $prefix, strlen($prefix)) !== 0) { continue; }
                $relative = $prefix === '' ? $class : substr($class, strlen($prefix));
                $logical = str_replace('\\', DIRECTORY_SEPARATOR, $relative) . '.php';
                foreach ($directories as $directory) {
                    $file = $directory . DIRECTORY_SEPARATOR . $logical;
                    if (is_file($file)) { return $file; }
                }
            }

            $position = strrpos($class, '\\');
            $logical = $position === false
                ? str_replace('_', DIRECTORY_SEPARATOR, $class) . '.php'
                : str_replace('\\', DIRECTORY_SEPARATOR, substr($class, 0, $position + 1))
                    . str_replace('_', DIRECTORY_SEPARATOR, substr($class, $position + 1)) . '.php';
            foreach ($this->prefixesPsr0 as $prefix => $directories) {
                if ($prefix !== '' && strncmp($class, $prefix, strlen($prefix)) !== 0) { continue; }
                foreach ($directories as $directory) {
                    $file = $directory . DIRECTORY_SEPARATOR . $logical;
                    if (is_file($file)) { return $file; }
                }
            }

            if ($this->useIncludePath && ($file = stream_resolve_include_path($logical))) { return $file; }
            $this->missingClasses[$class] = true;
            return false;
        }
    }

    function includeFile($file) { include $file; }
    """# + "\n"
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

  private func isNonASCII(_ character: Character) -> Bool {
    character.unicodeScalars.contains { $0.value >= 128 }
  }
}
