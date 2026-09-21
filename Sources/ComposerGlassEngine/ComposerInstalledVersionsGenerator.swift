import Foundation

/// Generates the runtime metadata exposed by `composer-runtime-api` without
/// invoking PHP or Composer.
enum ComposerInstalledVersionsGenerator {
  static func write(
    rootManifest: ComposerManifest,
    projectDirectoryURL: URL,
    composerDirectoryURL: URL,
    fileManager: FileManager
  ) throws {
    let installedJSONURL = composerDirectoryURL.appendingPathComponent("installed.json")
    let document: [String: JSONValue]
    if fileManager.fileExists(atPath: installedJSONURL.path) {
      do {
        let value = try JSONDecoder().decode(
          JSONValue.self,
          from: Data(contentsOf: installedJSONURL)
        )
        guard case .object(let fields) = value else {
          throw ComposerAutoloadGenerationError.invalidInstalledMetadata(installedJSONURL)
        }
        document = fields
      } catch let error as ComposerAutoloadGenerationError {
        throw error
      } catch {
        throw ComposerAutoloadGenerationError.invalidInstalledMetadata(installedJSONURL)
      }
    } else {
      document = [:]
    }

    let installedPHP = installedMetadataSource(
      rootManifest: rootManifest,
      projectDirectoryURL: projectDirectoryURL,
      document: document
    )
    try Data(installedPHP.utf8).write(
      to: composerDirectoryURL.appendingPathComponent("installed.php"),
      options: .atomic
    )
    guard let installedVersionsURL = Bundle.module.url(
      forResource: "InstalledVersions.php",
      withExtension: nil,
      subdirectory: "Composer"
    ) else {
      throw ComposerAutoloadGenerationError.upstreamResourceMissing("InstalledVersions.php")
    }
    let installedVersionsDestination = composerDirectoryURL.appendingPathComponent(
      "InstalledVersions.php"
    )
    if fileManager.fileExists(atPath: installedVersionsDestination.path) {
      try fileManager.removeItem(at: installedVersionsDestination)
    }
    try fileManager.copyItem(at: installedVersionsURL, to: installedVersionsDestination)
  }

  private static func installedMetadataSource(
    rootManifest: ComposerManifest,
    projectDirectoryURL: URL,
    document: [String: JSONValue]
  ) -> String {
    let rootName = rootManifest.name ?? "__root__"
    let rootVersionInfo = rootVersionInfo(
      rootManifest: rootManifest,
      projectDirectoryURL: projectDirectoryURL
    )
    let rootPrettyVersion = rootVersionInfo.prettyVersion
    let rootVersion = rootVersionInfo.version
    let rootType = rootManifest.packageType ?? "project"
    let developmentMode = document["dev"]?.boolValue ?? false
    let developmentPackages = Set(
      document["dev-package-names"]?.arrayValue?.compactMap(\.stringValue) ?? []
    )

    let rootFields = [
      "name": phpQuote(rootName),
      "pretty_version": phpQuote(rootPrettyVersion),
      "version": phpQuote(rootVersion),
      "reference": rootVersionInfo.reference.map(phpQuote) ?? "null",
      "type": phpQuote(rootType),
      "install_path": "__DIR__ . '/../../'",
      "aliases": phpList(rootVersionInfo.aliases, indentation: 3),
      "dev": developmentMode ? "true" : "false",
    ]

    var versions: [String: [String: String]] = [:]
    versions[rootName] = [
      "pretty_version": phpQuote(rootPrettyVersion),
      "version": phpQuote(rootVersion),
      "reference": rootVersionInfo.reference.map(phpQuote) ?? "null",
      "type": phpQuote(rootType),
      "install_path": "__DIR__ . '/../../'",
      "aliases": phpList(rootVersionInfo.aliases),
      "dev_requirement": "false",
    ]

    if case .array(let packages)? = document["packages"] {
      for packageValue in packages {
        guard case .object(let package) = packageValue,
          let name = package["name"]?.stringValue
        else {
          continue
        }
        versions[name] = installedPackageFields(
          package,
          name: name,
          development: developmentPackages.contains(name)
        )
        addVirtualPackages(
          from: package["replace"],
          field: "replaced",
          development: developmentPackages.contains(name),
          to: &versions
        )
        addVirtualPackages(
          from: package["provide"],
          field: "provided",
          development: developmentPackages.contains(name),
          to: &versions
        )
      }
    }

    addVirtualPackages(
      from: rootManifest["replace"],
      field: "replaced",
      development: false,
      to: &versions
    )
    addVirtualPackages(
      from: rootManifest["provide"],
      field: "provided",
      development: false,
      to: &versions
    )

    let root = phpAssociativeArray(rootFields, indentation: 2)
    let versionEntries = versions.sorted { $0.key < $1.key }.map { name, fields in
      "        \(phpQuote(name)) => \(phpAssociativeArray(fields, indentation: 3)),"
    }.joined(separator: "\n")

    return """
      <?php return array(
          'root' => \(root),
          'versions' => array(
      \(versionEntries)
          ),
      );
      """ + "\n"
  }

  private static func installedPackageFields(
    _ package: [String: JSONValue],
    name: String,
    development: Bool
  ) -> [String: String] {
    let prettyVersion = package["version"]?.stringValue
    let normalizedVersion = package["version_normalized"]?.stringValue ?? prettyVersion
    let type = package["type"]?.stringValue ?? "library"
    let reference: String?
    if package["installation-source"]?.stringValue == "source" {
      reference = nestedString(in: package, object: "source", field: "reference")
        ?? nestedString(in: package, object: "dist", field: "reference")
    } else {
      reference = nestedString(in: package, object: "dist", field: "reference")
        ?? nestedString(in: package, object: "source", field: "reference")
    }
    let aliases = package["aliases"]?.arrayValue?.compactMap(\.stringValue) ?? []
    let installPath: String
    if case .null? = package["install-path"] {
      installPath = "NULL"
    } else {
      let path = package["install-path"]?.stringValue ?? installedJSONPath(for: name)
      installPath = "__DIR__ . \(phpQuote("/\(path)"))"
    }

    var fields: [String: String] = [
      "type": phpQuote(type),
      "install_path": installPath,
      "aliases": phpList(aliases),
      "dev_requirement": development ? "true" : "false",
    ]
    if let prettyVersion {
      fields["pretty_version"] = phpQuote(prettyVersion)
    }
    if let normalizedVersion {
      fields["version"] = phpQuote(normalizedVersion)
    }
    fields["reference"] = reference.map(phpQuote) ?? "null"
    return fields
  }

  private static func rootVersionInfo(
    rootManifest: ComposerManifest,
    projectDirectoryURL: URL
  ) -> (prettyVersion: String, version: String, reference: String?, aliases: [String]) {
    if let prettyVersion = rootManifest["version"]?.stringValue {
      return (
        prettyVersion,
        rootManifest["version_normalized"]?.stringValue ?? normalizedVersion(prettyVersion),
        nil,
        []
      )
    }
    if let git = gitHead(in: projectDirectoryURL) {
      let prettyVersion = "dev-\(git.branch)"
      let aliases: [String]
      if case .object(let extra)? = rootManifest["extra"],
        case .object(let branchAliases)? = extra["branch-alias"],
        let alias = branchAliases[prettyVersion]?.stringValue
      {
        aliases = [alias]
      } else {
        aliases = []
      }
      return (prettyVersion, prettyVersion, git.reference, aliases)
    }
    return ("1.0.0+no-version-set", "1.0.0.0", nil, [])
  }

  private static func normalizedVersion(_ version: String) -> String {
    guard let parsed = try? ComposerVersion(version) else { return version }
    return "\(parsed.major).\(parsed.minor).\(parsed.patch).\(parsed.build)"
  }

  private static func gitHead(in projectDirectoryURL: URL) -> (branch: String, reference: String)? {
    let fileManager = FileManager.default
    let dotGit = projectDirectoryURL.appendingPathComponent(".git")
    let gitDirectory: URL
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory), isDirectory.boolValue {
      gitDirectory = dotGit
    } else if let contents = try? String(contentsOf: dotGit, encoding: .utf8),
      contents.hasPrefix("gitdir:")
    {
      let relative = contents.dropFirst("gitdir:".count)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      gitDirectory = URL(fileURLWithPath: relative, relativeTo: projectDirectoryURL)
        .standardizedFileURL
    } else {
      return nil
    }
    let headURL = gitDirectory.appendingPathComponent("HEAD")
    guard let head = try? String(contentsOf: headURL, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines),
      head.hasPrefix("ref: ")
    else {
      return nil
    }
    let ref = String(head.dropFirst(5))
    guard ref.hasPrefix("refs/heads/") else { return nil }
    let branch = String(ref.dropFirst("refs/heads/".count))
    let refURL = gitDirectory.appendingPathComponent(ref)
    if let reference = try? String(contentsOf: refURL, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines), !reference.isEmpty
    {
      return (branch, reference)
    }
    let packedRefsURL = gitDirectory.appendingPathComponent("packed-refs")
    if let packedRefs = try? String(contentsOf: packedRefsURL, encoding: .utf8) {
      for line in packedRefs.split(separator: "\n") where !line.hasPrefix("#") {
        let components = line.split(separator: " ", maxSplits: 1)
        if components.count == 2, components[1] == Substring(ref) {
          return (branch, String(components[0]))
        }
      }
    }
    return nil
  }

  private static func addVirtualPackages(
    from value: JSONValue?,
    field: String,
    development: Bool,
    to versions: inout [String: [String: String]]
  ) {
    guard case .object(let packages)? = value else {
      return
    }
    for (name, constraintValue) in packages.sorted(by: { $0.key < $1.key }) {
      guard !ComposerPlatformPackage.isPlatformName(name) else { continue }
      guard let constraint = constraintValue.stringValue else {
        continue
      }
      var fields =
        versions[name]
        ?? [
          "dev_requirement": development ? "true" : "false"
        ]
      var constraints = phpListValues(fields[field] ?? "array()")
      if !constraints.contains(constraint) {
        constraints.append(constraint)
      }
      constraints.sort {
        $0.compare($1, options: [.caseInsensitive, .numeric]) == .orderedAscending
      }
      fields[field] = phpList(constraints)
      versions[name] = fields
    }
  }

  private static func installedJSONPath(for packageName: String) -> String {
    if packageName.hasPrefix("composer/") {
      return "./" + String(packageName.dropFirst("composer/".count))
    }
    return "../\(packageName)"
  }

  private static func nestedString(
    in fields: [String: JSONValue],
    object: String,
    field: String
  ) -> String? {
    fields[object]?.objectValue?[field]?.stringValue
  }

  private static func phpAssociativeArray(
    _ fields: [String: String],
    indentation: Int
  ) -> String {
    let spaces = String(repeating: "    ", count: indentation)
    let closingSpaces = String(repeating: "    ", count: max(0, indentation - 1))
    let entries = fields.sorted { fieldOrder($0.key) < fieldOrder($1.key) }.map { key, value in
      "\(spaces)\(phpQuote(key)) => \(value)"
    }.joined(separator: ",\n")
    return "array(\n\(entries),\n\(closingSpaces))"
  }

  private static func fieldOrder(_ field: String) -> Int {
    let order = [
      "name", "pretty_version", "version", "reference", "type", "install_path", "aliases",
      "dev", "dev_requirement", "replaced", "provided",
    ]
    return order.firstIndex(of: field) ?? order.count
  }

  private static func phpQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'"))'"
  }

  private static func phpList(_ values: [String], indentation: Int = 4) -> String {
    guard !values.isEmpty else {
      return "array()"
    }
    let spaces = String(repeating: "    ", count: indentation)
    let closingSpaces = String(repeating: "    ", count: max(0, indentation - 1))
    let entries = values.enumerated().map { index, value in
      "\(spaces)\(index) => \(phpQuote(value)),"
    }.joined(separator: "\n")
    return "array(\n\(entries)\n\(closingSpaces))"
  }

  private static func phpListValues(_ source: String) -> [String] {
    guard source != "array()" else {
      return []
    }
    let pattern = #"\d+ => '((?:\\'|[^'])*)'"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      return []
    }
    let range = NSRange(source.startIndex..<source.endIndex, in: source)
    return expression.matches(in: source, range: range).compactMap { match in
      guard let valueRange = Range(match.range(at: 1), in: source) else {
        return nil
      }
      return String(source[valueRange]).replacingOccurrences(of: "\\'", with: "'")
    }
  }

  // Adapted from Composer's InstalledVersions.php (MIT license). This is the
  // runtime API promised by packages requiring composer-runtime-api ^2.0.
  private static let installedVersionsSource = #"""
    <?php

    /*
     * This file is part of Composer.
     *
     * (c) Nils Adermann <naderman@naderman.de>
     *     Jordi Boggiano <j.boggiano@seld.be>
     *
     * For the full copyright and license information, please view the LICENSE
     * file that was distributed with this source code.
     */

    namespace Composer;

    use Composer\Semver\VersionParser;

    /**
     * Runtime package metadata compatible with composer-runtime-api ^2.0.
     *
     * @final
     */
    class InstalledVersions
    {
        private static $installed;

        public static function getInstalledPackages()
        {
            return array_keys(self::getInstalled()['versions']);
        }

        public static function getInstalledPackagesByType($type)
        {
            $packages = array();
            foreach (self::getInstalled()['versions'] as $name => $package) {
                if (isset($package['type']) && $package['type'] === $type) {
                    $packages[] = $name;
                }
            }
            return $packages;
        }

        public static function isInstalled($packageName, $includeDevRequirements = true)
        {
            $installed = self::getInstalled();
            if (!isset($installed['versions'][$packageName])) {
                return false;
            }
            return $includeDevRequirements
                || !isset($installed['versions'][$packageName]['dev_requirement'])
                || $installed['versions'][$packageName]['dev_requirement'] === false;
        }

        public static function satisfies(VersionParser $parser, $packageName, $constraint)
        {
            $constraint = $parser->parseConstraints((string) $constraint);
            $provided = $parser->parseConstraints(self::getVersionRanges($packageName));
            return $provided->matches($constraint);
        }

        public static function getVersionRanges($packageName)
        {
            $package = self::package($packageName);
            $ranges = array();
            if (isset($package['pretty_version'])) {
                $ranges[] = $package['pretty_version'];
            }
            foreach (array('aliases', 'replaced', 'provided') as $key) {
                if (isset($package[$key])) {
                    $ranges = array_merge($ranges, $package[$key]);
                }
            }
            return implode(' || ', $ranges);
        }

        public static function getVersion($packageName)
        {
            $package = self::package($packageName);
            return isset($package['version']) ? $package['version'] : null;
        }

        public static function getPrettyVersion($packageName)
        {
            $package = self::package($packageName);
            return isset($package['pretty_version']) ? $package['pretty_version'] : null;
        }

        public static function getReference($packageName)
        {
            $package = self::package($packageName);
            return isset($package['reference']) ? $package['reference'] : null;
        }

        public static function getInstallPath($packageName)
        {
            $package = self::package($packageName);
            return isset($package['install_path']) ? $package['install_path'] : null;
        }

        public static function getRootPackage()
        {
            return self::getInstalled()['root'];
        }

        public static function getRawData()
        {
            return self::getInstalled();
        }

        public static function getAllRawData()
        {
            return array(self::getInstalled());
        }

        public static function reload($data)
        {
            self::$installed = $data;
        }

        private static function package($packageName)
        {
            $installed = self::getInstalled();
            if (!isset($installed['versions'][$packageName])) {
                throw new \OutOfBoundsException('Package "' . $packageName . '" is not installed');
            }
            return $installed['versions'][$packageName];
        }

        private static function getInstalled()
        {
            if (self::$installed === null) {
                self::$installed = require __DIR__ . '/installed.php';
            }
            return self::$installed;
        }
    }
    """# + "\n"
}
