import Foundation

public enum ComposerLockError: Error, Equatable, Sendable {
  case rootIsNotObject
  case missingField(String)
  case invalidField(String)
  case invalidPackageName(String)
  case duplicatePackage(String)
}

public enum ComposerLockSection: String, CaseIterable, Sendable {
  case runtime
  case development

  fileprivate var lockKey: String {
    switch self {
    case .runtime:
      "packages"
    case .development:
      "packages-dev"
    }
  }
}

/// A package entry from `composer.lock` that retains unsupported metadata.
public struct ComposerLockedPackage: Equatable, Sendable {
  public private(set) var fields: [String: JSONValue]
  var jsonKeyOrders: [String: [String]]

  public init(
    name: String,
    version: String,
    fields: [String: JSONValue] = [:]
  ) throws {
    guard ComposerPackageName.isValid(name) else {
      throw ComposerLockError.invalidPackageName(name)
    }
    guard !version.isEmpty else {
      throw ComposerLockError.invalidField("version")
    }
    self.fields = fields
    self.fields["name"] = .string(name)
    self.fields["version"] = .string(version)
    self.jsonKeyOrders = [:]
  }

  public var name: String {
    fields["name"]?.stringValue ?? ""
  }

  public var version: String {
    fields["version"]?.stringValue ?? ""
  }

  public var packageDescription: String? {
    fields["description"]?.stringValue
  }

  public var packageType: String? {
    fields["type"]?.stringValue
  }

  public func requirements() throws -> [String: String] {
    guard let rawRequirements = fields["require"] else {
      return [:]
    }
    guard case .object(let object) = rawRequirements else {
      throw ComposerLockError.invalidField("require")
    }
    var requirements: [String: String] = [:]
    for (name, value) in object {
      guard let constraint = value.stringValue else {
        throw ComposerLockError.invalidField("require")
      }
      requirements[name] = constraint
    }
    return requirements
  }

  public subscript(_ key: String) -> JSONValue? {
    fields[key]
  }

  fileprivate init(
    validating fields: [String: JSONValue],
    jsonKeyOrders: [String: [String]] = [:]
  ) throws {
    guard let name = fields["name"]?.stringValue else {
      throw ComposerLockError.missingField("name")
    }
    guard ComposerPackageName.isValid(name) else {
      throw ComposerLockError.invalidPackageName(name)
    }
    guard let version = fields["version"]?.stringValue, !version.isEmpty else {
      throw ComposerLockError.missingField("version")
    }
    self.fields = fields
    self.jsonKeyOrders = jsonKeyOrders
  }
}

/// A structure-preserving representation of `composer.lock`.
public struct ComposerLockFile: Equatable, Sendable {
  public private(set) var fields: [String: JSONValue]
  private var jsonKeyOrders: [String: [String]]

  public init(
    contentHash: String,
    packages: [ComposerLockedPackage] = [],
    developmentPackages: [ComposerLockedPackage] = [],
    fields: [String: JSONValue] = [:]
  ) throws {
    self.fields = fields
    self.jsonKeyOrders = [:]
    self.fields["content-hash"] = .string(contentHash)
    try setPackages(packages, in: .runtime)
    try setPackages(developmentPackages, in: .development)
  }

  public static func decode(from data: Data) throws -> ComposerLockFile {
    let value = try JSONDecoder().decode(JSONValue.self, from: data)
    guard case .object(let fields) = value else {
      throw ComposerLockError.rootIsNotObject
    }
    let lockFile = ComposerLockFile(
      fields: fields,
      jsonKeyOrders: JSONKeyOrderParser.parse(data)
    )
    try lockFile.validate()
    return lockFile
  }

  public var contentHash: String {
    fields["content-hash"]?.stringValue ?? ""
  }

  public var minimumStability: String? {
    fields["minimum-stability"]?.stringValue
  }

  public var pluginAPIVersion: String? {
    fields["plugin-api-version"]?.stringValue
  }

  var wasGeneratedByComposerGlassEngine: Bool {
    fields["_readme"]?.arrayValue?.contains {
      $0.stringValue?.contains("ComposerGlassEngine") == true
    } == true
  }

  public func packages(
    in section: ComposerLockSection = .runtime
  ) throws -> [ComposerLockedPackage] {
    guard case .array(let values)? = fields[section.lockKey] else {
      throw ComposerLockError.invalidField(section.lockKey)
    }
    return try values.enumerated().map { index, value in
      guard case .object(let packageFields) = value else {
        throw ComposerLockError.invalidField(section.lockKey)
      }
      let prefix = "/\(section.lockKey)/\(index)"
      let packageOrderPairs: [(String, [String])] = jsonKeyOrders.compactMap {
        path, order -> (String, [String])? in
          guard path == prefix || path.hasPrefix(prefix + "/") else { return nil }
          return (String(path.dropFirst(prefix.count)), order)
        }
      let packageOrders = Dictionary(uniqueKeysWithValues: packageOrderPairs)
      return try ComposerLockedPackage(
        validating: packageFields,
        jsonKeyOrders: packageOrders
      )
    }
  }

  public mutating func setPackages(
    _ packages: [ComposerLockedPackage],
    in section: ComposerLockSection
  ) throws {
    let sortedPackages = packages.sorted {
      ($0.name, $0.version) < ($1.name, $1.version)
    }
    var names = Set<String>()
    for package in sortedPackages {
      guard names.insert(package.name).inserted else {
        throw ComposerLockError.duplicatePackage(package.name)
      }
    }
    fields[section.lockKey] = .array(
      sortedPackages.map { .object($0.fields) }
    )
  }

  public mutating func updateContentHash(from composerJSON: Data) throws {
    fields["content-hash"] = .string(
      try ComposerContentHash.compute(from: composerJSON)
    )
  }

  public func isFresh(for composerJSON: Data) throws -> Bool {
    contentHash == (try ComposerContentHash.compute(from: composerJSON))
  }

  public func encoded(prettyPrinted: Bool = true) throws -> Data {
    if prettyPrinted {
      return ComposerJSONWriter.data(.object(fields), rootOrder: ComposerJSONWriter.lockRootOrder)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return try encoder.encode(JSONValue.object(fields))
  }

  public subscript(_ key: String) -> JSONValue? {
    get { fields[key] }
    set { fields[key] = newValue }
  }

  private init(
    fields: [String: JSONValue],
    jsonKeyOrders: [String: [String]] = [:]
  ) {
    self.fields = fields
    self.jsonKeyOrders = jsonKeyOrders
  }

  private func validate() throws {
    guard fields["content-hash"] != nil else {
      throw ComposerLockError.missingField("content-hash")
    }
    guard fields["content-hash"]?.stringValue != nil else {
      throw ComposerLockError.invalidField("content-hash")
    }

    for section in ComposerLockSection.allCases {
      let packages = try packages(in: section)
      let duplicates = Dictionary(grouping: packages, by: \.name).first {
        $0.value.count > 1
      }
      if let duplicate = duplicates?.key {
        throw ComposerLockError.duplicatePackage(duplicate)
      }
    }
  }
}
