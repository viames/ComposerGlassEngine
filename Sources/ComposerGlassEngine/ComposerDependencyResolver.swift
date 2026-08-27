import Foundation

/// A source of Composer package versions. Repository clients and deterministic
/// in-memory sources can both participate in dependency resolution.
public protocol ComposerPackageSource: Sendable {
  func packages(
    named packageName: String,
    includeDevelopmentVersions: Bool
  ) async throws -> [ComposerRepositoryPackage]
}

extension ComposerRepositoryClient: ComposerPackageSource {}

public enum ComposerResolutionPlatformError: Error, Equatable, Sendable {
  case invalidPackageName(String)
  case invalidVersion(package: String, version: String)
}

/// The immutable virtual packages used while resolving PHP and extension
/// requirements. These packages are checked but never included in the result.
public struct ComposerResolutionPlatform: Equatable, Sendable {
  public static let empty = ComposerResolutionPlatform(validatedPackages: [:])

  public private(set) var packages: [String: ComposerVersion]

  public init(packages: [String: String] = [:]) throws {
    var parsed: [String: ComposerVersion] = [:]
    for (name, value) in packages {
      guard ComposerPlatformPackage.isPlatformName(name), name == name.lowercased() else {
        throw ComposerResolutionPlatformError.invalidPackageName(name)
      }
      do {
        parsed[name] = try ComposerVersion(value)
      } catch {
        throw ComposerResolutionPlatformError.invalidVersion(package: name, version: value)
      }
    }
    self.packages = parsed
  }

  private init(validatedPackages: [String: ComposerVersion]) {
    self.packages = validatedPackages
  }

  public func version(for packageName: String) -> ComposerVersion? {
    packages[packageName]
  }
}

/// One constraint contributing to a resolution decision or failure.
public struct ComposerResolutionRequirement: Equatable, Sendable {
  public let package: String
  public let constraint: String
  public let requiredBy: String?

  public init(package: String, constraint: String, requiredBy: String? = nil) {
    self.package = package
    self.constraint = constraint
    self.requiredBy = requiredBy
  }
}

public enum ComposerResolutionProblemReason: Equatable, Sendable {
  case packageNotFound
  case noCompatibleVersion
  case invalidConstraint(String)
  case platformPackageUnavailable
  case platformVersionMismatch(actualVersion: String)
}

/// A stable, UI-independent explanation of why a resolution branch failed.
public struct ComposerResolutionProblem: Equatable, Sendable {
  public let package: String
  public let reason: ComposerResolutionProblemReason
  public let requirements: [ComposerResolutionRequirement]
  public let availableVersions: [String]

  public init(
    package: String,
    reason: ComposerResolutionProblemReason,
    requirements: [ComposerResolutionRequirement],
    availableVersions: [String] = []
  ) {
    self.package = package
    self.reason = reason
    self.requirements = requirements
    self.availableVersions = availableVersions
  }
}

public enum ComposerDependencyResolverError: Error, Equatable, Sendable {
  case invalidPackageName(String)
  case invalidConstraint(ComposerResolutionRequirement)
  case resolutionFailed(ComposerResolutionProblem)
}

public struct ComposerResolvedPackage: Equatable, Sendable {
  public let package: ComposerRepositoryPackage
  public let parsedVersion: ComposerVersion

  public init(package: ComposerRepositoryPackage, parsedVersion: ComposerVersion) {
    self.package = package
    self.parsedVersion = parsedVersion
  }
}

public struct ComposerResolutionResult: Equatable, Sendable {
  /// Packages sorted by package name for reproducible lockfile generation.
  public let packages: [ComposerResolvedPackage]

  public init(packages: [ComposerResolvedPackage]) {
    self.packages = packages
  }
}

/// A deterministic, highest-compatible dependency resolver for the supported
/// numeric-version subset. It performs backtracking without invoking PHP,
/// Composer, a shell, or downloaded package code.
public actor ComposerDependencyResolver {
  private struct ParsedRequirement: Equatable, Sendable {
    let explanation: ComposerResolutionRequirement
    let constraint: ComposerConstraint
  }

  private struct Candidate: Equatable, Sendable {
    let package: ComposerRepositoryPackage
    let version: ComposerVersion
  }

  private struct State: Sendable {
    var requirements: [String: [ParsedRequirement]] = [:]
    var selected: [String: Candidate] = [:]
    var depth = 0
  }

  private struct DeadEnd: Error, Sendable {
    let problem: ComposerResolutionProblem
    let depth: Int
  }

  private enum SearchOutcome: Sendable {
    case success(State)
    case failure(DeadEnd)
  }

  private struct CacheKey: Hashable, Sendable {
    let packageName: String
    let includeDevelopmentVersions: Bool
  }

  private let source: any ComposerPackageSource
  private let platform: ComposerResolutionPlatform
  private var packageCache: [CacheKey: [ComposerRepositoryPackage]] = [:]

  public init(
    source: any ComposerPackageSource,
    platform: ComposerResolutionPlatform = .empty
  ) {
    self.source = source
    self.platform = platform
  }

  public func resolve(
    requirements: [String: String],
    minimumStability: ComposerStability = .stable,
    preferStable: Bool = false
  ) async throws -> ComposerResolutionResult {
    let rootRequirements = requirements.keys.sorted().compactMap { packageName in
      requirements[packageName].map {
        ComposerResolutionRequirement(package: packageName, constraint: $0)
      }
    }
    return try await resolve(
      rootRequirements: rootRequirements,
      minimumStability: minimumStability,
      preferStable: preferStable
    )
  }

  public func resolve(
    manifest: ComposerManifest,
    includeDevelopmentRequirements: Bool = false
  ) async throws -> ComposerResolutionResult {
    let runtime = try manifest.requirements()
    var rootRequirements = runtime.keys.sorted().compactMap { packageName in
      runtime[packageName].map {
        ComposerResolutionRequirement(package: packageName, constraint: $0)
      }
    }
    if includeDevelopmentRequirements {
      let development = try manifest.requirements(in: .development)
      rootRequirements += development.keys.sorted().compactMap { packageName in
        development[packageName].map {
          ComposerResolutionRequirement(package: packageName, constraint: $0)
        }
      }
    }
    let stability = try Self.parseStability(manifest.minimumStability ?? "stable")
    return try await resolve(
      rootRequirements: rootRequirements,
      minimumStability: stability,
      preferStable: manifest.preferStable ?? false
    )
  }

  private func resolve(
    rootRequirements: [ComposerResolutionRequirement],
    minimumStability: ComposerStability,
    preferStable: Bool
  ) async throws -> ComposerResolutionResult {
    packageCache.removeAll(keepingCapacity: true)
    var state = State()
    for requirement in rootRequirements {
      let packageName = requirement.package
      guard ComposerPackageName.isValid(packageName), packageName == packageName.lowercased() else {
        throw ComposerDependencyResolverError.invalidPackageName(packageName)
      }

      if ComposerPlatformPackage.isPlatformName(packageName) {
        if let problem = platformProblem(for: requirement) {
          throw ComposerDependencyResolverError.resolutionFailed(problem)
        }
      } else {
        do {
          try add(requirement, to: &state)
        } catch {
          throw ComposerDependencyResolverError.invalidConstraint(requirement)
        }
      }
    }

    let outcome = try await search(
      state,
      minimumStability: minimumStability,
      preferStable: preferStable
    )
    switch outcome {
    case .success(let result):
      let packages = result.selected.values
        .sorted { $0.package.name < $1.package.name }
        .map { ComposerResolvedPackage(package: $0.package, parsedVersion: $0.version) }
      return ComposerResolutionResult(packages: packages)
    case .failure(let deadEnd):
      throw ComposerDependencyResolverError.resolutionFailed(deadEnd.problem)
    }
  }

  private func search(
    _ state: State,
    minimumStability: ComposerStability,
    preferStable: Bool
  ) async throws -> SearchOutcome {
    guard
      let packageName = state.requirements.keys
        .filter({ state.selected[$0] == nil })
        .sorted()
        .first
    else {
      return .success(state)
    }

    let requirements = state.requirements[packageName] ?? []
    let packageStability = effectiveStability(
      for: requirements,
      defaultingTo: minimumStability
    )
    let includeDevelopmentVersions = packageStability == .development
    let rawPackages = try await packages(
      named: packageName,
      includeDevelopmentVersions: includeDevelopmentVersions
    )
    let availableVersions = rawPackages.map(\.version).sorted()
    let candidates = rawPackages.compactMap { package -> Candidate? in
      guard let version = try? ComposerVersion(package.normalizedVersion ?? package.version),
        version.stability >= packageStability,
        requirements.allSatisfy({ $0.constraint.matches(version) })
      else {
        return nil
      }
      return Candidate(package: package, version: version)
    }.sorted { lhs, rhs in
      if preferStable, lhs.version.stability != rhs.version.stability {
        return lhs.version.stability > rhs.version.stability
      }
      if lhs.version != rhs.version {
        return lhs.version > rhs.version
      }
      return lhs.package.version > rhs.package.version
    }

    guard !candidates.isEmpty else {
      let reason: ComposerResolutionProblemReason =
        rawPackages.isEmpty
        ? .packageNotFound
        : .noCompatibleVersion
      return .failure(
        DeadEnd(
          problem: ComposerResolutionProblem(
            package: packageName,
            reason: reason,
            requirements: sortedExplanations(requirements),
            availableVersions: availableVersions
          ),
          depth: state.depth
        )
      )
    }

    var bestFailure: DeadEnd?
    for candidate in candidates {
      var branch = state
      branch.selected[packageName] = candidate
      branch.depth += 1

      let dependencyOutcome = addDependencies(of: candidate, to: &branch)
      switch dependencyOutcome {
      case .failure(let failure):
        bestFailure = preferred(failure, over: bestFailure)
        continue
      case .success:
        break
      }

      let outcome = try await search(
        branch,
        minimumStability: minimumStability,
        preferStable: preferStable
      )
      switch outcome {
      case .success:
        return outcome
      case .failure(let failure):
        bestFailure = preferred(failure, over: bestFailure)
      }
    }

    return .failure(
      bestFailure
        ?? DeadEnd(
          problem: ComposerResolutionProblem(
            package: packageName,
            reason: .noCompatibleVersion,
            requirements: sortedExplanations(requirements),
            availableVersions: availableVersions
          ),
          depth: state.depth
        )
    )
  }

  private func addDependencies(
    of candidate: Candidate,
    to state: inout State
  ) -> Result<Void, DeadEnd> {
    let requirements: [String: String]
    do {
      requirements = try candidate.package.requirements()
    } catch {
      let problem = ComposerResolutionProblem(
        package: candidate.package.name,
        reason: .invalidConstraint("require"),
        requirements: [],
        availableVersions: [candidate.package.version]
      )
      return .failure(DeadEnd(problem: problem, depth: state.depth))
    }

    for dependencyName in requirements.keys.sorted() {
      guard let constraintText = requirements[dependencyName] else {
        continue
      }
      let requirement = ComposerResolutionRequirement(
        package: dependencyName,
        constraint: constraintText,
        requiredBy: candidate.package.name
      )
      guard ComposerPackageName.isValid(dependencyName),
        dependencyName == dependencyName.lowercased()
      else {
        let problem = ComposerResolutionProblem(
          package: dependencyName,
          reason: .invalidConstraint(constraintText),
          requirements: [requirement]
        )
        return .failure(DeadEnd(problem: problem, depth: state.depth))
      }

      if ComposerPlatformPackage.isPlatformName(dependencyName) {
        if let problem = platformProblem(for: requirement) {
          return .failure(DeadEnd(problem: problem, depth: state.depth))
        }
        continue
      }

      do {
        try add(requirement, to: &state)
      } catch {
        let problem = ComposerResolutionProblem(
          package: dependencyName,
          reason: .invalidConstraint(constraintText),
          requirements: [requirement]
        )
        return .failure(DeadEnd(problem: problem, depth: state.depth))
      }

      if let selected = state.selected[dependencyName],
        let dependencyRequirements = state.requirements[dependencyName],
        !dependencyRequirements.allSatisfy({ $0.constraint.matches(selected.version) })
      {
        let problem = ComposerResolutionProblem(
          package: dependencyName,
          reason: .noCompatibleVersion,
          requirements: sortedExplanations(dependencyRequirements),
          availableVersions: [selected.package.version]
        )
        return .failure(DeadEnd(problem: problem, depth: state.depth))
      }
    }
    return .success(())
  }

  private func add(
    _ requirement: ComposerResolutionRequirement,
    to state: inout State
  ) throws {
    let parsed = try ComposerConstraint.parse(requirement.constraint)
    let value = ParsedRequirement(explanation: requirement, constraint: parsed)
    if state.requirements[requirement.package]?.contains(value) != true {
      state.requirements[requirement.package, default: []].append(value)
    }
  }

  private func platformProblem(
    for requirement: ComposerResolutionRequirement
  ) -> ComposerResolutionProblem? {
    guard let version = platform.version(for: requirement.package) else {
      return ComposerResolutionProblem(
        package: requirement.package,
        reason: .platformPackageUnavailable,
        requirements: [requirement]
      )
    }
    guard let constraint = try? ComposerConstraint.parse(requirement.constraint) else {
      return ComposerResolutionProblem(
        package: requirement.package,
        reason: .invalidConstraint(requirement.constraint),
        requirements: [requirement],
        availableVersions: [version.original]
      )
    }
    guard constraint.matches(version) else {
      return ComposerResolutionProblem(
        package: requirement.package,
        reason: .platformVersionMismatch(actualVersion: version.original),
        requirements: [requirement],
        availableVersions: [version.original]
      )
    }
    return nil
  }

  private func packages(
    named packageName: String,
    includeDevelopmentVersions: Bool
  ) async throws -> [ComposerRepositoryPackage] {
    let key = CacheKey(
      packageName: packageName,
      includeDevelopmentVersions: includeDevelopmentVersions
    )
    if let cached = packageCache[key] {
      return cached
    }
    let loaded = try await source.packages(
      named: packageName,
      includeDevelopmentVersions: includeDevelopmentVersions
    )
    packageCache[key] = loaded
    return loaded
  }

  private func effectiveStability(
    for requirements: [ParsedRequirement],
    defaultingTo defaultStability: ComposerStability
  ) -> ComposerStability {
    requirements
      .filter { $0.explanation.requiredBy == nil }
      .compactMap { Self.stabilityFlag(in: $0.explanation.constraint) }
      .min() ?? defaultStability
  }

  private func sortedExplanations(
    _ requirements: [ParsedRequirement]
  ) -> [ComposerResolutionRequirement] {
    requirements.map(\.explanation).sorted {
      if $0.requiredBy != $1.requiredBy {
        return ($0.requiredBy ?? "") < ($1.requiredBy ?? "")
      }
      return $0.constraint < $1.constraint
    }
  }

  private func preferred(_ newFailure: DeadEnd, over current: DeadEnd?) -> DeadEnd {
    guard let current else {
      return newFailure
    }
    if newFailure.depth != current.depth {
      return newFailure.depth > current.depth ? newFailure : current
    }
    if newFailure.problem.requirements.count != current.problem.requirements.count {
      return newFailure.problem.requirements.count > current.problem.requirements.count
        ? newFailure
        : current
    }
    return newFailure.problem.package < current.problem.package ? newFailure : current
  }

  private static func stabilityFlag(in constraint: String) -> ComposerStability? {
    guard let marker = constraint.lastIndex(of: "@") else {
      return nil
    }
    return try? parseStability(String(constraint[constraint.index(after: marker)...]))
  }

  private static func parseStability(_ value: String) throws -> ComposerStability {
    switch value.lowercased() {
    case "dev": .development
    case "alpha": .alpha
    case "beta": .beta
    case "rc": .releaseCandidate
    case "stable": .stable
    default: throw ComposerConstraintError.invalidToken(value)
    }
  }
}
