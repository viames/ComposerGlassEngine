import Foundation

public enum ComposerManifestError: Error, Equatable, Sendable {
  case rootIsNotObject
  case invalidStringMap(String)
  case invalidPackageName(String)
}

/// A Composer root manifest that preserves fields not yet understood by the
/// engine.
public struct ComposerManifest: Equatable, Sendable {
  public private(set) var fields: [String: JSONValue]

  public init(fields: [String: JSONValue] = [:]) {
    self.fields = fields
  }

  public static func decode(from data: Data) throws -> ComposerManifest {
    let value = try JSONDecoder().decode(JSONValue.self, from: data)
    guard case .object(let fields) = value else {
      throw ComposerManifestError.rootIsNotObject
    }
    return ComposerManifest(fields: fields)
  }

  public func encoded(
    prettyPrinted: Bool = true,
    sortedKeys: Bool = false
  ) throws -> Data {
    let encoder = JSONEncoder()
    var formatting: JSONEncoder.OutputFormatting = [.withoutEscapingSlashes]
    if prettyPrinted {
      formatting.insert(.prettyPrinted)
    }
    if sortedKeys {
      formatting.insert(.sortedKeys)
    }
    encoder.outputFormatting = formatting
    return try encoder.encode(JSONValue.object(fields))
  }

  public var name: String? {
    get { fields["name"]?.stringValue }
    set { setOptionalString(newValue, for: "name") }
  }

  public var packageDescription: String? {
    get { fields["description"]?.stringValue }
    set { setOptionalString(newValue, for: "description") }
  }

  public var packageType: String? {
    get { fields["type"]?.stringValue }
    set { setOptionalString(newValue, for: "type") }
  }

  public var minimumStability: String? {
    get { fields["minimum-stability"]?.stringValue }
    set { setOptionalString(newValue, for: "minimum-stability") }
  }

  public var preferStable: Bool? {
    get {
      guard case .bool(let value)? = fields["prefer-stable"] else {
        return nil
      }
      return value
    }
    set {
      fields["prefer-stable"] = newValue.map(JSONValue.bool)
    }
  }

  public func requirements(
    in section: ComposerRequirementSection = .runtime
  ) throws -> [String: String] {
    let key = section.manifestKey
    guard let rawValue = fields[key] else {
      return [:]
    }
    guard case .object(let object) = rawValue else {
      throw ComposerManifestError.invalidStringMap(key)
    }

    var requirements: [String: String] = [:]
    for (package, constraint) in object {
      guard case .string(let constraintValue) = constraint else {
        throw ComposerManifestError.invalidStringMap(key)
      }
      requirements[package] = constraintValue
    }
    return requirements
  }

  public mutating func setRequirement(
    package: String,
    constraint: String?,
    in section: ComposerRequirementSection = .runtime
  ) throws {
    guard ComposerPackageName.isValid(package) else {
      throw ComposerManifestError.invalidPackageName(package)
    }

    let key = section.manifestKey
    var requirements = try requirements(in: section)
    requirements[package] = constraint

    if requirements.isEmpty {
      fields.removeValue(forKey: key)
    } else {
      fields[key] = .object(
        requirements.mapValues(JSONValue.string)
      )
    }
  }

  public subscript(_ key: String) -> JSONValue? {
    get { fields[key] }
    set { fields[key] = newValue }
  }

  private mutating func setOptionalString(_ value: String?, for key: String) {
    fields[key] = value.map(JSONValue.string)
  }
}

public enum ComposerRequirementSection: String, CaseIterable, Sendable {
  case runtime
  case development
  case conflict
  case provide
  case replace

  fileprivate var manifestKey: String {
    switch self {
    case .runtime:
      "require"
    case .development:
      "require-dev"
    case .conflict:
      "conflict"
    case .provide:
      "provide"
    case .replace:
      "replace"
    }
  }
}

public enum ComposerPackageName {
  public static func isValid(_ value: String) -> Bool {
    if ComposerPlatformPackage.isPlatformName(value) {
      return true
    }

    let pattern = #"^[a-z0-9]([_.-]?[a-z0-9]+)*/[a-z0-9](([_.]|-{1,2})?[a-z0-9]+)*$"#
    guard let match = value.range(of: pattern, options: .regularExpression) else {
      return false
    }
    return match == value.startIndex..<value.endIndex
  }
}

public enum ComposerPlatformPackage {
  public static func isPlatformName(_ value: String) -> Bool {
    // Composer package names always contain a vendor separator. Prefixes such
    // as `php-http/` belong to regular packages, not to the PHP platform.
    guard !value.contains("/") else {
      return false
    }

    if value == "php" || value == "hhvm" || value == "composer" || value == "composer-plugin-api"
      || value == "composer-runtime-api"
    {
      return true
    }

    return value.hasPrefix("ext-") || value.hasPrefix("lib-") || value.hasPrefix("php-")
  }
}
