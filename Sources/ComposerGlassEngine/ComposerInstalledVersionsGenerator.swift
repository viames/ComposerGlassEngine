import Foundation

/// Generates the runtime metadata exposed by `composer-runtime-api` without
/// invoking PHP or Composer.
enum ComposerInstalledVersionsGenerator {
  static func write(
    rootManifest: ComposerManifest,
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
      document: document
    )
    try Data(installedPHP.utf8).write(
      to: composerDirectoryURL.appendingPathComponent("installed.php"),
      options: .atomic
    )
    try Data(installedVersionsSource.utf8).write(
      to: composerDirectoryURL.appendingPathComponent("InstalledVersions.php"),
      options: .atomic
    )
  }

  private static func installedMetadataSource(
    rootManifest: ComposerManifest,
    document: [String: JSONValue]
  ) -> String {
    let rootName = rootManifest.name ?? "__root__"
    let rootPrettyVersion = rootManifest["version"]?.stringValue ?? "dev-main"
    let rootVersion = rootManifest["version_normalized"]?.stringValue ?? rootPrettyVersion
    let rootType = rootManifest.packageType ?? "project"
    let developmentMode = document["dev"]?.boolValue ?? false

    let rootFields = [
      "name": phpQuote(rootName),
      "pretty_version": phpQuote(rootPrettyVersion),
      "version": phpQuote(rootVersion),
      "reference": "NULL",
      "type": phpQuote(rootType),
      "install_path": "__DIR__ . '/../../'",
      "aliases": "array()",
      "dev": developmentMode ? "true" : "false",
    ]

    var versions: [String: [String: String]] = [:]
    versions[rootName] = [
      "pretty_version": phpQuote(rootPrettyVersion),
      "version": phpQuote(rootVersion),
      "reference": "NULL",
      "type": phpQuote(rootType),
      "install_path": "__DIR__ . '/../../'",
      "aliases": "array()",
      "dev_requirement": "false",
    ]

    if case .array(let packages)? = document["packages"] {
      for packageValue in packages {
        guard case .object(let package) = packageValue,
          let name = package["name"]?.stringValue
        else {
          continue
        }
        versions[name] = installedPackageFields(package, name: name)
        addVirtualPackages(
          from: package["replace"],
          field: "replaced",
          development: package["dev_requirement"]?.boolValue ?? false,
          to: &versions
        )
        addVirtualPackages(
          from: package["provide"],
          field: "provided",
          development: package["dev_requirement"]?.boolValue ?? false,
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
      "        \(phpQuote(name)) => \(phpAssociativeArray(fields, indentation: 2))"
    }.joined(separator: ",\n")

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
    name: String
  ) -> [String: String] {
    let prettyVersion = package["version"]?.stringValue
    let normalizedVersion = package["version_normalized"]?.stringValue ?? prettyVersion
    let type = package["type"]?.stringValue ?? "library"
    let reference =
      nestedString(in: package, object: "source", field: "reference")
      ?? nestedString(in: package, object: "dist", field: "reference")
    let aliases = package["aliases"]?.arrayValue?.compactMap(\.stringValue) ?? []
    let installPath: String
    if case .null? = package["install-path"] {
      installPath = "NULL"
    } else {
      let path = package["install-path"]?.stringValue ?? "../\(name)"
      installPath = "__DIR__ . \(phpQuote("/\(path)"))"
    }

    var fields: [String: String] = [
      "type": phpQuote(type),
      "install_path": installPath,
      "aliases": phpList(aliases),
      "dev_requirement": (package["dev_requirement"]?.boolValue ?? false) ? "true" : "false",
    ]
    if let prettyVersion {
      fields["pretty_version"] = phpQuote(prettyVersion)
    }
    if let normalizedVersion {
      fields["version"] = phpQuote(normalizedVersion)
    }
    fields["reference"] = reference.map(phpQuote) ?? "NULL"
    return fields
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
      fields[field] = phpList(constraints)
      versions[name] = fields
    }
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

  private static func phpList(_ values: [String]) -> String {
    guard !values.isEmpty else {
      return "array()"
    }
    let entries = values.enumerated().map { index, value in
      "\(index) => \(phpQuote(value))"
    }.joined(separator: ", ")
    return "array(\(entries))"
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
