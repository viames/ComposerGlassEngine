import Foundation

public enum ComposerRepositoryError: Error, Equatable, Sendable {
  case invalidRepositoryURL
  case insecureURL(URL)
  case invalidResponse
  case unexpectedStatus(Int)
  case missingMetadataURL
  case invalidMetadataURL(String)
  case invalidPackages
  case packageNameMismatch(expected: String, actual: String)
}

/// The Composer 2 repository descriptor served from `packages.json`.
public struct ComposerRepositoryIndex: Equatable, Sendable {
  public private(set) var fields: [String: JSONValue]

  public static func decode(from data: Data) throws -> ComposerRepositoryIndex {
    let value = try JSONDecoder().decode(JSONValue.self, from: data)
    guard case .object(let fields) = value else {
      throw ComposerRepositoryError.invalidResponse
    }
    return ComposerRepositoryIndex(fields: fields)
  }

  public var metadataURLTemplate: String? {
    fields["metadata-url"]?.stringValue
  }

  public var providersAPIURLTemplate: String? {
    fields["providers-api"]?.stringValue
  }

  public var notificationURL: String? {
    fields["notify-batch"]?.stringValue ?? fields["notify"]?.stringValue
  }

  public var availablePackages: [String]? {
    guard case .array(let values)? = fields["available-packages"] else {
      return nil
    }
    let names = values.compactMap(\.stringValue)
    return names.count == values.count ? names : nil
  }

  public var availablePackagePatterns: [String]? {
    guard case .array(let values)? = fields["available-package-patterns"] else {
      return nil
    }
    let patterns = values.compactMap(\.stringValue)
    return patterns.count == values.count ? patterns : nil
  }

  public func mayContain(package name: String) -> Bool {
    if let availablePackages {
      return availablePackages.contains(name)
    }
    if let availablePackagePatterns {
      return availablePackagePatterns.contains { pattern in
        Self.matches(name, wildcardPattern: pattern)
      }
    }
    return true
  }

  public subscript(_ key: String) -> JSONValue? {
    fields[key]
  }

  func inlinePackages(named name: String) throws -> [ComposerRepositoryPackage]? {
    guard case .object(let packageMap)? = fields["packages"], let raw = packageMap[name] else {
      return nil
    }
    return try ComposerRepositoryPackage.decodeCollection(raw, expectedName: name)
  }

  private static func matches(_ value: String, wildcardPattern: String) -> Bool {
    let expression = NSRegularExpression.escapedPattern(for: wildcardPattern)
      .replacingOccurrences(of: #"\*"#, with: ".*")
    let pattern = "^\(expression)$"
    return value.range(of: pattern, options: .regularExpression) != nil
  }
}

/// One installable version returned by a Composer repository.
public struct ComposerRepositoryPackage: Equatable, Sendable {
  public private(set) var fields: [String: JSONValue]
  var jsonKeyOrders: [String: [String]]

  private init(fields: [String: JSONValue]) {
    self.fields = fields
    self.jsonKeyOrders = [:]
  }

  /// Creates package metadata for custom repositories and deterministic tests.
  /// Reserved package fields are normalized from the typed arguments.
  public init(
    name: String,
    version: String,
    normalizedVersion: String? = nil,
    requirements: [String: String] = [:],
    additionalFields: [String: JSONValue] = [:]
  ) throws {
    guard
      ComposerPackageName.isValid(name), name == name.lowercased(),
      !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw ComposerRepositoryError.invalidPackages
    }
    guard
      requirements.allSatisfy({
        ComposerPackageName.isValid($0.key) && $0.key == $0.key.lowercased()
          && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      })
    else {
      throw ComposerRepositoryError.invalidPackages
    }

    var fields = additionalFields
    fields["name"] = .string(name)
    fields["version"] = .string(version)
    fields["version_normalized"] = normalizedVersion.map(JSONValue.string)
    fields["require"] =
      requirements.isEmpty
      ? nil
      : .object(requirements.mapValues(JSONValue.string))
    self.fields = fields
    self.jsonKeyOrders = [:]
  }

  public var name: String {
    fields["name"]?.stringValue ?? ""
  }

  public var version: String {
    fields["version"]?.stringValue ?? ""
  }

  public var normalizedVersion: String? {
    fields["version_normalized"]?.stringValue
  }

  public var packageDescription: String? {
    fields["description"]?.stringValue
  }

  public var packageType: String? {
    fields["type"]?.stringValue
  }

  public var distURL: URL? {
    endpointURL(for: "dist")
  }

  public var distType: String? {
    endpointString(for: "type", in: "dist")
  }

  public var distReference: String? {
    endpointString(for: "reference", in: "dist")
  }

  public var distChecksum: String? {
    endpointString(for: "shasum", in: "dist")
  }

  public var sourceURL: URL? {
    endpointURL(for: "source")
  }

  public func requirements() throws -> [String: String] {
    try stringMap(named: "require")
  }

  public func conflicts() throws -> [String: String] {
    try stringMap(named: "conflict")
  }

  public func provides() throws -> [String: String] {
    try stringMap(named: "provide")
  }

  public func replaces() throws -> [String: String] {
    try stringMap(named: "replace")
  }

  public var branchAlias: String? {
    guard case .object(let extra)? = fields["extra"],
      case .object(let aliases)? = extra["branch-alias"]
    else {
      return nil
    }
    return aliases[version]?.stringValue
  }

  private func stringMap(named field: String) throws -> [String: String] {
    guard let rawRequirements = fields[field] else {
      return [:]
    }
    guard case .object(let object) = rawRequirements else {
      throw ComposerRepositoryError.invalidPackages
    }
    var requirements: [String: String] = [:]
    for (name, value) in object {
      guard let constraint = value.stringValue else {
        throw ComposerRepositoryError.invalidPackages
      }
      requirements[name] = constraint
    }
    return requirements
  }

  public subscript(_ key: String) -> JSONValue? {
    fields[key]
  }

  func withRepositoryNotificationURL(_ url: String?) -> ComposerRepositoryPackage {
    guard fields["notification-url"] == nil, let url else { return self }
    var copy = self
    copy.fields["notification-url"] = .string(url)
    return copy
  }

  static func decodeCollection(
    _ value: JSONValue,
    expectedName: String
  ) throws -> [ComposerRepositoryPackage] {
    let packageValues: [JSONValue]
    switch value {
    case .array(let values):
      packageValues = values
    case .object(let versions):
      packageValues = versions.sorted { $0.key < $1.key }.map(\.value)
    default:
      throw ComposerRepositoryError.invalidPackages
    }
    return try packageValues.map { try decode($0, expectedName: expectedName) }
  }

  static func decode(_ value: JSONValue, expectedName: String) throws
    -> ComposerRepositoryPackage
  {
    guard case .object(let fields) = value,
      let name = fields["name"]?.stringValue,
      let version = fields["version"]?.stringValue,
      !version.isEmpty
    else {
      throw ComposerRepositoryError.invalidPackages
    }
    guard name == expectedName else {
      throw ComposerRepositoryError.packageNameMismatch(
        expected: expectedName,
        actual: name
      )
    }
    return ComposerRepositoryPackage(fields: fields)
  }

  private func endpointURL(for key: String) -> URL? {
    guard case .object(let endpoint)? = fields[key],
      let value = endpoint["url"]?.stringValue
    else {
      return nil
    }
    return URL(string: value)
  }

  private func endpointString(for field: String, in key: String) -> String? {
    guard case .object(let endpoint)? = fields[key] else {
      return nil
    }
    return endpoint[field]?.stringValue
  }
}

/// An independent Swift implementation of the public `composer/2.0` metadata
/// expansion format documented by `composer/metadata-minifier`.
enum ComposerMetadataMinifier {
  static func expand(_ values: [JSONValue]) throws -> [JSONValue] {
    guard var expandedFields = values.first?.objectValue else {
      if values.isEmpty {
        return []
      }
      throw ComposerRepositoryError.invalidPackages
    }

    var expanded: [JSONValue] = [.object(expandedFields)]
    for value in values.dropFirst() {
      guard case .object(let changes) = value else {
        throw ComposerRepositoryError.invalidPackages
      }
      for (key, newValue) in changes {
        if newValue == .string("__unset") {
          expandedFields.removeValue(forKey: key)
        } else {
          expandedFields[key] = newValue
        }
      }
      expanded.append(.object(expandedFields))
    }
    return expanded
  }
}
