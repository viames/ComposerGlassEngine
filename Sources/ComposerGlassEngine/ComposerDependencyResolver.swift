import Foundation

/// A source of Composer package versions. Repository clients and deterministic
/// in-memory sources can both participate in dependency resolution.
public protocol ComposerPackageSource: Sendable {
  func packages(
    named packageName: String,
    includeDevelopmentVersions: Bool
  ) async throws -> [ComposerRepositoryPackage]
}

public protocol ComposerVirtualPackageSource: ComposerPackageSource {
  func providerPackages(
    for virtualPackageName: String,
    includeDevelopmentVersions: Bool
  ) async throws -> [ComposerRepositoryPackage]
}

extension ComposerRepositoryClient: ComposerVirtualPackageSource {}

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
  case packageConflict(conflictingPackage: String, constraint: String)
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

public struct ComposerResolvedAlias: Equatable, Sendable {
  public let package: String
  public let version: String
  public let alias: String
  public let normalizedAlias: String

  public init(package: String, version: String, alias: String, normalizedAlias: String) {
    self.package = package
    self.version = version
    self.alias = alias
    self.normalizedAlias = normalizedAlias
  }
}

public struct ComposerResolutionResult: Equatable, Sendable {
  /// Packages sorted by package name for reproducible lockfile generation.
  public let packages: [ComposerResolvedPackage]
  public let aliases: [ComposerResolvedAlias]

  public init(
    packages: [ComposerResolvedPackage],
    aliases: [ComposerResolvedAlias] = []
  ) {
    self.packages = packages
    self.aliases = aliases
  }
}

public enum ComposerResolutionEvent: Equatable, Sendable {
  case evaluatingPackage(name: String, candidateCount: Int)
  case tryingVersion(package: String, version: String)
  case backtracking(package: String, version: String)
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
    let alias: ComposerResolvedAlias?
  }

  private struct Exposure: Sendable {
    let packageName: String
    let version: ComposerVersion
  }

  private struct State: Sendable {
    var requirements: [String: [ParsedRequirement]] = [:]
    var conflicts: [String: [ParsedRequirement]] = [:]
    var selected: [String: Candidate] = [:]
    var exposures: [String: Exposure] = [:]
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
    let providers: Bool
  }

  private struct CandidatePoolKey: Hashable, Sendable {
    let packageName: String
    let includeDevelopmentVersions: Bool
    let preferStable: Bool
  }

  private struct CandidatePool: Sendable {
    let rawPackages: [ComposerRepositoryPackage]
    let candidates: [Candidate]
  }

  private let source: any ComposerPackageSource
  private let platform: ComposerResolutionPlatform
  private var packageCache: [CacheKey: [ComposerRepositoryPackage]] = [:]
  private var candidatePoolCache: [CandidatePoolKey: CandidatePool] = [:]
  private var failedStateCache: [String: DeadEnd] = [:]
  private var inspectedIntrinsicCandidates: Set<String> = []
  private var intrinsicCandidateProblemCache: [String: ComposerResolutionProblem] = [:]

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
    preferStable: Bool = false,
    progress: (@Sendable (ComposerResolutionEvent) async -> Void)? = nil
  ) async throws -> ComposerResolutionResult {
    let rootRequirements = requirements.keys.sorted().compactMap { packageName in
      requirements[packageName].map {
        ComposerResolutionRequirement(package: packageName, constraint: $0)
      }
    }
    return try await resolve(
      rootRequirements: rootRequirements,
      rootConflicts: [],
      minimumStability: minimumStability,
      preferStable: preferStable,
      progress: progress
    )
  }

  public func resolve(
    manifest: ComposerManifest,
    includeDevelopmentRequirements: Bool = false,
    progress: (@Sendable (ComposerResolutionEvent) async -> Void)? = nil
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
    let rootConflicts = try manifest.requirements(in: .conflict).keys.sorted().compactMap {
      packageName in
      try manifest.requirements(in: .conflict)[packageName].map {
        ComposerResolutionRequirement(package: packageName, constraint: $0)
      }
    }
    return try await resolve(
      rootRequirements: rootRequirements,
      rootConflicts: rootConflicts,
      minimumStability: stability,
      preferStable: manifest.preferStable ?? false,
      progress: progress
    )
  }

  private func resolve(
    rootRequirements: [ComposerResolutionRequirement],
    rootConflicts: [ComposerResolutionRequirement],
    minimumStability: ComposerStability,
    preferStable: Bool,
    progress: (@Sendable (ComposerResolutionEvent) async -> Void)?
  ) async throws -> ComposerResolutionResult {
    packageCache.removeAll(keepingCapacity: true)
    candidatePoolCache.removeAll(keepingCapacity: true)
    failedStateCache.removeAll(keepingCapacity: true)
    inspectedIntrinsicCandidates.removeAll(keepingCapacity: true)
    intrinsicCandidateProblemCache.removeAll(keepingCapacity: true)
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
    for conflict in rootConflicts {
      guard ComposerPackageName.isValid(conflict.package),
        conflict.package == conflict.package.lowercased()
      else {
        throw ComposerDependencyResolverError.invalidPackageName(conflict.package)
      }
      do {
        try addConflict(conflict, to: &state)
      } catch {
        throw ComposerDependencyResolverError.invalidConstraint(conflict)
      }
    }

    let outcome = try await search(
      state,
      minimumStability: minimumStability,
      preferStable: preferStable,
      progress: progress
    )
    switch outcome {
    case .success(let result):
      let packages = result.selected.values
        .sorted { $0.package.name < $1.package.name }
        .map { ComposerResolvedPackage(package: $0.package, parsedVersion: $0.version) }
      let aliases = result.selected.values.compactMap(\.alias).sorted {
        ($0.package, $0.version, $0.alias) < ($1.package, $1.version, $1.alias)
      }
      return ComposerResolutionResult(packages: packages, aliases: aliases)
    case .failure(let deadEnd):
      throw ComposerDependencyResolverError.resolutionFailed(deadEnd.problem)
    }
  }

  private func search(
    _ state: State,
    minimumStability: ComposerStability,
    preferStable: Bool,
    progress: (@Sendable (ComposerResolutionEvent) async -> Void)?
  ) async throws -> SearchOutcome {
    try Task.checkCancellation()
    let fingerprint = stateFingerprint(state)
    if let cachedFailure = failedStateCache[fingerprint] {
      return .failure(cachedFailure)
    }
    let unsatisfiedPackageNames = state.requirements.keys
      .filter { !requirementsAreSatisfied(for: $0, in: state) }
      .sorted()
    guard !unsatisfiedPackageNames.isEmpty else {
      return .success(state)
    }

    try await prefetchPackageMetadata(
      for: unsatisfiedPackageNames,
      in: state,
      minimumStability: minimumStability
    )

    var choices: [CandidateChoice] = []
    for packageName in unsatisfiedPackageNames {
      try Task.checkCancellation()
      let choice = try await candidateChoice(
        for: packageName,
        in: state,
        minimumStability: minimumStability,
        preferStable: preferStable
      )
      choices.append(choice)
    }

    // A real package whose published versions are all incompatible with the
    // current state cannot become viable later in this branch. Fail before
    // exploring unrelated packages. An empty virtual requirement remains
    // deferrable because another unselected package may provide it.
    if let definitiveFailure = choices.first(where: {
      $0.candidates.isEmpty && !$0.isDeferrableVirtualRequirement
    }) {
      let failure = definitiveFailure.emptyFailure(depth: state.depth)
      failedStateCache[fingerprint] = failure
      return .failure(failure)
    }

    // Resolve the most constrained package first. This avoids exploring large
    // version trees (for example aws/aws-sdk-php) before a narrow transitive
    // requirement can reject the branch.
    let viableChoices = choices.filter { !$0.candidates.isEmpty }
    guard !viableChoices.isEmpty else {
      let failure = choices[0].emptyFailure(depth: state.depth)
      failedStateCache[fingerprint] = failure
      return .failure(failure)
    }
    let choice = viableChoices.min {
      if $0.candidates.count != $1.candidates.count {
        return $0.candidates.count < $1.candidates.count
      }
      if $0.requirements.count != $1.requirements.count {
        return $0.requirements.count > $1.requirements.count
      }
      return $0.packageName < $1.packageName
    }!
    let packageName = choice.packageName
    let candidates = choice.candidates
    await progress?(
      .evaluatingPackage(name: packageName, candidateCount: candidates.count)
    )

    var bestFailure: DeadEnd?
    for candidate in candidates {
      try Task.checkCancellation()
      var branch = state
      branch.selected[candidate.package.name] = candidate
      for (name, version) in exposedVersions(by: candidate) {
        branch.exposures[name] = Exposure(
          packageName: candidate.package.name,
          version: version
        )
      }
      branch.depth += 1

      let dependencyOutcome = addDependencies(of: candidate, to: &branch)
      switch dependencyOutcome {
      case .failure(let failure):
        bestFailure = preferred(failure, over: bestFailure)
        continue
      case .success:
        break
      }

      await progress?(
        .tryingVersion(package: packageName, version: candidate.package.version)
      )

      let outcome = try await search(
        branch,
        minimumStability: minimumStability,
        preferStable: preferStable,
        progress: progress
      )
      switch outcome {
      case .success:
        return outcome
      case .failure(let failure):
        bestFailure = preferred(failure, over: bestFailure)
        await progress?(
          .backtracking(package: packageName, version: candidate.package.version)
        )
        if shouldBackjump(failure, over: packageName, in: branch) {
          failedStateCache[fingerprint] = failure
          return .failure(failure)
        }
      }
    }

    let failure =
      bestFailure
      ?? DeadEnd(
        problem: ComposerResolutionProblem(
          package: packageName,
          reason: .noCompatibleVersion,
          requirements: sortedExplanations(choice.requirements),
          availableVersions: choice.rawPackages.map(\.version).sorted()
        ),
        depth: state.depth
      )
    failedStateCache[fingerprint] = failure
    return .failure(failure)
  }

  private struct CandidateChoice {
    let packageName: String
    let requirements: [ParsedRequirement]
    let rawPackages: [ComposerRepositoryPackage]
    let candidates: [Candidate]
    let rejectedFailure: DeadEnd?

    var isDeferrableVirtualRequirement: Bool {
      candidates.isEmpty && rawPackages.isEmpty && rejectedFailure == nil
    }

    func emptyFailure(depth: Int) -> DeadEnd {
      if let rejectedFailure {
        return rejectedFailure
      }
      return DeadEnd(
        problem: ComposerResolutionProblem(
          package: packageName,
          reason: rawPackages.isEmpty ? .packageNotFound : .noCompatibleVersion,
          requirements: requirements.map(\.explanation).sorted {
            if $0.requiredBy != $1.requiredBy {
              return ($0.requiredBy ?? "") < ($1.requiredBy ?? "")
            }
            return $0.constraint < $1.constraint
          },
          availableVersions: rawPackages.map(\.version).sorted()
        ),
        depth: depth
      )
    }
  }

  private func candidateChoice(
    for packageName: String,
    in state: State,
    minimumStability: ComposerStability,
    preferStable: Bool
  ) async throws -> CandidateChoice {
    let requirements = state.requirements[packageName] ?? []
    let packageStability = effectiveStability(
      for: requirements,
      defaultingTo: minimumStability
    )
    let includeDevelopmentVersions = packageStability == .development
    let pool = try await candidatePool(
      for: packageName,
      includeDevelopmentVersions: includeDevelopmentVersions,
      preferStable: preferStable
    )
    let parsedCandidates = pool.candidates.filter { candidate in
      guard candidate.version.stability >= packageStability,
        let providedVersion = providedVersion(
          by: candidate.package,
          for: packageName,
          candidateVersion: candidate.version
        )
      else {
        return false
      }
      return requirements.allSatisfy { $0.constraint.matches(providedVersion) }
    }
    var candidates: [Candidate] = []
    var rejectedFailure: DeadEnd?
    for candidate in parsedCandidates {
      if let problem = intrinsicPlatformProblem(for: candidate) {
        let failure = DeadEnd(problem: problem, depth: state.depth + 1)
        rejectedFailure = preferred(failure, over: rejectedFailure)
        continue
      }
      if let failure = compatibilityFailure(for: candidate, in: state) {
        rejectedFailure = preferred(failure, over: rejectedFailure)
        continue
      }
      candidates.append(candidate)
    }
    return CandidateChoice(
      packageName: packageName,
      requirements: requirements,
      rawPackages: pool.rawPackages,
      candidates: candidates,
      rejectedFailure: rejectedFailure
    )
  }

  /// Platform requirements are immutable throughout a resolution. Rejecting
  /// these candidates before selecting unrelated packages prevents the same
  /// fixed incompatibility from being rediscovered in every branch.
  private func intrinsicPlatformProblem(
    for candidate: Candidate
  ) -> ComposerResolutionProblem? {
    let key = candidate.package.name + "@" + candidate.package.version
    if inspectedIntrinsicCandidates.contains(key) {
      return intrinsicCandidateProblemCache[key]
    }
    inspectedIntrinsicCandidates.insert(key)

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
      intrinsicCandidateProblemCache[key] = problem
      return problem
    }

    for dependencyName in requirements.keys.sorted()
    where ComposerPlatformPackage.isPlatformName(dependencyName) {
      guard let constraint = requirements[dependencyName] else {
        continue
      }
      let requirement = ComposerResolutionRequirement(
        package: dependencyName,
        constraint: constraint,
        requiredBy: candidate.package.name
      )
      if let problem = platformProblem(for: requirement) {
        intrinsicCandidateProblemCache[key] = problem
        return problem
      }
    }
    return nil
  }

  /// A fixed platform conflict cannot be repaired by changing a package that
  /// is not in the dependency chain that introduced the platform requirement.
  /// Skip those unrelated decision levels instead of exploring their Cartesian
  /// product, while still trying alternative versions of every ancestor.
  private func shouldBackjump(
    _ failure: DeadEnd,
    over packageName: String,
    in state: State
  ) -> Bool {
    switch failure.problem.reason {
    case .platformPackageUnavailable, .platformVersionMismatch:
      break
    case .packageNotFound, .noCompatibleVersion, .invalidConstraint, .packageConflict:
      return false
    }

    var contributingPackages = Set([failure.problem.package])
    var pending = failure.problem.requirements.compactMap(\.requiredBy)
    while let package = pending.popLast() {
      guard contributingPackages.insert(package).inserted else {
        continue
      }
      for requirement in state.requirements[package] ?? [] {
        if let requiredBy = requirement.explanation.requiredBy {
          pending.append(requiredBy)
        }
      }
    }
    return !contributingPackages.contains(packageName)
  }

  private func candidatePool(
    for packageName: String,
    includeDevelopmentVersions: Bool,
    preferStable: Bool
  ) async throws -> CandidatePool {
    let key = CandidatePoolKey(
      packageName: packageName,
      includeDevelopmentVersions: includeDevelopmentVersions,
      preferStable: preferStable
    )
    if let cached = candidatePoolCache[key] {
      return cached
    }
    var rawPackages = try await packages(
      named: packageName,
      includeDevelopmentVersions: includeDevelopmentVersions
    )
    if rawPackages.isEmpty {
      rawPackages = try await providerPackages(
        for: packageName,
        includeDevelopmentVersions: includeDevelopmentVersions
      )
    }
    let candidates = rawPackages.compactMap { package -> Candidate? in
      guard let parsed = parsedCandidate(for: package) else {
        return nil
      }
      return Candidate(package: package, version: parsed.version, alias: parsed.alias)
    }.sorted { lhs, rhs in
      if preferStable, lhs.version.stability != rhs.version.stability {
        return lhs.version.stability > rhs.version.stability
      }
      if lhs.version != rhs.version {
        return lhs.version > rhs.version
      }
      return lhs.package.version > rhs.package.version
    }
    let pool = CandidatePool(rawPackages: rawPackages, candidates: candidates)
    candidatePoolCache[key] = pool
    return pool
  }

  private func addDependencies(
    of candidate: Candidate,
    to state: inout State
  ) -> Result<Void, DeadEnd> {
    do {
      for (package, constraint) in try candidate.package.conflicts() {
        try addConflict(
          ComposerResolutionRequirement(
            package: package,
            constraint: constraint,
            requiredBy: candidate.package.name
          ),
          to: &state
        )
      }
    } catch {
      let problem = ComposerResolutionProblem(
        package: candidate.package.name,
        reason: .invalidConstraint("conflict"),
        requirements: [],
        availableVersions: [candidate.package.version]
      )
      return .failure(DeadEnd(problem: problem, depth: state.depth))
    }

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

  private func addConflict(
    _ requirement: ComposerResolutionRequirement,
    to state: inout State
  ) throws {
    let parsed = try ComposerConstraint.parse(requirement.constraint)
    let value = ParsedRequirement(explanation: requirement, constraint: parsed)
    if state.conflicts[requirement.package]?.contains(value) != true {
      state.conflicts[requirement.package, default: []].append(value)
    }
  }

  private func requirementsAreSatisfied(for packageName: String, in state: State) -> Bool {
    guard let requirements = state.requirements[packageName], !requirements.isEmpty else {
      return true
    }
    guard let exposure = state.exposures[packageName] else {
      return false
    }
    return requirements.allSatisfy { $0.constraint.matches(exposure.version) }
  }

  private func stateFingerprint(_ state: State) -> String {
    var parts = state.selected.keys.sorted().compactMap { name in
      state.selected[name].map { "S:\(name)@\($0.package.version)" }
    }
    for name in state.requirements.keys.sorted() {
      let values = (state.requirements[name] ?? []).map { requirement in
        "\(requirement.explanation.constraint)<-\(requirement.explanation.requiredBy ?? "root")"
      }.sorted().joined(separator: ",")
      parts.append("R:\(name)=\(values)")
    }
    for name in state.conflicts.keys.sorted() {
      let values = (state.conflicts[name] ?? []).map { requirement in
        "\(requirement.explanation.constraint)<-\(requirement.explanation.requiredBy ?? "root")"
      }.sorted().joined(separator: ",")
      parts.append("C:\(name)=\(values)")
    }
    return parts.joined(separator: "|")
  }

  private func compatibilityFailure(
    for candidate: Candidate,
    in state: State,
    excluding excludedPackage: String? = nil
  ) -> DeadEnd? {
    let exposed = exposedVersions(by: candidate)
    for (name, version) in exposed.sorted(by: { $0.key < $1.key }) {
      if let conflict = state.conflicts[name]?.first(where: { $0.constraint.matches(version) }) {
        return conflictFailure(
          candidate: candidate,
          conflictingPackage: name,
          conflict: conflict
        )
      }
    }

    let candidateConflicts = (try? candidate.package.conflicts()) ?? [:]
    for (name, constraintText) in candidateConflicts.sorted(by: { $0.key < $1.key }) {
      guard let constraint = try? ComposerConstraint.parse(constraintText) else {
        return DeadEnd(
          problem: ComposerResolutionProblem(
            package: candidate.package.name,
            reason: .invalidConstraint(constraintText),
            requirements: []
          ),
          depth: state.depth
        )
      }
      if ComposerPlatformPackage.isPlatformName(name), let version = platform.version(for: name),
        constraint.matches(version)
      {
        let requirement = ComposerResolutionRequirement(
          package: name,
          constraint: constraintText,
          requiredBy: candidate.package.name
        )
        return conflictFailure(
          candidate: candidate,
          conflictingPackage: name,
          conflict: ParsedRequirement(explanation: requirement, constraint: constraint)
        )
      }
      if let exposure = state.exposures[name], exposure.packageName != excludedPackage,
        constraint.matches(exposure.version)
      {
          let requirement = ComposerResolutionRequirement(
            package: name,
            constraint: constraintText,
            requiredBy: candidate.package.name
          )
          return conflictFailure(
            candidate: candidate,
            conflictingPackage: exposure.packageName,
            conflict: ParsedRequirement(explanation: requirement, constraint: constraint)
          )
      }
    }

    let candidateReplacements = (try? candidate.package.replaces()) ?? [:]
    for replacedName in candidateReplacements.keys.sorted() {
      if let exposure = state.exposures[replacedName],
        exposure.packageName != excludedPackage
      {
        let replacement = candidateReplacements[replacedName] ?? "*"
        let requirement = ComposerResolutionRequirement(
          package: replacedName,
          constraint: replacement,
          requiredBy: candidate.package.name
        )
        let parsed =
          (try? ComposerConstraint.parse(replacement == "self.version" ? "*" : replacement))
          ?? (try! ComposerConstraint.parse("*"))
        return conflictFailure(
          candidate: candidate,
          conflictingPackage: exposure.packageName,
          conflict: ParsedRequirement(explanation: requirement, constraint: parsed)
        )
      }
    }
    if let exposure = state.exposures[candidate.package.name],
      exposure.packageName != candidate.package.name,
      exposure.packageName != excludedPackage
    {
      let requirement = ComposerResolutionRequirement(
        package: candidate.package.name,
        constraint: "*",
        requiredBy: exposure.packageName
      )
      return conflictFailure(
        candidate: candidate,
        conflictingPackage: exposure.packageName,
        conflict: ParsedRequirement(
          explanation: requirement,
          constraint: try! ComposerConstraint.parse("*")
        )
      )
    }
    return nil
  }

  private func conflictFailure(
    candidate: Candidate,
    conflictingPackage: String,
    conflict: ParsedRequirement
  ) -> DeadEnd {
    DeadEnd(
      problem: ComposerResolutionProblem(
        package: candidate.package.name,
        reason: .packageConflict(
          conflictingPackage: conflictingPackage,
          constraint: conflict.explanation.constraint
        ),
        requirements: [conflict.explanation],
        availableVersions: [candidate.package.version]
      ),
      depth: 0
    )
  }

  private func exposedVersions(by candidate: Candidate) -> [String: ComposerVersion] {
    var result = [candidate.package.name: candidate.version]
    for name in ((try? candidate.package.provides()) ?? [:]).keys {
      if let version = providedVersion(
        by: candidate.package,
        for: name,
        candidateVersion: candidate.version
      ) {
        result[name] = version
      }
    }
    for name in ((try? candidate.package.replaces()) ?? [:]).keys {
      if let version = providedVersion(
        by: candidate.package,
        for: name,
        candidateVersion: candidate.version
      ) {
        result[name] = version
      }
    }
    return result
  }

  private func providedVersion(
    by package: ComposerRepositoryPackage,
    for requiredName: String,
    candidateVersion: ComposerVersion
  ) -> ComposerVersion? {
    if package.name == requiredName {
      return candidateVersion
    }
    let value =
      ((try? package.provides()) ?? [:])[requiredName]
      ?? ((try? package.replaces()) ?? [:])[requiredName]
    guard let value else {
      return nil
    }
    if value == "self.version" || value == "*" {
      return candidateVersion
    }
    return try? ComposerVersion(value)
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
      includeDevelopmentVersions: includeDevelopmentVersions,
      providers: false
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

  private struct PrefetchRequest: Sendable {
    let key: CacheKey
  }

  private struct PrefetchResult: Sendable {
    let key: CacheKey
    let packages: [ComposerRepositoryPackage]
  }

  private func prefetchPackageMetadata(
    for packageNames: [String],
    in state: State,
    minimumStability: ComposerStability
  ) async throws {
    let requests = packageNames.compactMap { packageName -> PrefetchRequest? in
      let stability = effectiveStability(
        for: state.requirements[packageName] ?? [],
        defaultingTo: minimumStability
      )
      let key = CacheKey(
        packageName: packageName,
        includeDevelopmentVersions: stability == .development,
        providers: false
      )
      return packageCache[key] == nil ? PrefetchRequest(key: key) : nil
    }
    guard requests.count > 1 else {
      return
    }

    let source = source
    let concurrencyLimit = 8
    var offset = 0
    while offset < requests.count {
      let upperBound = min(offset + concurrencyLimit, requests.count)
      let batch = Array(requests[offset..<upperBound])
      let results = try await withThrowingTaskGroup(
        of: PrefetchResult.self,
        returning: [PrefetchResult].self
      ) { group in
        for request in batch {
          group.addTask {
            let loaded = try await source.packages(
              named: request.key.packageName,
              includeDevelopmentVersions: request.key.includeDevelopmentVersions
            )
            return PrefetchResult(key: request.key, packages: loaded)
          }
        }
        var loaded: [PrefetchResult] = []
        loaded.reserveCapacity(batch.count)
        for try await result in group {
          loaded.append(result)
        }
        return loaded
      }
      for result in results {
        packageCache[result.key] = result.packages
      }
      offset = upperBound
    }
  }

  private func providerPackages(
    for packageName: String,
    includeDevelopmentVersions: Bool
  ) async throws -> [ComposerRepositoryPackage] {
    let key = CacheKey(
      packageName: packageName,
      includeDevelopmentVersions: includeDevelopmentVersions,
      providers: true
    )
    if let cached = packageCache[key] {
      return cached
    }
    guard let source = source as? any ComposerVirtualPackageSource else {
      packageCache[key] = []
      return []
    }
    let loaded = try await source.providerPackages(
      for: packageName,
      includeDevelopmentVersions: includeDevelopmentVersions
    )
    packageCache[key] = loaded
    return loaded
  }

  private func parsedCandidate(
    for package: ComposerRepositoryPackage
  ) -> (version: ComposerVersion, alias: ComposerResolvedAlias?)? {
    if let version = try? ComposerVersion(package.normalizedVersion ?? package.version) {
      return (version, nil)
    }
    guard let alias = package.branchAlias,
      let aliasVersion = Self.parseBranchAlias(alias)
    else {
      return nil
    }
    return (
      aliasVersion,
      ComposerResolvedAlias(
        package: package.name,
        version: package.version,
        alias: alias,
        normalizedAlias: [
          aliasVersion.major,
          aliasVersion.minor,
          aliasVersion.patch,
          aliasVersion.build,
        ].map(String.init).joined(separator: ".") + "-dev"
      )
    )
  }

  private static func parseBranchAlias(_ value: String) -> ComposerVersion? {
    var normalized = value.lowercased()
    guard normalized.hasSuffix("-dev") else {
      return nil
    }
    normalized.removeLast(4)
    let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
    guard !components.isEmpty, components.count <= 4 else {
      return nil
    }
    var numbers: [Int] = []
    var foundWildcard = false
    for component in components {
      if component == "x" || component == "*" {
        foundWildcard = true
        numbers.append(9_999_999)
      } else if !foundWildcard, let number = Int(component) {
        numbers.append(number)
      } else {
        return nil
      }
    }
    guard foundWildcard else {
      return nil
    }
    while numbers.count < 4 {
      numbers.append(9_999_999)
    }
    return ComposerVersion(
      major: numbers[0],
      minor: numbers[1],
      patch: numbers[2],
      build: numbers[3],
      stability: .development
    )
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
