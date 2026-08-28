import Foundation

public enum ComposerConstraintError: Error, Equatable, Sendable {
  case empty
  case invalidToken(String)
  case invalidRange(String)
}

public struct ComposerConstraint: Equatable, Sendable {
  private let groups: [[Predicate]]

  public static func parse(_ value: String) throws -> ComposerConstraint {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let inlineAlias = trimmed.components(separatedBy: " as ")
    guard inlineAlias.count <= 2 else {
      throw ComposerConstraintError.invalidToken(value)
    }
    let aliased = inlineAlias.count == 2 ? inlineAlias[1] : inlineAlias[0]
    let normalizedAlias = normalizeDevelopmentAlias(aliased)
    let stripped = stripStabilityFlag(from: normalizedAlias)
    guard !stripped.isEmpty else {
      throw ComposerConstraintError.empty
    }

    let orParts =
      stripped
      .replacingOccurrences(of: "||", with: "|")
      .split(separator: "|", omittingEmptySubsequences: false)
    guard orParts.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
      throw ComposerConstraintError.invalidToken(value)
    }

    let groups = try orParts.map { part in
      try parseAndGroup(String(part))
    }
    return ComposerConstraint(groups: groups)
  }

  public func matches(_ version: ComposerVersion) -> Bool {
    groups.contains { group in
      group.allSatisfy { $0.matches(version) }
    }
  }

  private static func parseAndGroup(_ value: String) throws -> [Predicate] {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

    if let hyphenPredicates = try parseHyphenRange(trimmed) {
      return hyphenPredicates
    }

    let tokens =
      trimmed
      .replacingOccurrences(of: ",", with: " ")
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
    guard !tokens.isEmpty else {
      throw ComposerConstraintError.empty
    }
    return try tokens.flatMap(parseToken)
  }

  private static func parseToken(_ token: String) throws -> [Predicate] {
    if token == "*" || token.lowercased() == "x" {
      return [.always]
    }

    if token.hasPrefix("^") {
      let baseText = String(token.dropFirst())
      let base = try parseVersion(baseText, token: token)
      let componentCount = numericComponentCount(baseText)
      let upper: ComposerVersion
      if componentCount == 1 {
        upper = exclusiveUpper(major: base.major + 1)
      } else if base.major > 0 {
        upper = exclusiveUpper(major: base.major + 1)
      } else if componentCount == 2 || base.minor > 0 {
        upper = exclusiveUpper(major: 0, minor: base.minor + 1)
      } else {
        upper = exclusiveUpper(major: 0, minor: 0, patch: base.patch + 1)
      }
      return [
        .comparison(.greaterThanOrEqual, inclusiveLower(base)),
        .comparison(.lessThan, upper),
      ]
    }

    if token.hasPrefix("~") {
      let versionText = String(token.dropFirst())
      let componentCount = numericComponentCount(versionText)
      let base = try parseVersion(versionText, token: token)
      let upper =
        componentCount >= 3
        ? exclusiveUpper(major: base.major, minor: base.minor + 1)
        : exclusiveUpper(major: base.major + 1)
      return [
        .comparison(.greaterThanOrEqual, inclusiveLower(base)),
        .comparison(.lessThan, upper),
      ]
    }

    if containsWildcard(token) {
      return try wildcardPredicates(token)
    }

    let operators: [(String, ComparisonOperator)] = [
      (">=", .greaterThanOrEqual),
      ("<=", .lessThanOrEqual),
      ("!=", .notEqual),
      ("==", .equal),
      (">", .greaterThan),
      ("<", .lessThan),
      ("=", .equal),
    ]

    for (prefix, comparisonOperator) in operators where token.hasPrefix(prefix) {
      let versionText = String(token.dropFirst(prefix.count))
      guard !versionText.isEmpty else {
        throw ComposerConstraintError.invalidToken(token)
      }
      let parsedVersion = try parseVersion(versionText, token: token)
      let comparisonVersion: ComposerVersion
      switch comparisonOperator {
      case .greaterThanOrEqual:
        comparisonVersion = inclusiveLower(parsedVersion)
      case .lessThan:
        comparisonVersion =
          parsedVersion.hasExplicitStability
          ? parsedVersion
          : parsedVersion.replacingStability(with: .development)
      case .equal, .notEqual, .lessThanOrEqual, .greaterThan:
        comparisonVersion = parsedVersion
      }
      return [.comparison(comparisonOperator, comparisonVersion)]
    }

    return [.comparison(.equal, try parseVersion(token, token: token))]
  }

  private static func parseHyphenRange(_ value: String) throws -> [Predicate]? {
    let components = value.components(separatedBy: " - ")
    guard components.count > 1 else {
      return nil
    }
    guard components.count == 2 else {
      throw ComposerConstraintError.invalidRange(value)
    }

    let lowerText = components[0].trimmingCharacters(in: .whitespaces)
    let upperText = components[1].trimmingCharacters(in: .whitespaces)
    let lower = inclusiveLower(try parseVersion(lowerText, token: value))
    let upper = try parseVersion(upperText, token: value)
    let upperComponentCount = numericComponentCount(upperText)

    if upperComponentCount < 3 {
      let upperBound =
        upperComponentCount == 1
        ? exclusiveUpper(major: upper.major + 1)
        : exclusiveUpper(major: upper.major, minor: upper.minor + 1)
      return [
        .comparison(.greaterThanOrEqual, lower),
        .comparison(.lessThan, upperBound),
      ]
    }

    return [
      .comparison(.greaterThanOrEqual, lower),
      .comparison(.lessThanOrEqual, upper),
    ]
  }

  private static func wildcardPredicates(_ token: String) throws -> [Predicate] {
    let components = token.lowercased().split(
      separator: ".",
      omittingEmptySubsequences: false
    )
    guard
      let wildcardIndex = components.firstIndex(where: {
        $0 == "*" || $0 == "x"
      }), components[wildcardIndex...].allSatisfy({ $0 == "*" || $0 == "x" })
    else {
      throw ComposerConstraintError.invalidToken(token)
    }
    if wildcardIndex == 0 {
      return [.always]
    }

    let numericPrefix = components[..<wildcardIndex]
    guard numericPrefix.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
      throw ComposerConstraintError.invalidToken(token)
    }
    let numbers = numericPrefix.compactMap { Int($0) }
    var padded = numbers
    while padded.count < 4 {
      padded.append(0)
    }
    let lower = ComposerVersion(
      major: padded[0],
      minor: padded[1],
      patch: padded[2],
      build: padded[3],
      stability: .development
    )
    let upper: ComposerVersion
    switch wildcardIndex {
    case 1:
      upper = exclusiveUpper(major: padded[0] + 1)
    case 2:
      upper = exclusiveUpper(major: padded[0], minor: padded[1] + 1)
    default:
      upper = exclusiveUpper(
        major: padded[0],
        minor: padded[1],
        patch: padded[2] + 1
      )
    }
    return [.comparison(.greaterThanOrEqual, lower), .comparison(.lessThan, upper)]
  }

  private static func parseVersion(
    _ value: String,
    token: String
  ) throws -> ComposerVersion {
    do {
      return try ComposerVersion(value)
    } catch {
      throw ComposerConstraintError.invalidToken(token)
    }
  }

  private static func containsWildcard(_ value: String) -> Bool {
    value.split(separator: ".").contains {
      $0 == "*" || $0.lowercased() == "x"
    }
  }

  private static func numericComponentCount(_ value: String) -> Int {
    let withoutStability = value.split(separator: "-", maxSplits: 1)[0]
    return withoutStability.split(separator: ".").count
  }

  private static func inclusiveLower(_ version: ComposerVersion) -> ComposerVersion {
    version.hasExplicitStability
      ? version
      : version.replacingStability(with: .development)
  }

  private static func exclusiveUpper(
    major: Int,
    minor: Int = 0,
    patch: Int = 0,
    build: Int = 0
  ) -> ComposerVersion {
    ComposerVersion(
      major: major,
      minor: minor,
      patch: patch,
      build: build,
      stability: .development
    )
  }

  private static func stripStabilityFlag(from value: String) -> String {
    guard let atIndex = value.lastIndex(of: "@") else {
      return value
    }
    let flag = value[value.index(after: atIndex)...].lowercased()
    let knownFlags = ["dev", "alpha", "beta", "rc", "stable"]
    guard knownFlags.contains(flag) else {
      return value
    }
    return String(value[..<atIndex]).trimmingCharacters(in: .whitespaces)
  }

  private static func normalizeDevelopmentAlias(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.lowercased().hasSuffix("-dev") else {
      return trimmed
    }
    let numeric = String(trimmed.dropLast(4))
    guard
      numeric.split(separator: ".").allSatisfy({ component in
        component.allSatisfy(\.isNumber) || component.lowercased() == "x" || component == "*"
      })
    else {
      return trimmed
    }
    return numeric + "@dev"
  }
}

private enum Predicate: Equatable, Sendable {
  case always
  case comparison(ComparisonOperator, ComposerVersion)

  func matches(_ candidate: ComposerVersion) -> Bool {
    switch self {
    case .always:
      true
    case .comparison(let comparisonOperator, let version):
      switch comparisonOperator {
      case .equal:
        candidate == version
      case .notEqual:
        candidate != version
      case .lessThan:
        candidate < version
      case .lessThanOrEqual:
        candidate <= version
      case .greaterThan:
        candidate > version
      case .greaterThanOrEqual:
        candidate >= version
      }
    }
  }
}

private enum ComparisonOperator: Equatable, Sendable {
  case equal
  case notEqual
  case lessThan
  case lessThanOrEqual
  case greaterThan
  case greaterThanOrEqual
}
