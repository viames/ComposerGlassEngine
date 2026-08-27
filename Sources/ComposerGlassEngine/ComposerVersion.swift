import Foundation

public enum ComposerVersionError: Error, Equatable, Sendable {
  case empty
  case unsupportedBranch(String)
  case invalidNumericComponent(String)
  case tooManyNumericComponents(String)
  case invalidStability(String)
}

public enum ComposerStability: Int, Comparable, Codable, Sendable {
  case development = 0
  case alpha = 1
  case beta = 2
  case releaseCandidate = 3
  case stable = 4

  public static func < (lhs: ComposerStability, rhs: ComposerStability) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

/// A normalized numeric Composer version. Composer branch aliases such as
/// `dev-main` are intentionally represented outside this type.
public struct ComposerVersion: Hashable, Comparable, Codable, Sendable,
  CustomStringConvertible
{
  public let major: Int
  public let minor: Int
  public let patch: Int
  public let build: Int
  public let stability: ComposerStability
  public let stabilityNumber: Int
  public let original: String

  public init(_ value: String) throws {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ComposerVersionError.empty
    }
    guard !trimmed.lowercased().hasPrefix("dev-") else {
      throw ComposerVersionError.unsupportedBranch(trimmed)
    }

    let withoutPrefix: Substring =
      if trimmed.first?.lowercased() == "v" && trimmed.dropFirst().first?.isNumber == true {
        trimmed.dropFirst()
      } else {
        Substring(trimmed)
      }

    let versionAndMetadata = withoutPrefix.split(
      separator: "+",
      maxSplits: 1,
      omittingEmptySubsequences: false
    )[0]
    let pieces = versionAndMetadata.split(
      separator: "-",
      maxSplits: 1,
      omittingEmptySubsequences: false
    )
    let numericText = pieces[0]
    let numericComponents = numericText.split(
      separator: ".",
      omittingEmptySubsequences: false
    )
    guard numericComponents.count <= 4 else {
      throw ComposerVersionError.tooManyNumericComponents(trimmed)
    }

    var numbers = [Int]()
    for component in numericComponents {
      guard !component.isEmpty, component.allSatisfy(\.isNumber),
        let number = Int(component)
      else {
        throw ComposerVersionError.invalidNumericComponent(String(component))
      }
      numbers.append(number)
    }
    while numbers.count < 4 {
      numbers.append(0)
    }

    let parsedStability: (ComposerStability, Int)
    if pieces.count == 1 || pieces[1].isEmpty {
      parsedStability = (.stable, 0)
    } else {
      parsedStability = try Self.parseStability(String(pieces[1]))
    }

    major = numbers[0]
    minor = numbers[1]
    patch = numbers[2]
    build = numbers[3]
    stability = parsedStability.0
    stabilityNumber = parsedStability.1
    original = trimmed
  }

  internal init(
    major: Int,
    minor: Int = 0,
    patch: Int = 0,
    build: Int = 0,
    stability: ComposerStability = .stable,
    stabilityNumber: Int = 0
  ) {
    self.major = major
    self.minor = minor
    self.patch = patch
    self.build = build
    self.stability = stability
    self.stabilityNumber = stabilityNumber
    self.original = [major, minor, patch, build].map(String.init).joined(separator: ".")
  }

  internal func replacingStability(
    with stability: ComposerStability,
    number: Int = 0
  ) -> ComposerVersion {
    ComposerVersion(
      major: major,
      minor: minor,
      patch: patch,
      build: build,
      stability: stability,
      stabilityNumber: number
    )
  }

  internal var hasExplicitStability: Bool {
    original.split(separator: "+", maxSplits: 1)[0].contains("-")
  }

  public static func < (lhs: ComposerVersion, rhs: ComposerVersion) -> Bool {
    let lhsNumbers = [lhs.major, lhs.minor, lhs.patch, lhs.build]
    let rhsNumbers = [rhs.major, rhs.minor, rhs.patch, rhs.build]

    if lhsNumbers != rhsNumbers {
      return lhsNumbers.lexicographicallyPrecedes(rhsNumbers)
    }
    if lhs.stability != rhs.stability {
      return lhs.stability < rhs.stability
    }
    return lhs.stabilityNumber < rhs.stabilityNumber
  }

  public static func == (lhs: ComposerVersion, rhs: ComposerVersion) -> Bool {
    lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch
      && lhs.build == rhs.build && lhs.stability == rhs.stability
      && lhs.stabilityNumber == rhs.stabilityNumber
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(major)
    hasher.combine(minor)
    hasher.combine(patch)
    hasher.combine(build)
    hasher.combine(stability)
    hasher.combine(stabilityNumber)
  }

  public var description: String {
    original
  }

  private static func parseStability(
    _ value: String
  ) throws -> (ComposerStability, Int) {
    let normalized = value.lowercased()
    let prefixes: [(String, ComposerStability)] = [
      ("dev", .development),
      ("alpha", .alpha),
      ("a", .alpha),
      ("beta", .beta),
      ("b", .beta),
      ("rc", .releaseCandidate),
      ("stable", .stable),
    ]

    for (prefix, stability) in prefixes where normalized.hasPrefix(prefix) {
      var suffix = String(normalized.dropFirst(prefix.count))
      while suffix.first == "." || suffix.first == "-" {
        suffix.removeFirst()
      }
      guard suffix.isEmpty || suffix.allSatisfy(\.isNumber) else {
        throw ComposerVersionError.invalidStability(value)
      }
      return (stability, Int(suffix) ?? 0)
    }

    throw ComposerVersionError.invalidStability(value)
  }
}
